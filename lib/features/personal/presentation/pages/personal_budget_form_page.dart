import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../personal/domain/services/exchange_rate_service.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class PersonalBudgetFormPage extends ConsumerStatefulWidget {
  const PersonalBudgetFormPage({super.key});
  @override
  ConsumerState<PersonalBudgetFormPage> createState() => _PersonalBudgetFormPageState();
}

class _PersonalBudgetFormPageState extends ConsumerState<PersonalBudgetFormPage>
    with SingleTickerProviderStateMixin {
  int _currentStep = 0;
  bool _isEdit = false;
  String _editId = '';

  final _nameCtrl = TextEditingController();
  final _totalAmountCtrl = TextEditingController();
  final _amountFocusNode = FocusNode();
  final _amountKey = GlobalKey();

  String _periodType = 'monthly';
  DateTime? _startDate;
  DateTime? _endDate;
  int? _customDays;
  double _totalAmount = 0;
  String _currency = 'USD';
  bool _currencyTouched = false;
  final Set<String> _selectedBudgetTypes = {'expenses'};
  final Map<String, double> _categoryAmounts = {};
  final Set<String> _customExpenseCategories = {};
  // Per-category amount controllers: TextFields without controllers lose
  // their visible text whenever the step rebuilds (Back/Next unmounts them),
  // so amounts LOOKED reset even though the map kept them. Controllers keep
  // exactly what the user typed until the user changes it.
  final Map<String, TextEditingController> _amountCtrls = {};
  String? _stepError;
  static const _suggestedCategories = [
    'طعام وشراب', 'مواصلات', 'سكن وإيجار', 'فواتير', 'تسوق',
    'صحة', 'تعليم', 'ترفيه', 'ملابس', 'هدايا',
  ];
  final _customCategoryCtrl = TextEditingController();

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  static const _periodOptions = [
    ('daily', 'budgetPeriodDaily', Icons.today_rounded),
    ('weekly', 'budgetPeriodWeekly', Icons.view_week_rounded),
    ('custom_days', 'budgetPeriodCustomDays', Icons.date_range_rounded),
    ('date_range', 'budgetPeriodDateRange', Icons.calendar_month_rounded),
    ('monthly', 'budgetPeriodMonthly', Icons.calendar_view_month_rounded),
    ('yearly', 'budgetPeriodYearly', Icons.event_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 25).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );
    _resolveCurrencyDefault();
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final extra = GoRouterState.of(context).extra;
    if (extra is Map<String, dynamic> && !_isEdit) {
      final rawBudget = extra['budget'];
      PersonalBudget? budget;
      if (rawBudget is PersonalBudget) {
        budget = rawBudget;
      } else if (rawBudget is Map<String, dynamic>) {
        budget = PersonalBudget.fromJson(rawBudget);
      }
      if (budget != null) {
        _isEdit = true;
        _editId = budget.id;
        _nameCtrl.text = budget.name;
        _periodType = budget.periodType;
        _startDate = budget.startDate;
        _endDate = budget.endDate;
        _customDays = budget.customDays;
        _totalAmount = budget.totalAmount;
        _totalAmountCtrl.text = budget.totalAmount.toStringAsFixed(0);
        _currency = budget.currency;
        _currencyTouched = true;
        _selectedBudgetTypes.clear();
        _selectedBudgetTypes.addAll(budget.budgetTypes);
        for (final cat in budget.categories) {
          _categoryAmounts[cat.name] = cat.allocatedAmount;
          if (cat.type == 'expense') {
            _customExpenseCategories.add(cat.name);
          }
        }
      }
    }
  }

  TextEditingController _amountCtrlFor(String catName) {
    return _amountCtrls.putIfAbsent(catName, () {
      final v = _categoryAmounts[catName] ?? 0;
      return TextEditingController(
        text: v > 0 ? (v == v.roundToDouble() ? v.toInt().toString() : v.toString()) : '',
      );
    });
  }

  void _dropAmountCtrl(String catName) {
    _amountCtrls.remove(catName)?.dispose();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _totalAmountCtrl.dispose();
    _amountFocusNode.dispose();
    _shakeController.dispose();
    _customCategoryCtrl.dispose();
    for (final c in _amountCtrls.values) {
      c.dispose();
    }
    _amountCtrls.clear();
    super.dispose();
  }

  List<String> _getAvailableCategories() {
    return _customExpenseCategories.toList();
  }

  bool _canProceed() {
    switch (_currentStep) {
      case 0: return _nameCtrl.text.trim().isNotEmpty;
      case 1: return true;
      case 2: return true;
      case 3: return _selectedBudgetTypes.isNotEmpty || _customExpenseCategories.isNotEmpty;
      case 4: return _totalAmount > 0 && _totalCategoryAmount <= _totalAmount;
      default: return true;
    }
  }

  double get _totalCategoryAmount {
    return _categoryAmounts.values.fold<double>(0, (s, v) => s + v);
  }

  void _nextStep() {
    if (_currentStep == 4 && _totalAmount <= 0) {
      _shakeAmountField();
      return;
    }
    if (_currentStep == 4 && _totalCategoryAmount > _totalAmount) {
      HapticFeedback.heavyImpact();
      return;
    }
    if (_currentStep == 4) {
      // Every selected category must carry an amount: block Next naming the
      // first offender so the user either types it or removes the category.
      // (Zero-amount categories never reach the server state silently.)
      final missing = _customExpenseCategories
          .where((c) => (_categoryAmounts[c] ?? 0) <= 0)
          .toList();
      if (missing.isNotEmpty) {
        HapticFeedback.heavyImpact();
        setState(() {
          _stepError = AppLocalizations.of(context).translate(
            'budgetCatAmountRequired',
            params: {'name': missing.first},
          );
        });
        return;
      }
      _stepError = null;
    }
    if (_currentStep < 5 && _canProceed()) {
      setState(() => _currentStep++);
      // Scroll to amount field when entering step 4
      if (_currentStep == 4) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _amountKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 400), curve: Curves.easeInOut, alignment: 0.3);
          }
          _amountFocusNode.requestFocus();
        });
      }
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }

  void _shakeAmountField() {
    _shakeController.forward(from: 0);
    HapticFeedback.heavyImpact();
    // Wait for animation frame to settle before scrolling
    Future.delayed(const Duration(milliseconds: 100), () {
      final ctx = _amountKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut, alignment: 0.2);
      }
      _amountFocusNode.requestFocus();
    });
  }

  Future<void> _submit() async {
    if (_nameCtrl.text.trim().isEmpty || _totalAmount <= 0) return;

    final categories = <BudgetCategory>[];
    for (final catName in _customExpenseCategories) {
      final amount = _categoryAmounts[catName] ?? 0;
      categories.add(BudgetCategory(id: '', name: catName, type: 'expense', allocatedAmount: amount, currency: _currency));
    }

    final budget = PersonalBudget(
      id: _isEdit ? _editId : '',
      name: _nameCtrl.text.trim(),
      periodType: _periodType,
      startDate: _startDate,
      endDate: _endDate,
      customDays: _customDays,
      totalAmount: _totalAmount,
      currency: _currency,
      budgetTypes: _selectedBudgetTypes.toList(),
      categories: categories,
    );

    HapticFeedback.lightImpact();
    final budgetNotifier = ref.read(budgetProvider.notifier);
    if (_isEdit) {
      await budgetNotifier.updateBudget(budget);
    } else {
      await budgetNotifier.addBudget(budget);
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_isEdit ? l10n.translate('editBudget') : l10n.translate('budgetCreateNew'),
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
      ),
      body: Column(
        children: [
          _buildStepIndicator(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _buildCurrentStep(),
            ),
          ),
          _buildNavigationButtons(),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    final l10n = AppLocalizations.of(context);
    final steps = [l10n.translate('nameLabel'), l10n.translate('currencyLabel'), l10n.translate('periodLabel'), l10n.translate('budgetSections'), l10n.translate('amount'), l10n.translate('budgetReview')];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: AppColors.surface,
      child: Row(
        children: List.generate(steps.length, (i) {
          final isActive = i == _currentStep;
          final isDone = i < _currentStep;
          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 26, height: 26,
                  decoration: BoxDecoration(
                    color: isDone ? AppColors.primary : isActive ? AppColors.primary.withAlpha(30) : AppColors.border,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: isDone
                        ? const Icon(Icons.check, size: 13, color: Colors.white)
                        : Text('${i + 1}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                            color: isActive ? AppColors.primary : AppColors.textSecondary)),
                  ),
                ),
                if (i < steps.length - 1) Expanded(child: Container(height: 2, color: isDone ? AppColors.primary : AppColors.border)),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case 0: return _buildStepName();
      case 1: return _buildStepCurrency();
      case 2: return _buildStepPeriod();
      case 3: return _buildStepTypes();
      case 4: return _buildStepAmount();
      case 5: return _buildStepReview();
      default: return const SizedBox.shrink();
    }
  }

  // ── Step 0: Name ──
  Widget _buildStepName() {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader(l10n.translate('budgetNameTitle'), l10n.translate('budgetNameSubtitle')),
        const SizedBox(height: 16),
        FyonaTextField(
          controller: _nameCtrl,
          decoration: InputDecoration(
            hintText: l10n.translate('budgetNameHint'),
            hintStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textDisabled),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.primary, width: 2)),
            contentPadding: const EdgeInsets.all(16),
          ),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 15),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // ── Step 1: Currency (user-enabled only) ──
  Widget _buildStepCurrency() {
    final l10n = AppLocalizations.of(context);
    final enabledAsync = ref.watch(enabledCurrenciesProvider);
    return enabledAsync.when(
      data: (enabled) {
        final currencies = enabled.where((code) =>
            ExchangeRateService.supportedCurrencies.containsKey(code)).toList();
        if (currencies.isEmpty) currencies.addAll(['SAR', 'USD', 'YER']);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _stepHeader(l10n.translate('budgetCurrencyTitle'), l10n.translate('budgetCurrencySubtitle')),
            const SizedBox(height: 8),
            Text(l10n.translate('budgetCurrencyNote'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            ...currencies.map((code) {
              final name = ExchangeRateService.localizedName(code);
              final symbol = ExchangeRateService.localizedSymbol(code);
              final selected = _currency == code;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GestureDetector(
                  onTap: () =>
                  setState(() => {_currency = code, _currencyTouched = true}),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primary.withAlpha(20) : AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? AppColors.primary : AppColors.border,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: selected ? AppColors.primary.withAlpha(25) : AppColors.background,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(child: Text(symbol, style: TextStyle(
                              fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold,
                              color: selected ? AppColors.primary : AppColors.textSecondary))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
                              Text(code, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                        if (selected) Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 22),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
      loading: () => const Center(child: DotsLoader()),
      error: (_, __) => Center(child: Text(AppLocalizations.of(context).translate('budgetCurrencyError'))),
    );
  }

  // ── Step 2: Period ──
  Widget _buildStepPeriod() {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader(l10n.translate('budgetPeriodTitle'), l10n.translate('budgetPeriodSubtitle')),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1.1,
          children: _periodOptions.map((p) {
            final selected = _periodType == p.$1;
            return GestureDetector(
              onTap: () {
                setState(() {
                  _periodType = p.$1;
                  // Auto-set dates based on period
                  final now = DateTime.now();
                  if (p.$1 == 'daily') {
                    _startDate = now;
                    _endDate = now.add(const Duration(days: 1));
                  } else if (p.$1 == 'weekly') {
                    _startDate = now;
                    _endDate = now.add(const Duration(days: 7));
                  } else if (p.$1 == 'monthly') {
                    _startDate = now;
                    _endDate = DateTime(now.year, now.month + 1, 0);
                  } else if (p.$1 == 'yearly') {
                    _startDate = now;
                    _endDate = DateTime(now.year, 12, 31);
                  }
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primary.withAlpha(25) : AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                    Icon(p.$3, size: 24, color: selected ? AppColors.primary : AppColors.textSecondary),
                    const SizedBox(height: 6),
                    Text(l10n.translate(p.$2), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w600,
                        color: selected ? AppColors.primary : AppColors.textSecondary)),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        // Show date info based on period
        if (_periodType == 'daily') ...[
          _datePicker(l10n.translate('budgetPickDay'), _startDate, (d) {
            setState(() {
              _startDate = d;
              _endDate = d.add(const Duration(days: 1));
            });
          }),
          if (_startDate != null)
            _dateInfo(l10n.translate('budgetDailyInfo', params: {'date': DateFormat('dd/MM/yyyy').format(_startDate!)})),
        ],
        if (_periodType == 'weekly') ...[
          _datePicker(l10n.translate('budgetPickWeekStart'), _startDate, (d) {
            setState(() {
              _startDate = d;
              _endDate = d.add(const Duration(days: 7));
            });
          }),
          if (_startDate != null && _endDate != null)
            _dateInfo(l10n.translate('budgetWeeklyInfo', params: {'start': DateFormat('dd/MM/yyyy').format(_startDate!), 'end': DateFormat('dd/MM/yyyy').format(_endDate!)})),
        ],
        if (_periodType == 'custom_days')
          FyonaTextField(
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: l10n.translate('budgetDaysHint'),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding: const EdgeInsets.all(16),
            ),
            onChanged: (v) {
              final days = int.tryParse(v);
              if (days != null && days > 0) {
                setState(() {
                  _customDays = days;
                  _startDate = DateTime.now();
                  _endDate = DateTime.now().add(Duration(days: days));
                });
              }
            },
          ),
        if (_periodType == 'date_range') ...[
          _datePicker(l10n.translate('startDate'), _startDate, (d) => setState(() => _startDate = d)),
          const SizedBox(height: 12),
          _datePicker(l10n.translate('endDate'), _endDate, (d) => setState(() => _endDate = d)),
        ],
        // Always show start/end dates
        if (_startDate != null && _endDate != null && !['daily', 'weekly'].contains(_periodType))
          _dateInfo('${l10n.translate('fromLabel')} ${DateFormat('dd/MM/yyyy').format(_startDate!)} ${l10n.translate('toLabel')} ${DateFormat('dd/MM/yyyy').format(_endDate!)}'),
      ],
    );
  }

  Widget _dateInfo(String text) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withAlpha(30)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.primary))),
        ],
      ),
    );
  }

  // ── Step 3: Budget Categories (manual input only) ──
  Widget _buildStepTypes() {
    final l10n = AppLocalizations.of(context);
    final cats = _customExpenseCategories.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader(l10n.translate('budgetTypeTitle'), l10n.translate('budgetTypeSubtitle')),
        const SizedBox(height: 16),
        FyonaTextField(
          controller: _customCategoryCtrl,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _addCustomCategory(),
          decoration: InputDecoration(
            hintText: l10n.translate('budgetNewCatHint'),
            hintStyle: TextStyle(fontFamily: 'Cairo', color: Colors.grey),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.primary, width: 2)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            suffixIcon: IconButton(
              icon: Icon(Icons.add_circle_rounded, color: AppColors.primary, size: 28),
              onPressed: _addCustomCategory,
            ),
          ),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 15),
        ),
        const SizedBox(height: 16),
        if (cats.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Icon(Icons.category_outlined, size: 40, color: AppColors.textDisabled),
                const SizedBox(height: 8),
                Text(l10n.translate('budgetAddAtLeastOne') ?? 'اكتب اسم القسم واضغط +',
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
              ],
            ),
          ),
        if (cats.isNotEmpty)
          ...cats.map((cat) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Icon(Icons.label_rounded, color: AppColors.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(cat, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                ),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      _customExpenseCategories.remove(cat);
                      _categoryAmounts.remove(cat);
                      _dropAmountCtrl(cat);
                      _stepError = null;
                    });
                  },
                  child: Icon(Icons.close_rounded, color: Colors.red.shade300, size: 20),
                ),
              ],
            ),
          )),
      ],
    );
  }

  void _addCustomCategory() {
    final name = _customCategoryCtrl.text.trim();
    if (name.isNotEmpty && !_customExpenseCategories.contains(name)) {
      HapticFeedback.lightImpact();
      setState(() {
        _customExpenseCategories.add(name);
        _customCategoryCtrl.clear();
      });
    }
  }

  // ── Step 4: Total Amount (required) + Category Distribution (optional) ──
  Widget _buildStepAmount() {
    final l10n = AppLocalizations.of(context);
    final categories = _getAvailableCategories();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader(l10n.translate('budgetAmount'), l10n.translate('budgetAmountSubtitle')),
        const SizedBox(height: 12),
        // Total amount - REQUIRED with shake
        AnimatedBuilder(
          animation: _shakeAnimation,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(_shakeAnimation.value, 0),
              child: child,
            );
          },
          child: Container(
            key: _amountKey,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _totalAmount > 0 ? AppColors.primary.withAlpha(15) : Color(0xFFB71C1C).withAlpha(15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _totalAmount > 0 ? AppColors.primary.withAlpha(40) : Color(0xFFEF5350).withAlpha(60),
                width: _totalAmount > 0 ? 1 : 2,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.account_balance_wallet_rounded,
                    color: _totalAmount > 0 ? AppColors.primary : Color(0xFFEF5350), size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.translate('budgetTotalRequired'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _totalAmount > 0 ? AppColors.textSecondary : Color(0xFFEF5350))),
                      FyonaTextField(
                        controller: _totalAmountCtrl,
                        focusNode: _amountFocusNode,
                        keyboardType: TextInputType.number,
                        inputFormatters: [AmountInputFormatter()],
                        style: const TextStyle(fontFamily: 'Cairo', fontSize: 22, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          hintText: '0',
                          hintStyle: TextStyle(color: AppColors.textDisabled),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          suffixText: ' $_currency',
                          suffixStyle: TextStyle(fontSize: 14, color: AppColors.textSecondary, fontFamily: 'Cairo'),
                        ),
                        onChanged: (v) {
                          _totalAmount = double.tryParse(v.replaceAll(',', '')) ?? 0;
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_totalAmount <= 0)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Text(l10n.translate('budgetAmountRequired'), style: TextStyle(
                fontFamily: 'Cairo', fontSize: 11, color: Color(0xFFEF5350), fontWeight: FontWeight.w600)),
          ),
        if (_totalCategoryAmount > _totalAmount && _totalAmount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Text(l10n.translate('budgetCatsExceed', params: {'cats': fmtNum(_totalCategoryAmount), 'total': fmtNum(_totalAmount)}), style: TextStyle(
                fontFamily: 'Cairo', fontSize: 11, color: Color(0xFFEF5350), fontWeight: FontWeight.w600)),
          ),
        if (_stepError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Text(_stepError!, style: TextStyle(
                fontFamily: 'Cairo', fontSize: 11, color: Color(0xFFEF5350), fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 20),
        // Category distribution (optional)
        if (categories.isNotEmpty) ...[
          Text(l10n.translate('budgetDistribute'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13,
              fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          const SizedBox(height: 10),
          ...categories.map((catName) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(catName, style:  TextStyle(fontFamily: 'Cairo', fontSize: 13,
                          fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: FyonaTextField(
                        controller: _amountCtrlFor(catName),
                        keyboardType: TextInputType.number,
                        inputFormatters: [AmountInputFormatter()],
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          hintText: '0',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          suffixText: ' $_currency',
                          suffixStyle: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontFamily: 'Cairo'),
                        ),
                        style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600),
                        onChanged: (v) {
                          _categoryAmounts[catName] = double.tryParse(v.replaceAll(',', '')) ?? 0;
                          _stepError = null;
                          setState(() {});
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          _buildDistributionSummary(categories),
        ],
      ],
    );
  }

  Widget _buildDistributionSummary(List<String> categories) {
    final l10n = AppLocalizations.of(context);
    final distributed = categories.fold<double>(0, (s, c) => s + (_categoryAmounts[c] ?? 0));
    final remaining = _totalAmount - distributed;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: remaining >= 0 ? const Color(0xFF1B5E20).withAlpha(20) : const Color(0xFFB71C1C).withAlpha(20),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _MiniStat(label: l10n.translate('budgetDistributed'), value: fmtNum(distributed)),
          _MiniStat(label: l10n.translate('remainingLabel'), value: fmtNum(remaining.abs()),
              color: remaining >= 0 ? const Color(0xFF66BB6A) : const Color(0xFFEF5350)),
        ],
      ),
    );
  }

  // ── Step 5: Review ──
  Widget _buildStepReview() {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader(l10n.translate('budgetReviewTitle'), l10n.translate('budgetReviewSubtitle')),
        const SizedBox(height: 16),
        _reviewItem(l10n.translate('nameLabel'), _nameCtrl.text),
        _reviewItem(l10n.translate('currencyLabel'), '$_currency - ${ExchangeRateService.localizedName(_currency)}'),
        _reviewItem(l10n.translate('periodLabel'), _getPeriodLabel()),
        _reviewItem(l10n.translate('budgetTotal'), '${fmtNum(_totalAmount)} $_currency'),
        const SizedBox(height: 16),
        if (_getAvailableCategories().isNotEmpty) ...[
          Text(l10n.translate('categories'), style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold,
              color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          ..._getAvailableCategories().where((cat) => (_categoryAmounts[cat] ?? 0) > 0).map((cat) {
            final amount = _categoryAmounts[cat] ?? 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(cat, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
                  Text(fmtNum(amount), style:  TextStyle(fontFamily: 'Cairo', fontSize: 13,
                      fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }

  String _getPeriodLabel() {
    final l10n = AppLocalizations.of(context);
    switch (_periodType) {
      case 'daily': return l10n.translate('budgetPeriodDaily');
      case 'weekly': return l10n.translate('budgetPeriodWeekly');
      case 'custom_days': return l10n.translate('budgetCustomDaysLabel', params: {'count': _customDays});
      case 'date_range':
        return '${l10n.translate('fromLabel')} ${_startDate != null ? DateFormat('dd/MM').format(_startDate!) : '--'} '
            '${l10n.translate('toLabel')} ${_endDate != null ? DateFormat('dd/MM').format(_endDate!) : '--'}';
      case 'monthly': return l10n.translate('budgetPeriodMonthly');
      case 'yearly': return l10n.translate('budgetPeriodYearly');
      default: return _periodType;
    }
  }

  Widget _stepHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style:  TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold,
            color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _reviewItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
          Flexible(child: Text(value, style:  TextStyle(fontFamily: 'Cairo', fontSize: 13,
              fontWeight: FontWeight.w600, color: AppColors.textPrimary), textAlign: TextAlign.end)),
        ],
      ),
    );
  }

  Widget _datePicker(String label, DateTime? current, ValueChanged<DateTime> onPicked) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: current ?? DateTime.now(),
          firstDate: DateTime.now().subtract(const Duration(days: 365)),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (picked != null) onPicked(picked);
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today_rounded, size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Text(
              current != null ? DateFormat('dd/MM/yyyy').format(current) : label,
              style: TextStyle(fontFamily: 'Cairo', fontSize: 13,
                  color: current != null ? AppColors.textPrimary : AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationButtons() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppColors.surface,
      child: Row(
        children: [
          if (_currentStep > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: _prevStep,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFF212121),
                  side: const BorderSide(color: Color(0xFF212121)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(l10n.translate('previous'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
              ),
            ),
          if (_currentStep > 0) const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: _currentStep < 5 ? (_canProceed() ? _nextStep : null) : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF212121).withAlpha(80),
                disabledForegroundColor: Colors.white54,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Text(
                _currentStep < 5 ? l10n.translate('next') : (_isEdit ? l10n.translate('saveChanges') : l10n.translate('budgetCreate')),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _MiniStat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold,
            color: color ?? AppColors.textPrimary)),
      ],
    );
  }
}
