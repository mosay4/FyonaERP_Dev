import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/services/currency/currency_engine.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../personal/domain/services/exchange_rate_service.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import '../widgets/personal_account_choice.dart';

class PersonalRecurringFormPage extends ConsumerStatefulWidget {
  const PersonalRecurringFormPage({super.key});
  @override
  ConsumerState<PersonalRecurringFormPage> createState() => _PersonalRecurringFormPageState();
}

/// Execution-day rule for the wizard: which calendar days may be picked as
/// the execution day for a given frequency. [anchor] is the already-chosen
/// start date (if any) that locks the weekday / day-of-month / anniversary.
bool isRecurringExecDaySelectable(String? frequency, DateTime? anchor, DateTime day) {
  switch (frequency) {
    case 'daily':
      return true;
    case 'weekly':
      final anchorWeekday = anchor?.weekday;
      if (anchorWeekday == null) return true;
      return day.weekday == anchorWeekday;
    case 'monthly':
      final anchorDay = anchor?.day;
      if (anchorDay == null) return day.day <= 28;
      return day.day == anchorDay;
    case 'yearly':
      if (anchor == null) return true;
      return day.month == anchor.month && day.day == anchor.day;
    default:
      return false;
  }
}

class _PersonalRecurringFormPageState extends ConsumerState<PersonalRecurringFormPage> {
  int _currentStep = 0;
  bool _isEdit = false;
  String _editId = '';

  String _type = 'expense';
  final _nameCtrl = TextEditingController();
  String _category = '';
  final _amountCtrl = TextEditingController();
  final _amountFocus = FocusNode();
  // No pre-selected frequency: the user must pick one explicitly.
  String? _frequency;
  int _intervalValue = 1;
  DateTime? _startDate;
  DateTime? _endDate;
  String _accountType = 'fixed';
  String? _bankAccountId;
  String _currency = 'USD';
  bool _currencyTouched = false;
  String _executionType = 'auto';
  String? _reminderTime;

  static const _incomeCategories = ['مرتب', 'راتب', 'بيع', 'هدية', 'إيجار', 'استثمار', 'عمولة', 'عمل حر', 'مكافأة', 'أخرى'];
  static const _expenseCategories = ['طعام', 'مواصلات', 'اتصالات', 'صحة', 'تعليم', 'ترفيه', 'إيجار', 'فواتير', 'أخرى'];

  static const _frequencyOptions = [
    ('daily', 'frequencyDaily', Icons.today_rounded),
    ('weekly', 'frequencyWeekly', Icons.view_week_rounded),
    ('monthly', 'frequencyMonthly', Icons.calendar_view_month_rounded),
    ('yearly', 'frequencyYearly', Icons.event_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _resolveCurrencyDefault();
    // Self-sufficient bank list (same reason as the detail page): the
    // account step must work even when no other section loaded banks yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(personalFinanceProvider.notifier).load();
      } catch (_) {}
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final extra = GoRouterState.of(context).extra;
      if (extra is Map<String, dynamic> && extra['recurring'] != null) {
        final rt = extra['recurring'] as RecurringTransaction;
        _isEdit = true;
        _editId = rt.id;
        _type = rt.type;
        _nameCtrl.text = rt.name;
        _category = rt.category;
        _amountCtrl.text = rt.amount.toStringAsFixed(0);
        _frequency = rt.frequency;
        _intervalValue = rt.intervalValue;
        _startDate = rt.nextDate;
        _accountType = rt.accountType;
        _bankAccountId = rt.bankAccountId;
        _currency = rt.currency;
        _currencyTouched = true;
        _executionType = rt.executionType;
        _reminderTime = rt.reminderTime;
        setState(() {});
      }
    });
  }

  /// Resolves USD-if-enabled-else-enabled without ever overriding an
  /// explicit user pick or an edit's currency.
  Future<void> _resolveCurrencyDefault() async {
    try {
      final code =
          await resolveDefaultCurrency(ref.read(currentUserIdProvider));
      if (!mounted || _currencyTouched) return;
      setState(() => _currency = code);
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  bool _canProceed() {
    switch (_currentStep) {
      case 0: return true;
      case 1: return _nameCtrl.text.trim().isNotEmpty;
      case 2: return _category.isNotEmpty;
      case 3: return (double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0) > 0;
      // Step 4 is validated inside _nextStep so the user gets an explicit
      // message (frequency missing / execution day missing).
      case 4: return true;
      case 5: return true;
      case 6: return true;
      default: return true;
    }
  }

  double get _amount => double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;

  void _warn(String key) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context).translate(key), style: const TextStyle(fontFamily: 'Cairo')),
      backgroundColor: AppColors.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _nextStep() {
    // Step 4 (frequency + execution day/time): nothing is pre-selected.
    // The user must pick a frequency AND an execution day; a missing time
    // silently defaults to 09:00 AM.
    if (_currentStep == 4) {
      if (_frequency == null) {
        _warn('recurringChooseDurationFirst');
        return;
      }
      if (_startDate == null) {
        _warn('recurringExecDayRequired');
        return;
      }
      if (_reminderTime == null) {
        setState(() => _reminderTime = '09:00');
      }
    }
    if (_currentStep < 7 && _canProceed()) {
      setState(() => _currentStep++);
    }
  }

  void _prevStep() {
    if (_currentStep > 0) setState(() => _currentStep--);
  }

  void _submit() {
    if (_nameCtrl.text.trim().isEmpty || _amount <= 0) return;
    if (_frequency == null || _startDate == null) {
      _warn(_frequency == null ? 'recurringChooseDurationFirst' : 'recurringExecDayRequired');
      return;
    }
    // A fixed binding without an account can never auto-execute and shows
    // "unspecified" in details — require the account up front.
    if (_accountType == 'fixed' && (_bankAccountId == null || _bankAccountId!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).translate('selectBankAccount'), style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final rt = RecurringTransaction(
      id: _isEdit ? _editId : '',
      name: _nameCtrl.text.trim(),
      type: _type,
      amount: _amount,
      category: _category,
      frequency: _frequency ?? 'monthly',
      intervalValue: _intervalValue,
      nextDate: _startDate,
      bankAccountId: _bankAccountId,
      currency: _currency,
      accountType: _accountType,
      executionType: _executionType,
      reminderTime: _reminderTime,
    );
    HapticFeedback.lightImpact();
    if (_isEdit) {
      ref.read(recurringProvider.notifier).update(rt);
    } else {
      ref.read(recurringProvider.notifier).add(rt);
    }
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_isEdit ? AppLocalizations.of(context).translate('recurringEditFormTitle2') : AppLocalizations.of(context).translate('recurringFormTitle'),
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface, elevation: 0,
      ),
      body: Column(
        children: [
          _buildStepIndicator(),
          Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: _buildCurrentStep())),
          _buildNavigationButtons(),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    final steps = ['treeTypeLabel', 'nameLabel', 'categoryLabel', 'amountLabel', 'frequency', 'recurringStepAccount', 'recurringStepExecution', 'recurringStepReview'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: AppColors.surface,
      child: Row(
        children: List.generate(steps.length, (i) {
          final isActive = i == _currentStep;
          final isDone = i < _currentStep;
          return Expanded(
            child: Row(children: [
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: isDone ? const Color(0xFFD32F2F) : isActive ? const Color(0xFFD32F2F).withAlpha(30) : AppColors.border,
                  shape: BoxShape.circle,
                ),
                child: Center(child: isDone
                    ? const Icon(Icons.check, size: 12, color: Colors.white)
                    : Text('${i + 1}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                        color: isActive ? const Color(0xFFD32F2F) : AppColors.textSecondary))),
              ),
              if (i < steps.length - 1) Expanded(child: Container(height: 2, color: isDone ? const Color(0xFFD32F2F) : AppColors.border)),
            ]),
          );
        }),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case 0: return _stepType();
      case 1: return _stepName();
      case 2: return _stepCategory();
      case 3: return _stepAmount();
      case 4: return _stepFrequency();
      case 5: return _stepAccount();
      case 6: return _stepExecution();
      case 7: return _stepReview();
      default: return const SizedBox.shrink();
    }
  }

  Widget _stepHeader(String title, String subtitle) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style:  TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
      const SizedBox(height: 4),
      Text(subtitle, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
    ]);
  }

  // ── Step 0: Type ──
  Widget _stepType() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringTypeTitle'), AppLocalizations.of(context).translate('recurringTypeHint')),
      const SizedBox(height: 24),
      Row(children: [
        Expanded(child: _TypeCard(label: AppLocalizations.of(context).translate('income'), icon: Icons.arrow_downward_rounded, color: const Color(0xFF66BB6A), isSelected: _type == 'income', onTap: () => setState(() => _type = 'income'))),
        const SizedBox(width: 12),
        Expanded(child: _TypeCard(label: AppLocalizations.of(context).translate('expense'), icon: Icons.arrow_upward_rounded, color: const Color(0xFFD32F2F), isSelected: _type == 'expense', onTap: () => setState(() => _type = 'expense'))),
      ]),
    ]);
  }

  // ── Step 1: Name ──
  Widget _stepName() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringNameTitle'), AppLocalizations.of(context).translate('recurringNameHint')),
      const SizedBox(height: 16),
      FyonaTextField(
        controller: _nameCtrl,
        decoration: InputDecoration(
          hintText: AppLocalizations.of(context).translate('recurringNameExample'),
          hintStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textDisabled),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD32F2F), width: 2)),
          contentPadding: const EdgeInsets.all(16),
        ),
        style: const TextStyle(fontFamily: 'Cairo', fontSize: 15),
        onChanged: (_) => setState(() {}),
      ),
    ]);
  }

  // ── Step 2: Category ──
  Widget _stepCategory() {
    final cats = _type == 'income' ? _incomeCategories : _expenseCategories;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringStepCategory'), AppLocalizations.of(context).translate('recurringCategoryHint')),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: cats.map((cat) {
        final selected = _category == cat;
        return GestureDetector(
          onTap: () => setState(() => _category = cat),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFD32F2F).withAlpha(15) : AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? const Color(0xFFD32F2F) : AppColors.border, width: selected ? 2 : 1),
            ),
            child: Text(cat, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: selected ? const Color(0xFFD32F2F) : AppColors.textPrimary)),
          ),
        );
      }).toList()),
    ]);
  }

  // ── Step 3: Amount + Currency ──
  Widget _stepAmount() {
    final enabledAsync = ref.watch(enabledCurrenciesProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringAmountTitle'), AppLocalizations.of(context).translate('recurringAmountHint')),
      const SizedBox(height: 16),
      FyonaTextField(
        controller: _amountCtrl, focusNode: _amountFocus,
        keyboardType: TextInputType.number, inputFormatters: [AmountInputFormatter()],
        style: const TextStyle(fontFamily: 'Cairo', fontSize: 28, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          hintText: '0', hintStyle: TextStyle(color: AppColors.textDisabled),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD32F2F), width: 2)),
          contentPadding: const EdgeInsets.all(20),
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 16),
      Text(AppLocalizations.of(context).translate('recurringCurrencyLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
      const SizedBox(height: 8),
      enabledAsync.when(
        data: (enabled) {
          final currencies = enabled.where((code) => ExchangeRateService.supportedCurrencies.containsKey(code)).toList();
          if (currencies.isEmpty) currencies.addAll(['SAR', 'USD']);
          return Wrap(spacing: 8, runSpacing: 8, children: currencies.map((code) {
            // Name only (localized): showing symbol + name duplicates text
            // for variants whose symbol IS the name (e.g. Yemeni Rial).
            final name = ExchangeRateService.localizedName(code);
            final selected = _currency == code;
            return GestureDetector(
              onTap: () =>
                  setState(() => {_currency = code, _currencyTouched = true}),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFFD32F2F).withAlpha(15) : AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? const Color(0xFFD32F2F) : AppColors.border, width: selected ? 2 : 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(name, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: selected ? FontWeight.bold : FontWeight.normal, color: selected ? const Color(0xFFD32F2F) : AppColors.textPrimary)),
                ]),
              ),
            );
          }).toList());
        },
        loading: () => const DotsLoader(),
        error: (_, __) => const SizedBox.shrink(),
      ),
    ]);
  }

  // ── Step 4: Frequency + Dates ──
  Widget _stepFrequency() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringFreqTitle'), AppLocalizations.of(context).translate('recurringFreqHint')),
      const SizedBox(height: 16),
      GridView.count(
        shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.3,
        children: _frequencyOptions.map((f) {
          final selected = _frequency == f.$1;
          return GestureDetector(
            onTap: () => setState(() {
              // Switching frequency invalidates any previously picked
              // execution day (it belonged to the old period).
              if (_frequency != f.$1) {
                _startDate = null;
                _endDate = null;
              }
              _frequency = f.$1;
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFFD32F2F).withAlpha(15) : AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: selected ? const Color(0xFFD32F2F) : AppColors.border, width: selected ? 2 : 1),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(f.$3, size: 28, color: selected ? const Color(0xFFD32F2F) : AppColors.textSecondary),
                const SizedBox(height: 8),
                Text(AppLocalizations.of(context).translate(f.$2), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: selected ? const Color(0xFFD32F2F) : AppColors.textSecondary)),
              ]),
            ),
          );
        }).toList(),
      ),
      const SizedBox(height: 20),
      // ── Interval selector (custom amount) ──
      if (_frequency == 'weekly') ...[
        _intervalRow(AppLocalizations.of(context).translate('recurringEvery'), _intervalValue, 1, 12, AppLocalizations.of(context).translate('week')),
      ] else if (_frequency == 'monthly') ...[
        _intervalRow(AppLocalizations.of(context).translate('recurringEvery'), _intervalValue, 1, 24, AppLocalizations.of(context).translate('month')),
      ] else if (_frequency == 'yearly') ...[
        _intervalRow(AppLocalizations.of(context).translate('recurringEvery'), _intervalValue, 1, 10, AppLocalizations.of(context).translate('recurringYearSingle')),
      ],
      const SizedBox(height: 16),
      // ── Date pickers ──
      if (_frequency == 'daily') ...[
        _datePicker(AppLocalizations.of(context).translate('recurringPickDay'), _startDate, (d) => setState(() => _startDate = d)),
        if (_startDate != null)
          _dateInfo(AppLocalizations.of(context).translate('recurringStartsEnds24h', params: {'start': DateFormat('dd/MM/yyyy').format(_startDate!)})),
      ] else if (_frequency == 'weekly') ...[
        _datePicker(AppLocalizations.of(context).translate('recurringWeekStart'), _startDate, (d) {
          setState(() { _startDate = d; _endDate = d.add(Duration(days: 7 * _intervalValue)); });
        }),
        if (_startDate != null && _endDate != null)
          _dateInfo(AppLocalizations.of(context).translate('recurringStartsEnds', params: {'start': DateFormat('dd/MM/yyyy').format(_startDate!), 'end': DateFormat('dd/MM/yyyy').format(_endDate!)})),
      ] else if (_frequency == 'monthly') ...[
        _datePicker(AppLocalizations.of(context).translate('startDate'), _startDate, (d) {
          setState(() { _startDate = d; _endDate = DateTime(d.year, d.month + _intervalValue, d.day); });
        }),
        if (_startDate != null)
          _dateInfo(AppLocalizations.of(context).translate('recurringFromTo', params: {'from': DateFormat('dd/MM/yyyy').format(_startDate!), 'to': _endDate != null ? DateFormat('dd/MM/yyyy').format(_endDate!) : '--'})),
      ] else if (_frequency == 'yearly') ...[
        _datePicker(AppLocalizations.of(context).translate('startDate'), _startDate, (d) {
          setState(() { _startDate = d; _endDate = DateTime(d.year + _intervalValue, d.month, d.day); });
        }),
        if (_startDate != null)
          _dateInfo(AppLocalizations.of(context).translate('recurringFromTo', params: {'from': DateFormat('dd/MM/yyyy').format(_startDate!), 'to': _endDate != null ? DateFormat('dd/MM/yyyy').format(_endDate!) : '--'})),
      ],
      // ── Execution day & time: the day picker only offers execution days
      // matching the chosen frequency; the time defaults to 09:00 AM.
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.notifications_active_rounded, size: 18, color: Color(0xFFD32F2F)),
            const SizedBox(width: 8),
            Expanded(child: Text(AppLocalizations.of(context).translate('recurringExecDayTimeTitle'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 4),
          Text(AppLocalizations.of(context).translate('recurringExecDayTimeHint'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () async {
              if (_frequency == null) {
                _warn('recurringChooseDurationFirst');
                return;
              }
              final now = DateTime.now();
              final today = DateTime(now.year, now.month, now.day);
              var initial = _startDate ?? today;
              if (initial.isBefore(today)) initial = today;
              final picked = await showDatePicker(
                  context: context,
                  initialDate: initial,
                  firstDate: today,
                  lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                  selectableDayPredicate: (day) =>
                      isRecurringExecDaySelectable(_frequency, _startDate, day));
              if (picked != null) setState(() => _startDate = picked);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
              child: Row(children: [
                const Icon(Icons.calendar_today_rounded, size: 18, color: Color(0xFFD32F2F)),
                const SizedBox(width: 10),
                Expanded(child: Text(AppLocalizations.of(context).translate('startDate'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13))),
                Text(
                  _startDate != null ? DateFormat('dd/MM/yyyy').format(_startDate!) : AppLocalizations.of(context).translate('recurringNotSpecified'),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: _startDate != null ? AppColors.textPrimary : AppColors.textSecondary),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () async {
              final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: 9, minute: 0));
              if (picked != null) setState(() => _reminderTime = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
              child: Row(children: [
                const Icon(Icons.access_time_rounded, size: 18, color: Color(0xFFD32F2F)),
                const SizedBox(width: 10),
                Expanded(child: Text(AppLocalizations.of(context).translate('recurringReminderTimeLabel'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13))),
                Text(
                  _reminderTime ?? AppLocalizations.of(context).translate('recurringDefaultTime'),
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ]),
            ),
          ),
          if (_startDate != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              const Icon(Icons.info_outline, size: 14, color: Color(0xFF1565C0)),
              const SizedBox(width: 6),
              Expanded(child: Text(
                '${DateFormat('dd/MM/yyyy').format(_startDate!)} • ${_reminderTime ?? '09:00'}',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF1565C0), fontWeight: FontWeight.w600),
              )),
            ]),
          ],
        ]),
      ),
    ]);
  }

  Widget _intervalRow(String label, int value, int min, int max, String unit) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(
        children: [
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(width: 8),
          Icon(Icons.swap_vert_rounded, size: 16, color: const Color(0xFFD32F2F)),
          const SizedBox(width: 4),
          Text(AppLocalizations.of(context).translate('recurringDragHint'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textDisabled)),
        ],
      ),
      const SizedBox(height: 8),
      Container(
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: ListWheelScrollView(
          controller: FixedExtentScrollController(initialItem: value - 1),
          itemExtent: 52,
          physics: const FixedExtentScrollPhysics(),
          diameterRatio: 1.5,
          perspective: 0.003,
          onSelectedItemChanged: (i) {
            final newVal = i + 1;
            setState(() {
              _intervalValue = newVal;
              if (_startDate != null) {
                if (_frequency == 'weekly') _endDate = _startDate!.add(Duration(days: 7 * newVal));
                else if (_frequency == 'monthly') _endDate = DateTime(_startDate!.year, _startDate!.month + newVal, _startDate!.day);
                else if (_frequency == 'yearly') _endDate = DateTime(_startDate!.year + newVal, _startDate!.month, _startDate!.day);
              }
            });
          },
          children: List.generate(max - min + 1, (i) {
            final val = i + min;
            final isSelected = val == value;
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: isSelected ? BoxDecoration(
                  color: const Color(0xFFD32F2F).withAlpha(15),
                  borderRadius: BorderRadius.circular(8),
                ) : null,
                child: Text('$val $unit', style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    color: isSelected ? const Color(0xFFD32F2F) : AppColors.textSecondary)),
              ),
            );
          }),
        ),
      ),
    ]);
  }

  Widget _dateInfo(String text) {
    return Container(
      margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFD32F2F).withAlpha(10), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFD32F2F).withAlpha(30))),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 16, color: Color(0xFFD32F2F)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: const Color(0xFFD32F2F)))),
      ]),
    );
  }

  // ── Step 5: Account ──
  Widget _stepAccount() {
    final accounts = ref.watch(personalFinanceProvider).bankAccounts;

    final grouped = <String, List<PersonalBankAccount>>{};
    for (final acc in accounts) {
      grouped.putIfAbsent(acc.bankName, () => []).add(acc);
    }
    final bankNames = grouped.keys.toList();
    final selectedBankAccounts = _bankAccountId != null
        ? accounts.where((a) => a.id == _bankAccountId).toList()
        : [];
    final selectedBankName = selectedBankAccounts.isNotEmpty ? selectedBankAccounts.first.bankName : null;
    final bankAccounts = selectedBankName != null ? (grouped[selectedBankName] ?? []) : [];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringStepAccount'), AppLocalizations.of(context).translate('recurringAccountHint')),
      const SizedBox(height: 16),
      _buildRadioOption(AppLocalizations.of(context).translate('recurringFixedAccount'), AppLocalizations.of(context).translate('recurringFixedAccountDesc'), _accountType == 'fixed', () => setState(() => _accountType = 'fixed')),
      const SizedBox(height: 10),
      _buildRadioOption(AppLocalizations.of(context).translate('recurringPickAtExecution'), AppLocalizations.of(context).translate('recurringPickAtExecutionDesc'), _accountType == 'pick_at_execution', () => setState(() { _accountType = 'pick_at_execution'; _bankAccountId = null; })),
      if (_accountType == 'fixed') ...[
        const SizedBox(height: 16),
        Text(_type == 'income' ? AppLocalizations.of(context).translate('recurringIncomeToWhich') : AppLocalizations.of(context).translate('recurringExpenseFromWhich'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
        const SizedBox(height: 10),
        if (accounts.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
            child: Text(AppLocalizations.of(context).translate('noBankAccounts'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
          )
        else if (_bankAccountId == null) ...[
          ...bankNames.map((name) {
            final accs = grouped[name]!;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => setState(() {
                  _bankAccountId = accs.first.id;
                }),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(children: [
                    Icon(Icons.account_balance_rounded, color: AppColors.textSecondary, size: 22),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(isCashAccount(name) ? cashDisplayName() : name, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(AppLocalizations.of(context).translate('recurringAccountsCount', params: {'count': accs.length, 'count2': accs.length}),
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                    ])),
                    Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
                  ]),
                ),
              ),
            );
          }),
        ] else ...[
          GestureDetector(
            onTap: () => setState(() { _bankAccountId = null; }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Icon(Icons.arrow_back_rounded, size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Text(AppLocalizations.of(context).translate('recurringBackToBanks'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary)),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          ...bankAccounts.map((acc) {
            final selected = _bankAccountId == acc.id;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => setState(() {
                  _bankAccountId = acc.id;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFFD32F2F).withAlpha(10) : AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: selected ? const Color(0xFFD32F2F) : AppColors.border, width: selected ? 2 : 1),
                  ),
                  child: Row(children: [
                    Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: selected ? const Color(0xFFD32F2F) : AppColors.textSecondary, size: 22),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(child: Text(acc.currency, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600,
                            color: selected ? AppColors.textPrimary : AppColors.textSecondary))),
                        PersonalAccountTypeTag(accounts: List<PersonalBankAccount>.from(bankAccounts), account: acc),
                      ]),
                      Text(AppLocalizations.of(context).translate('recurringBalanceIs', params: {'balance': fmtNum(acc.balance)}), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                    ])),
                  ]),
                ),
              ),
            );
          }),
        ],
      ],
    ]);
  }

  List<String> _bankCurrencyOptions(String bankCurrency) {
    return [bankCurrency];
  }

  Widget _buildConversionInfo(String fromCurrency, String toCurrency) {
    final engine = ref.read(currencyEngineProvider);
    final rate = engine.getRate(toCurrency, fromCurrency);
    if (rate == null) return const SizedBox.shrink();
    final amount = _amount;
    final converted = amount * rate;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1565C0).withAlpha(10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1565C0).withAlpha(30)),
      ),
      child: Row(children: [
        const Icon(Icons.swap_horiz_rounded, size: 16, color: Color(0xFF1565C0)),
        const SizedBox(width: 8),
        Expanded(child: Text(
          AppLocalizations.of(context).translate('recurringConvertHint', params: {'amount': fmtNum(converted), 'from': fromCurrency, 'to': toCurrency, 'rate': rate.toStringAsFixed(2)}),
          style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: const Color(0xFF1565C0)),
        )),
      ]),
    );
  }

  // ── Step 6: Execution ──
  Widget _stepExecution() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringExecMethodTitle'), AppLocalizations.of(context).translate('recurringExecMethodHint')),
      const SizedBox(height: 16),
      _buildRadioOption(AppLocalizations.of(context).translate('recurringAutoExec'), AppLocalizations.of(context).translate('recurringAutoExecDesc'), _executionType == 'auto', () => setState(() => _executionType = 'auto')),
      const SizedBox(height: 10),
      _buildRadioOption(AppLocalizations.of(context).translate('recurringReminderConfirm'), AppLocalizations.of(context).translate('recurringReminderConfirmDesc'), _executionType == 'reminder', () => setState(() => _executionType = 'reminder')),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _executionType == 'auto' ? const Color(0xFF66BB6A).withAlpha(10) : const Color(0xFF1565C0).withAlpha(10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: (_executionType == 'auto' ? const Color(0xFF66BB6A) : const Color(0xFF1565C0)).withAlpha(30)),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 16, color: _executionType == 'auto' ? const Color(0xFF66BB6A) : const Color(0xFF1565C0)),
          const SizedBox(width: 8),
          Expanded(child: Text(
            _executionType == 'auto'
                ? AppLocalizations.of(context).translate('recurringAutoHint')
                : AppLocalizations.of(context).translate('recurringReminderHint'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: _executionType == 'auto' ? const Color(0xFF66BB6A) : const Color(0xFF1565C0)),
          )),
        ]),
      ),
      const SizedBox(height: 16),
      // ── Notification info ──
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(AppLocalizations.of(context).translate('recurringNotifTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          _notifInfo(AppLocalizations.of(context).translate('recurringNotif2Days'), Icons.notifications_none_rounded),
          _notifInfo(AppLocalizations.of(context).translate('recurringNotif1Day'), Icons.notifications_active_outlined),
          _notifInfo(AppLocalizations.of(context).translate('recurringNotifMinutes'), Icons.alarm_rounded),
          _notifInfo(AppLocalizations.of(context).translate('recurringNotifSameTime'), Icons.notifications_active),
        ]),
      ),
    ]);
  }

  Widget _notifInfo(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
      ]),
    );
  }

  // ── Step 7: Review ──
  Widget _stepReview() {
    final isIncome = _type == 'income';
    final intervalText = _frequency == null
        ? AppLocalizations.of(context).translate('recurringNotSpecified')
        : _frequency == 'daily' ? AppLocalizations.of(context).translate('recurringDaily')
        : _frequency == 'weekly' ? AppLocalizations.of(context).translate('recurringEveryXWeeks', params: {'count': _intervalValue})
        : _frequency == 'monthly' ? AppLocalizations.of(context).translate('recurringEveryXMonths', params: {'count': _intervalValue})
        : AppLocalizations.of(context).translate('recurringEveryXYears', params: {'count': _intervalValue});
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepHeader(AppLocalizations.of(context).translate('recurringReviewTitle'), AppLocalizations.of(context).translate('recurringReviewHint')),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
        child: Column(children: [
          _reviewRow(AppLocalizations.of(context).translate('treeTypeLabel'), isIncome ? AppLocalizations.of(context).translate('income') : AppLocalizations.of(context).translate('expense'), isIncome ? const Color(0xFF66BB6A) : const Color(0xFFD32F2F)),
          _reviewRow(AppLocalizations.of(context).translate('nameLabel'), _nameCtrl.text, AppColors.textPrimary),
          _reviewRow(AppLocalizations.of(context).translate('categoryLabel'), _category, AppColors.textPrimary),
          _reviewRow(AppLocalizations.of(context).translate('amountLabel'), '${fmtNum(_amount)} $_currency', const Color(0xFFD32F2F)),
          _reviewRow(AppLocalizations.of(context).translate('frequency'), intervalText, AppColors.textPrimary),
          _reviewRow(AppLocalizations.of(context).translate('startDate'), _startDate != null ? DateFormat('dd/MM/yyyy').format(_startDate!) : AppLocalizations.of(context).translate('recurringNotSpecified'), AppColors.textPrimary),
          if (_endDate != null) _reviewRow(AppLocalizations.of(context).translate('endDate'), DateFormat('dd/MM/yyyy').format(_endDate!), AppColors.textPrimary),
          _reviewRow(AppLocalizations.of(context).translate('recurringStepAccount'), _accountType == 'fixed' ? (_bankAccountId != null ? AppLocalizations.of(context).translate('recurringFixedLabel') : AppLocalizations.of(context).translate('recurringNotSpecified')) : AppLocalizations.of(context).translate('recurringPickAtExecShort'), AppColors.textPrimary),
          _reviewRow(AppLocalizations.of(context).translate('recurringStepExecution'), _executionType == 'auto' ? AppLocalizations.of(context).translate('recurringAutoShort') : AppLocalizations.of(context).translate('recurringReminderConfirm'), AppColors.textPrimary),
          if (_reminderTime != null) _reviewRow(AppLocalizations.of(context).translate('recurringTimeLabel'), _reminderTime!, AppColors.textPrimary),
        ]),
      ),
    ]);
  }

  Widget _reviewRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
        Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: valueColor)),
      ]),
    );
  }

  Widget _buildRadioOption(String title, String subtitle, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFD32F2F).withAlpha(10) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? const Color(0xFFD32F2F) : AppColors.border, width: selected ? 2 : 1),
        ),
        child: Row(children: [
          Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, color: selected ? const Color(0xFFD32F2F) : AppColors.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
            Text(subtitle, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
          ])),
        ]),
      ),
    );
  }

  Widget _datePicker(String label, DateTime? current, ValueChanged<DateTime> onPicked) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(context: context, initialDate: current ?? DateTime.now(),
            firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now().add(const Duration(days: 365 * 3)));
        if (picked != null) onPicked(picked);
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: Row(children: [
          const Icon(Icons.calendar_today_rounded, size: 18, color: Color(0xFFD32F2F)),
          const SizedBox(width: 10),
          Text(current != null ? DateFormat('dd/MM/yyyy').format(current) : label,
              style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: current != null ? AppColors.textPrimary : AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _buildNavigationButtons() {
    return Container(
      padding: const EdgeInsets.all(16), color: AppColors.surface,
      child: Row(children: [
        if (_currentStep > 0)
          Expanded(child: OutlinedButton(
            onPressed: _prevStep,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, backgroundColor: const Color(0xFF212121),
                side: const BorderSide(color: Color(0xFF212121)), padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(AppLocalizations.of(context).translate('previous'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
          )),
        if (_currentStep > 0) const SizedBox(width: 12),
        Expanded(child: ElevatedButton(
          onPressed: _currentStep < 7 ? (_canProceed() ? _nextStep : null) : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFF212121).withAlpha(80), disabledForegroundColor: Colors.white54,
              padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
          child: Text(_currentStep < 7 ? AppLocalizations.of(context).translate('next') : (_isEdit ? AppLocalizations.of(context).translate('saveChanges') : AppLocalizations.of(context).translate('recurringCreateTx')),
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold)),
        )),
      ]),
    );
  }
}

class _TypeCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;
  const _TypeCard({required this.label, required this.icon, required this.color, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? color.withAlpha(15) : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isSelected ? color : AppColors.border, width: isSelected ? 2 : 1),
        ),
        child: Column(children: [
          Icon(icon, size: 36, color: isSelected ? color : AppColors.textSecondary),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold, color: isSelected ? color : AppColors.textSecondary)),
        ]),
      ),
    );
  }
}
