import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../../di/personal_providers.dart' show personalFinanceServiceProvider;
import '../../domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/shared/widgets/app_icon_badge.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/core/utils/amount_input_formatter.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/services/currency/enabled_currencies_service.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';



/// Shared goal artwork (see [GoalIcons]) so the list and detail pages match.
final _iconChoices = GoalIcons.choices;
const _iconKeys = GoalIcons.keys;

class SavingsGoalsPage extends ConsumerStatefulWidget {
  const SavingsGoalsPage({super.key});
  @override
  ConsumerState<SavingsGoalsPage> createState() => _SavingsGoalsPageState();
}

class _SavingsGoalsPageState extends ConsumerState<SavingsGoalsPage> {
  bool _showAdd = false;
  bool _savingGoal = false;
  String? _contributeId;
  String? _editId;
  final _nameCtrl = TextEditingController();
  final _targetCtrl = TextEditingController();
  String _currency = 'USD';
  bool _currencyTouched = false;
  final _amountCtrl = TextEditingController();
  DateTime? _deadline;
  String _selIcon = 'مدخرات';
  String? _bankId;
  String? _selCurrencyForGoal;
  String? _goalBudgetId;
  bool _contributing = false;
  String? _contribOpId;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _nameCtrl.dispose();
    _targetCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _resetForm() {
    _editId = null;
    _nameCtrl.clear();
    _targetCtrl.clear();
    _currencyTouched = false;
    _resolveCurrencyDefault();
    _deadline = null;
    _selIcon = 'مدخرات';
    _selCurrencyForGoal = null;
    _goalBudgetId = null;
  }

  void _startEdit(SavingsGoal g) {
    _editId = g.id;
    _nameCtrl.text = g.name;
    _targetCtrl.text = g.targetAmount.toStringAsFixed(0);
    _currency = g.currency;
    _currencyTouched = true;
    _deadline = g.deadline != null ? DateTime.tryParse(g.deadline!) : null;
    _selIcon = g.icon.isNotEmpty ? g.icon : 'مدخرات';
    _goalBudgetId = g.budgetId;
    setState(() { _showAdd = true; _contributeId = null; });
  }

  Future<void> _createGoal() async {
    if (_savingGoal) return;
    final l10n = AppLocalizations.of(context);
    final name = _nameCtrl.text.trim();
    final target = double.tryParse(_targetCtrl.text.replaceAll(',', ''));
    if (name.isEmpty || target == null || target <= 0) { _snack(l10n.translate('goalFillAllFields')); return; }
    setState(() => _savingGoal = true);
    final notifier = ref.read(personalFinanceProvider.notifier);
    final deadline = _deadline?.toIso8601String();
    try {
      if (_editId != null) {
        await notifier.updateSavingsGoal(SavingsGoal(
          id: _editId!, name: name, targetAmount: target,
          currency: _currency, deadline: deadline, icon: _selIcon,
          budgetId: _goalBudgetId,
        ));
      } else {
        await notifier.addSavingsGoal(SavingsGoal(
          id: '', name: name, targetAmount: target,
          currency: _currency, deadline: deadline, icon: _selIcon,
          budgetId: _goalBudgetId,
        ));
      }
      _resetForm();
      setState(() { _showAdd = false; _savingGoal = false; });
    } catch (e) {
      setState(() => _savingGoal = false);
      _snack(e.toString());
    }
  }

  Future<void> _contribute(SavingsGoal g) async {
    final l10n = AppLocalizations.of(context);
    final amt = double.tryParse(_amountCtrl.text.replaceAll(',', ''));
    if (amt == null || amt <= 0) { _snack(l10n.translate('enterValidAmount')); return; }
    final st = ref.read(personalFinanceProvider);
    final isCash = _bankId == null || _bankId == '-1' || _bankId!.isEmpty;

    String srcCurrency;
    double srcBalance;
    String? effectiveAccountId;
    String? accName;

    if (!isCash) {
      PersonalBankAccount? resolved =
          st.bankAccounts.where((a) => a.id == _bankId).firstOrNull;
      if (resolved == null) { _snack(l10n.translate('accountNotFound')); return; }
      // Honor the explicitly chosen currency: resolve the exact account of
      // this bank holding it, so the payment is deducted from that currency.
      if (_selCurrencyForGoal != null && resolved.currency != _selCurrencyForGoal) {
        final bankName = resolved.bankName;
        final wantCur = _selCurrencyForGoal;
        final exact = st.bankAccounts
            .where((a) => a.bankName == bankName && a.currency == wantCur)
            .firstOrNull;
        if (exact == null) { _snack(l10n.translate('accountNotFound')); return; }
        resolved = exact;
      }
      srcCurrency = resolved.currency;
      srcBalance = resolved.balance;
      effectiveAccountId = resolved.id;
      accName = resolved.bankName;
    } else {
      // Cash pays from the explicitly chosen currency account (debts-style):
      // the contribution is deducted from that exact cash row, never from a
      // summed-up mixed-currency total.
      final cashAccs =
          st.bankAccounts.where((a) => a.accountType == 'cash').toList();
      PersonalBankAccount? resolved;
      if (_selCurrencyForGoal != null) {
        resolved = cashAccs
            .where((a) => a.currency == _selCurrencyForGoal)
            .firstOrNull;
      }
      resolved ??= cashAccs.length == 1 ? cashAccs.firstOrNull : null;
      if (resolved == null) {
        _snack(l10n.translate('selectCurrency'));
        return;
      }
      srcCurrency = resolved.currency;
      srcBalance = resolved.balance;
      effectiveAccountId = resolved.id;
      accName = l10n.translate('accountTypeCash');
    }

    final double amountToGoal;
    if (srcCurrency != g.currency) {
      // Offline-first: use the last KNOWN cached rate when available. If the
      // rate is unavailable we still record the contribution in the source
      // currency value (goal amount = paid amount) so the user is never
      // blocked offline; a correct converted amount is synced later.
      final rate = _findRate(srcCurrency, g.currency, st.exchangeRates);
      amountToGoal = (rate != null && rate > 0) ? amt * rate : amt;
      if (srcBalance < amt) {
        _snack(l10n.translate('insufficientBalanceRequired', params: {'amount': fmtNum(amt), 'currency': srcCurrency, 'account': accName})); return;
      }
    } else {
      amountToGoal = amt;
      if (srcBalance < amt) {
        _snack(l10n.translate('insufficientBalanceIn', params: {'account': accName})); return;
      }
    }

    // ONE backend call: deduct + credit + linked tx (goal_id + budget_id).
    // Guarded: concurrent taps join one execution; one op id per form
    // session so retries/dedupes collapse server-side too.
    if (_contributing) return;
    _contribOpId ??= ref.read(personalFinanceServiceProvider).newOperationId();
    setState(() => _contributing = true);
    final notifier = ref.read(personalFinanceProvider.notifier);
    try {
      await notifier.contributeToGoal(
        g.id,
        amt,
        goalAmount: amountToGoal,
        currency: srcCurrency,
        bankAccountId: effectiveAccountId,
        paymentMethod: isCash ? 'cash' : 'bank',
        category: 'ادخار - ${g.name}',
        description: l10n.translate('goalDeposit', params: {'name': g.name}),
        clientOperationId: _contribOpId,
      );
      _amountCtrl.clear();
      _bankId = null;
      _selCurrencyForGoal = null;
      _contribOpId = null;
      setState(() => _contributeId = null);
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _contributing = false);
    }
  }

  double? _findRate(String from, String to, List<ExchangeRate> rates) {
    if (from == to) return 1.0;
    try {
      final engine = ref.read(currencyEngineProvider);
      return engine.getRate(from, to);
    } catch (_) {}
    for (final r in rates) {
      if (r.fromCurrency == from && r.toCurrency == to) return r.rate;
    }
    for (final r in rates) {
      if (r.fromCurrency == to && r.toCurrency == from && r.rate != 0) return 1.0 / r.rate;
    }
    return null;
  }

  void _deleteGoal(String id) {
    final l10n = AppLocalizations.of(context);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.translate('deleteGoalTitle'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      content: Text(l10n.translate('confirmDeleteGoal'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))),
        TextButton(onPressed: () async {
          Navigator.pop(ctx);
          final ok = await ref.read(personalFinanceProvider.notifier).deleteSavingsGoal(id);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Row(children: [
              Icon(ok ? Icons.check_circle : Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text(
                ok ? l10n.translate('deletedSuccessfully') : l10n.translate('personalErrDeleteGoal'),
                style: const TextStyle(fontFamily: 'Cairo', color: Colors.white, fontWeight: FontWeight.w600),
              )),
            ]),
            backgroundColor: ok ? AppColors.success : AppColors.danger,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 2),
          ));
        }, child: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))),
      ],
    ));
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: TextStyle(fontFamily: 'Cairo')),
    backgroundColor: AppColors.surface,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  ));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = ref.watch(personalFinanceProvider);
    final goals = st.savingsGoals;
    final totalTarget = goals.fold<double>(0, (s, g) => s + g.targetAmount);
    final totalSaved = goals.fold<double>(0, (s, g) => s + g.currentAmount);
    final completedCount = goals.where((g) => g.currentAmount >= g.targetAmount).length;
    final primaryCurrency = goals.isNotEmpty ? goals.first.currency : 'USD';

    return st.isLoading
          ? Center(child: DotsLoader())
          : CustomScrollView(
              physics: BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              slivers: [
                SliverPadding(padding: EdgeInsets.fromLTRB(20, 16, 20, 100), sliver: SliverList.list(children: [
                  // ═══ ADD BUTTON ═══
                  GestureDetector(
                    onTap: () => setState(() { _showAdd = !_showAdd; _contributeId = null; }),
                    child: AnimatedContainer(
                      duration: Duration(milliseconds: 300),
                      padding: EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                      decoration: BoxDecoration(
                        gradient: _showAdd
                            ? LinearGradient(colors: [AppColors.danger, AppColors.danger.withAlpha(200)])
                            : LinearGradient(colors: [Color(0xFFB82040), AppColors.primary]),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [BoxShadow(color: (_showAdd ? AppColors.danger : AppColors.primary).withAlpha(60), blurRadius: 16, offset: Offset(0, 6))],
                      ),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        AppIconBadge(icon: _showAdd ? TwoToneIcons.close.outline : TwoToneIcons.plus.outline, size: 32, iconSize: 16, backgroundColor: Colors.white.withAlpha(25), borderColor: Colors.white.withAlpha(40)),
                        SizedBox(width: 10),
                        Text(_showAdd ? l10n.translate('cancel') : l10n.translate('newSavingsGoal'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
                      ]),
                    ),
                  ),

                  // ═══ ADD FORM ═══
                  if (_showAdd) ...[
                    SizedBox(height: 16),
                    _buildAddForm(),
                  ],
                  SizedBox(height: 24),

                  // ═══ GOALS LIST ═══
                  if (goals.isEmpty)
                    _emptyState()
                  else ...[
                    Row(children: [
                      Container(width: 4, height: 18, decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2))),
                      SizedBox(width: 10),
                      Text(l10n.translate('myGoals'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    ]),
                    SizedBox(height: 16),
                    ...goals.map((g) => _goalCard(g, st.bankAccounts)),
                  ],
                ])),
              ],
            );
  }

  Widget _buildAddForm() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 0.5),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 20, offset: Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIconBadge(icon: TwoToneIcons.savingsGoal.outline, size: 40, iconSize: 20, backgroundColor: AppColors.primary.withAlpha(20), borderColor: AppColors.primary.withAlpha(40), accentColor: AppColors.primary),
          SizedBox(width: 12),
          Text(_editId != null ? l10n.translate('editGoal') : l10n.translate('newSavingsGoal'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        ]),
        SizedBox(height: 20),
        _FormField(controller: _nameCtrl, label: l10n.translate('goalNameLabel'), icon: TwoToneIcons.edit, keyboardType: TextInputType.text),
        SizedBox(height: 12),
        _FormField(controller: _targetCtrl, label: l10n.translate('targetAmountLabel'), icon: TwoToneIcons.money, keyboardType: TextInputType.number, isAmount: true),
        SizedBox(height: 12),
        CurrencySelector(
          value: _currency,
          label: l10n.translate('currencyLabel'),
          showCode: false,
          onChanged: (v) =>
              setState(() => {_currency = v, _currencyTouched = true}),
        ),
        SizedBox(height: 12),
        GestureDetector(
          onTap: () async { final p = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime(2035)); if (p != null) setState(() => _deadline = p); },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border, width: 0.5)),
            child: Row(children: [
              AppIconBadge(icon: TwoToneIcons.calendar.outline, size: 32, iconSize: 16, backgroundColor: AppColors.surface, borderColor: AppColors.border),
              SizedBox(width: 10),
              Expanded(child: Text(_deadline != null ? DateFormat('yyyy/MM/dd').format(_deadline!) : l10n.translate('dueDateOptionalLabel'),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: _deadline != null ? AppColors.textPrimary : AppColors.textPlaceholder))),
              if (_deadline != null) Text(DateFormat('yyyy/MM/dd').format(_deadline!), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.primary)),
            ]),
          ),
        ),
        SizedBox(height: 12),
        // Icon selector grid
        Text(l10n.translate('chooseIconLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        SizedBox(height: 8),
        Wrap(
          spacing: 8, runSpacing: 8,
          children: _iconKeys.map((k) {
            final selected = _selIcon == k;
            return GestureDetector(
              onTap: () { HapticFeedback.selectionClick(); setState(() => _selIcon = k); },
              child: AnimatedContainer(
                duration: Duration(milliseconds: 200),
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: selected ? AppColors.primary.withAlpha(25) : AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.5 : 0.5),
                ),
                child: AppIconBadge(
                  icon: _iconChoices[k]!.outline, size: 48, iconSize: 22,
                  backgroundColor: selected ? AppColors.primary.withAlpha(25) : Colors.transparent,
                  borderColor: Colors.transparent,
                  accentColor: selected ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
            );
          }).toList(),
        ),
        SizedBox(height: 20),
        Row(children: [
          Expanded(child: GestureDetector(
            onTap: () => setState(() => _showAdd = false),
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border, width: 0.5)),
              child: Center(child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
            ),
          )),
          SizedBox(width: 10),
          Expanded(flex: 2, child: GestureDetector(
            onTap: _createGoal,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFFB82040), AppColors.primary]),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(60), blurRadius: 12, offset: Offset(0, 4))],
              ),
              child: Center(child: Text(_editId != null ? l10n.translate('saveChanges') : l10n.translate('createGoal'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white))),
            ),
          )),
        ]),
      ]),
    );
  }

  Widget _goalCard(SavingsGoal g, List<PersonalBankAccount> listAccounts) {
    final l10n = AppLocalizations.of(context);
    final progress = g.targetAmount > 0 ? (g.currentAmount / g.targetAmount).clamp(0.0, 1.0) : 0.0;
    final pct = (progress * 100).toInt();
    final completed = g.currentAmount >= g.targetAmount;
    final icon = _iconChoices[g.icon] ?? TwoToneIcons.savingsGoal;
    final remaining = (g.targetAmount - g.currentAmount).clamp(0, g.targetAmount.toInt()).toDouble();
    String deadlineText = '';
    var isOverdue = false;
    if (g.deadline != null) {
      final d = DateTime.tryParse(g.deadline!);
      if (d != null) {
        final days = d.difference(DateTime.now()).inDays;
        isOverdue = days < 0;
        deadlineText = isOverdue
            ? l10n.translate('daysOverdue', params: {'days': '${days.abs()}'})
            : l10n.translate('daysRemaining', params: {'days': '$days'});
      }
    }
    final isContributing = _contributeId == g.id;

    return GestureDetector(
      onTap: () => context.pushNamed('personalSavingsDetail', pathParameters: {'goalId': '${g.id}'}),
      child: Container(
      margin: EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: completed ? AppColors.success.withAlpha(60) : AppColors.border, width: completed ? 1 : 0.5),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 20, offset: Offset(0, 8))],
      ),
      child: Column(children: [
        // Top section with gradient
        Container(
          padding: EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(1, -0.5), end: Alignment(-1, 0.5),
              colors: completed
                  ? [AppColors.success.withAlpha(40), AppColors.success.withAlpha(15)]
                  : [AppColors.primary.withAlpha(25), AppColors.primaryDark.withAlpha(15)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(children: [
            Row(children: [
              AppIconBadge(
                icon: icon.outline, size: 48, iconSize: 24,
                backgroundColor: completed ? AppColors.success.withAlpha(25) : AppColors.primary.withAlpha(20),
                borderColor: completed ? AppColors.success.withAlpha(40) : AppColors.primary.withAlpha(40),
                accentColor: completed ? AppColors.success : AppColors.primary,
              ),
              SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g.name, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                SizedBox(height: 2),
                Row(children: [
                  Text(l10n.translate(_iconLabelKey(g.icon)), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.primary)),
                  if (deadlineText.isNotEmpty) ...[
                    Text(' \u2022 ', style: TextStyle(color: AppColors.textDisabled, fontSize: R.fontSize(context, 11))),
                    Text(deadlineText, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: isOverdue ? AppColors.danger : AppColors.textSecondary)),
                  ],
                ]),
              ])),
              if (completed)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.success.withAlpha(20), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.success.withAlpha(40), width: 0.5)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    TwoToneIcon(data: TwoToneIcons.check, size: 14, outlineColor: AppColors.success),
                    SizedBox(width: 4),
                    Text(l10n.translate('completed'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), fontWeight: FontWeight.w700, color: AppColors.success)),
                  ]),
                ),
              PopupMenuButton<String>(
                icon: Container(
                  padding: EdgeInsets.all(6),
                  decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(8)),
                  child: TwoToneIcon(data: TwoToneIcons.filter, size: 16, outlineColor: AppColors.textSecondary),
                ),
                color: AppColors.surfaceVariant,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'add', child: Row(children: [TwoToneIcon(data: TwoToneIcons.plus, size: 16, outlineColor: AppColors.primary), SizedBox(width: 8), Text(l10n.translate('addAmount'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary))])),
                  PopupMenuItem(value: 'edit', child: Row(children: [TwoToneIcon(data: TwoToneIcons.edit, size: 16, outlineColor: AppColors.primary), SizedBox(width: 8), Text(l10n.translate('edit'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary))])),
                  PopupMenuItem(value: 'delete', child: Row(children: [TwoToneIcon(data: TwoToneIcons.delete, size: 16, outlineColor: AppColors.danger), SizedBox(width: 8), Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger))])),
                ],
                onSelected: (v) {
                  if (v == 'delete') _deleteGoal(g.id);
                  if (v == 'add') setState(() => _contributeId = isContributing ? null : g.id);
                  if (v == 'edit') _startEdit(g);
                },
              ),
            ]),
            SizedBox(height: 16),
            // Progress bar
            Stack(children: [
              Container(
                height: 10,
                decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(5)),
              ),
              AnimatedContainer(
                duration: Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                height: 10,
                width: MediaQuery.of(context).size.width * progress * 0.85,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: completed ? [AppColors.success, AppColors.success.withAlpha(180)] : [Color(0xFFB82040), AppColors.primary]),
                  borderRadius: BorderRadius.circular(5),
                  boxShadow: [BoxShadow(color: (completed ? AppColors.success : AppColors.primary).withAlpha(60), blurRadius: 8, offset: Offset(0, 2))],
                ),
              ),
            ]),
            SizedBox(height: 10),
            Row(children: [
              Flexible(fit: FlexFit.loose, child: FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerEnd, child: Text('${fmtNum(g.currentAmount)} ${currencySymbol(g.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary)))),
              Text(' / ', style: TextStyle(fontSize: R.fontSize(context, 13), color: AppColors.textDisabled)),
              Flexible(fit: FlexFit.loose, child: FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerEnd, child: Text('${fmtNum(g.targetAmount)} ${currencySymbol(g.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)))),
              Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(8)),
                child: Text('$pct%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ),
            ]),
          ]),
        ),

        // Bottom section with contribute button
        Padding(
          padding: EdgeInsets.fromLTRB(18, 12, 18, 16),
          child: Column(children: [
            if (remaining > 0)
              Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  AppIconBadge(icon: TwoToneIcons.info.outline, size: 24, iconSize: 12, backgroundColor: AppColors.surfaceVariant, borderColor: AppColors.border),
                  SizedBox(width: 6),
                  Text(l10n.translate('goalRemainingLine', params: {'amount': fmtNum(remaining), 'symbol': currencySymbol(g.currency)}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
                ]),
              ),
            GestureDetector(
              onTap: () => setState(() => _contributeId = isContributing ? null : g.id),
              child: AnimatedContainer(
                duration: Duration(milliseconds: 300),
                padding: EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  gradient: isContributing
                      ? LinearGradient(colors: [AppColors.danger, AppColors.danger.withAlpha(200)])
                      : LinearGradient(colors: [AppColors.primary.withAlpha(200), AppColors.primary]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  AppIconBadge(
                    icon: isContributing ? TwoToneIcons.close.outline : TwoToneIcons.arrowDown.outline,
                    size: 28, iconSize: 14,
                    backgroundColor: Colors.white.withAlpha(25),
                    borderColor: Colors.white.withAlpha(40),
                  ),
                  SizedBox(width: 8),
                  Text(isContributing ? l10n.translate('cancel') : l10n.translate('addAmount'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
                ]),
              ),
            ),
            if (isContributing) ...[
              SizedBox(height: 16),
              _buildContributeForm(g, listAccounts),
            ],
          ]),
        ),
      ]),
    ),
    );
  }

  Widget _buildContributeForm(SavingsGoal g, List<PersonalBankAccount> listAccounts) {
    final l10n = AppLocalizations.of(context);
    final st = ref.read(personalFinanceProvider);
    final allAccounts = st.bankAccounts;
    // Deduplicate: group by bankName, merge cash accounts
    final seen = <String>{};
    final uniqueAccounts = <PersonalBankAccount>[];
    for (final a in allAccounts) {
      final key = _isCashName(a.bankName) ? '__cash__' : '${a.bankName}_${a.currency}';
      if (!seen.contains(key)) {
        seen.add(key);
        uniqueAccounts.add(a);
      }
    }
    // Separate cash and bank accounts
    final cashAccs = uniqueAccounts.where((a) => _isCashName(a.bankName)).toList();
    final bankAccs = uniqueAccounts.where((a) => !_isCashName(a.bankName)).toList();
    final totalCash = allAccounts.where((a) => _isCashName(a.bankName)).fold<double>(0, (s, a) => s + a.balance);

    // Determine selected bank display text
    String bankDisplayText = l10n.translate('chooseSource');
    if (_bankId != null) {
      if (_bankId == '-1') {
        bankDisplayText = l10n.translate('accountTypeCash');
      } else {
        final acc = allAccounts.where((a) => a.id == _bankId).firstOrNull;
        if (acc != null) {
          bankDisplayText = _isCashName(acc.bankName)
              ? l10n.translate('accountTypeCash')
              : acc.bankName;
        }
      }
    }

    return Column(children: [
      // Bank account picker (bottom sheet)
      GestureDetector(
        onTap: () => _pickGoalBankAccount(bankAccs, cashAccs, totalCash),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Row(
            children: [
              TwoToneIcon(data: TwoToneIcons.bank, size: 18, outlineColor: AppColors.primary),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  bankDisplayText,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w600,
                    color: _bankId != null ? AppColors.textPrimary : AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              TwoToneIcon(data: TwoToneIcons.arrowDown, size: 18, outlineColor: AppColors.textSecondary),
            ],
          ),
        ),
      ),
      // Currency row (bank selected): shows the chosen currency, tap to change
      if (_bankId != null && _bankId != '-1') ...[
        SizedBox(height: 12),
        _buildCurrencyPickerForGoal(g, allAccounts),
      ],
      SizedBox(height: 12),
      _FormField(controller: _amountCtrl, label: l10n.translate('amountLabel'), icon: TwoToneIcons.money, keyboardType: TextInputType.number, isAmount: true),
      SizedBox(height: 12),
      Row(children: [
        Expanded(child: GestureDetector(
          onTap: () => setState(() { _contributeId = null; _selCurrencyForGoal = null; _contribOpId = null; }),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border, width: 0.5)),
            child: Center(child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
          ),
        )),
        SizedBox(width: 10),
        Expanded(flex: 2, child: GestureDetector(
          onTap: _contributing ? null : () => _contribute(g),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFFB82040), AppColors.primary]),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: _contributing
                  ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Text(l10n.translate('add'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        )),
      ]),
    ]);
  }

  bool _isCashName(String name) => name == 'كاش' || name == 'Cash';

  Widget _buildCurrencyPickerForGoal(SavingsGoal g, List<PersonalBankAccount> allAccounts) {
    final l10n = AppLocalizations.of(context);
    final acc = allAccounts.where((a) => a.id == _bankId).firstOrNull;
    if (acc == null) return SizedBox.shrink();
    final bankName = acc.bankName;
    final currencies = allAccounts.where((a) => a.bankName == bankName && !_isCashName(a.bankName)).map((a) => a.currency).toSet().toList();
    if (currencies.length <= 1) {
      // Auto-select the only currency
      if (currencies.length == 1 && _selCurrencyForGoal == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _selCurrencyForGoal = currencies.first);
        });
      }
      return SizedBox.shrink();
    }
    final display = _selCurrencyForGoal ?? l10n.translate('selectCurrencyFirst');
    return GestureDetector(
      onTap: () => _pickGoalCurrencyForBank(bankName),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _selCurrencyForGoal != null ? AppColors.primary.withAlpha(80) : AppColors.border,
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            TwoToneIcon(data: TwoToneIcons.coins, size: 18, outlineColor: AppColors.primary),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                display,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w600,
                  color: _selCurrencyForGoal != null ? AppColors.textPrimary : AppColors.textSecondary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            TwoToneIcon(data: TwoToneIcons.arrowDown, size: 18, outlineColor: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Future<void> _pickGoalBankAccount(List<PersonalBankAccount> bankAccs, List<PersonalBankAccount> cashAccs, double totalCash) async {
    final l10n = AppLocalizations.of(context);
    // Group by bank name (debts-style): one row per bank, name only.
    final bankNames = <String>[];
    for (final a in bankAccs) {
      if (!bankNames.contains(a.bankName)) bankNames.add(a.bankName);
    }
    final allNow = ref.read(personalFinanceProvider).bankAccounts;
    String? selBankName;
    if (_bankId != null && _bankId != '-1') {
      selBankName = allNow.where((a) => a.id == _bankId).firstOrNull?.bankName;
    }
    final selCashAcc = (_bankId != null && _bankId != '-1')
        ? allNow.where((a) => a.id == _bankId).firstOrNull
        : null;
    final selIsCash =
        selCashAcc != null && _isCashName(selCashAcc.bankName);
    // Distinct cash buckets (one per currency even with duplicate rows).
    final cashCurrencyCount = PersonalFinanceService.canonicalCashAccounts(
            allNow)
        .length;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: EdgeInsets.only(top: 10),
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: AppColors.textSecondary, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    TwoToneIcon(data: TwoToneIcons.bank, size: 22, outlineColor: AppColors.primary),
                    SizedBox(width: 10),
                    Text(l10n.translate('chooseSource'),
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo', color: AppColors.textPrimary)),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // Cash option (debts-style): currency-count subtitle, tap
                    // opens the cash currency sheet.
                    if (cashAccs.isNotEmpty)
                      InkWell(
                        onTap: () => Navigator.pop(ctx, 'cash:'),
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          decoration: BoxDecoration(
                            color: selIsCash ? AppColors.primary.withAlpha(15) : Colors.transparent,
                            border: Border(bottom: BorderSide(color: AppColors.border.withAlpha(40), width: 0.5)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 42, height: 42,
                                decoration: BoxDecoration(
                                  color: AppColors.success.withAlpha(20),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.success.withAlpha(60), width: 0.5),
                                ),
                                child: Icon(Icons.money, size: 20, color: AppColors.success),
                              ),
                              SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l10n.translate('accountTypeCash'),
                                        style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                    SizedBox(height: 2),
                                    Text(l10n.translate('personalCurrenciesCount', params: {'count': '$cashCurrencyCount'}),
                                        style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                                  ],
                                ),
                              ),
                              if (selIsCash)
                                TwoToneIcon(data: TwoToneIcons.check, size: 20, outlineColor: AppColors.primary),
                            ],
                          ),
                        ),
                      ),
                    // One row per bank: name only + small currency-count subtitle.
                    ...bankNames.map((name) {
                      final accs = allNow.where((a) => a.bankName == name && !_isCashName(a.bankName)).toList();
                      final n = accs.map((a) => a.currency).toSet().length;
                      final isSelected = selBankName == name;
                      return InkWell(
                        onTap: () => Navigator.pop(ctx, 'bank:$name'),
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          decoration: BoxDecoration(
                            color: isSelected ? AppColors.primary.withAlpha(15) : Colors.transparent,
                            border: Border(bottom: BorderSide(color: AppColors.border.withAlpha(40), width: 0.5)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 42, height: 42,
                                decoration: BoxDecoration(
                                  color: isSelected ? AppColors.primary.withAlpha(20) : AppColors.surface,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: isSelected ? AppColors.primary.withAlpha(60) : AppColors.border, width: 0.5),
                                ),
                                child: TwoToneIcon(data: TwoToneIcons.bank, size: 20, outlineColor: isSelected ? AppColors.primary : AppColors.textSecondary),
                              ),
                              SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(name,
                                        style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                    SizedBox(height: 2),
                                    Text(l10n.translate('personalCurrenciesCount', params: {'count': '$n'}),
                                        style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                TwoToneIcon(data: TwoToneIcons.check, size: 20, outlineColor: AppColors.primary)
                              else
                                TwoToneIcon(data: TwoToneIcons.arrowDown, size: 16, outlineColor: AppColors.textDisabled),
                            ],
                          ),
                        ),
                      );
                    }),
                    SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null) return;
    if (chosen == '-1') {
      setState(() {
        _bankId = '-1';
        _selCurrencyForGoal = null;
      });
      return;
    }
    if (chosen == 'cash:') {
      await _pickGoalCurrencyForBank('', isCash: true);
      return;
    }
    if (chosen.startsWith('bank:')) {
      await _pickGoalCurrencyForBank(chosen.substring(5));
    }
  }

  /// Currency popup for one bank (debts-style): every currency of the bank
  /// with its balance beside it. A single-currency bank is pre-selected
  /// automatically. Confirming pays from that exact currency account.
  /// With [isCash] the same sheet lists the cash account currencies instead.
  Future<void> _pickGoalCurrencyForBank(String bankName, {bool isCash = false}) async {
    final l10n = AppLocalizations.of(context);
    final st = ref.read(personalFinanceProvider);
    final rawAccs = st.bankAccounts
        .where((a) => isCash ? _isCashName(a.bankName) : (a.bankName == bankName && !_isCashName(a.bankName)))
        .toList();
    // Cash: one row per bucket with summed balances (duplicates collapse so
    // a currency is never listed twice and the resolved id is canonical).
    final accs = isCash
        ? PersonalFinanceService.canonicalCashAccounts(rawAccs)
        : rawAccs;
    if (accs.isEmpty) return;
    final pre = accs.length == 1 ? accs.first.currency : _selCurrencyForGoal;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: EdgeInsets.only(top: 10),
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: AppColors.textSecondary, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    TwoToneIcon(data: TwoToneIcons.coins, size: 22, outlineColor: AppColors.primary),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(isCash
                          ? '${l10n.translate('accountTypeCash')} — ${l10n.translate('currencyLabel')}'
                          : '$bankName — ${l10n.translate('currencyLabel')}',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo', color: AppColors.textPrimary)),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ...accs.map((a) {
                      final dupes = accs.where((x) => x.currency == a.currency).length;
                      final title = dupes > 1
                          ? '${a.currency} (${_shortGoalAccountType(a.accountType)})'
                          : a.currency;
                      final selected = pre == a.currency;
                      return InkWell(
                        onTap: () => Navigator.pop(ctx, a.currency),
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          decoration: BoxDecoration(
                            color: selected ? AppColors.primary.withAlpha(15) : Colors.transparent,
                            border: Border(bottom: BorderSide(color: AppColors.border.withAlpha(40), width: 0.5)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 42, height: 42,
                                decoration: BoxDecoration(
                                  color: selected ? AppColors.primary.withAlpha(20) : AppColors.surface,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: selected ? AppColors.primary.withAlpha(60) : AppColors.border, width: 0.5),
                                ),
                                child: TwoToneIcon(data: TwoToneIcons.coins, size: 20, outlineColor: selected ? AppColors.primary : AppColors.textSecondary),
                              ),
                              SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title,
                                        style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                    SizedBox(height: 2),
                                    Text(currencyName(a.currency),
                                        style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                                  ],
                                ),
                              ),
                              Text(fmtNum(a.balance),
                                  style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: selected ? AppColors.primary : AppColors.textPrimary)),
                              SizedBox(width: 8),
                              if (selected)
                                TwoToneIcon(data: TwoToneIcons.check, size: 20, outlineColor: AppColors.primary),
                            ],
                          ),
                        ),
                      );
                    }),
                    SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final cur = chosen ?? (accs.length == 1 ? accs.first.currency : null);
    if (cur == null) return;
    final exact = accs.where((a) => a.currency == cur).firstOrNull ?? accs.first;
    setState(() {
      _bankId = exact.id;
      _selCurrencyForGoal = cur;
    });
  }

  String _shortGoalAccountType(String type) {
    final l10n = AppLocalizations.of(context);
    switch (type) {
      case 'savings':
        return l10n.translate('accountTypeSavings');
      case 'credit':
        return l10n.translate('accountTypeCredit');
      case 'wallet':
        return l10n.translate('accountTypeWallet');
      case 'cash':
        return l10n.translate('accountTypeCash');
      case 'checking':
      default:
        return l10n.translate('accountTypeChecking');
    }
  }

  Widget _emptyState() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 60),
      child: Column(children: [
        AppIconBadge(icon: TwoToneIcons.savingsGoal.outline, size: 72, iconSize: 32, backgroundColor: AppColors.surface, borderColor: AppColors.border, accentColor: AppColors.textPlaceholder),
        SizedBox(height: 16),
        Text(l10n.translate('noSavingsGoals'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
        SizedBox(height: 6),
        Text(l10n.translate('createFirstGoalHint'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled)),
        SizedBox(height: 20),
        GestureDetector(
          onTap: () => setState(() => _showAdd = true),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFFB82040), AppColors.primary]),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppIconBadge(icon: TwoToneIcons.plus.outline, size: 28, iconSize: 14, backgroundColor: Colors.white.withAlpha(25), borderColor: Colors.white.withAlpha(40)),
              SizedBox(width: 8),
              Text(l10n.translate('newGoal'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
            ]),
          ),
        ),
      ]),
    );
  }

  String _iconLabelKey(String icon) {
    switch (icon) {
      case 'مدخرات': return 'goalIconSavings';
      case 'سفر': return 'goalIconTravel';
      case 'منزل': return 'goalIconHome';
      case 'سيارة': return 'goalIconCar';
      case 'تعليم': return 'goalIconEducation';
      case 'صحة': return 'goalIconHealth';
      case 'استثمار': return 'goalIconInvestment';
      case 'هدية': return 'goalIconGift';
      case 'مطعم': return 'goalIconRestaurant';
      case 'تقاعد': return 'goalIconRetirement';
      case 'تسوق': return 'goalIconShopping';
      case 'رياضة': return 'goalIconSports';
      case 'زفاف': return 'goalIconWedding';
      case 'عمرة وحج': return 'goalIconUmrahHajj';
      case 'طوارئ': return 'goalIconEmergency';
      case 'هاتف': return 'goalIconPhone';
      case 'لابتوب': return 'goalIconLaptop';
      case 'ساعة': return 'goalIconWatch';
      case 'أثاث': return 'goalIconFurniture';
      case 'مولود': return 'goalIconBaby';
      case 'دراجة': return 'goalIconBike';
      case 'تخييم': return 'goalIconCamping';
      case 'ملابس': return 'goalIconClothes';
      case 'عطر': return 'goalIconPerfume';
      case 'مشروع': return 'goalIconProject';
      case 'صدقة': return 'goalIconCharity';
      case 'ألعاب': return 'goalIconGames';
      case 'ترفيه': return 'goalIconEntertainment';
      default: return icon;
    }
  }
}

// ════════════════════════════════════════════════════════════
//  REUSABLE FORM FIELD
// ════════════════════════════════════════════════════════════
class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final TwoToneIconData icon;
  final TextInputType? keyboardType;
  final bool isAmount;
  const _FormField({required this.controller, required this.label, required this.icon, this.keyboardType, this.isAmount = false});

  @override
  Widget build(BuildContext context) {
    return FyonaTextField(
      controller: controller, keyboardType: keyboardType,
      inputFormatters: isAmount ? [AmountInputFormatter()] : null,
      textAlign: TextAlign.right,
      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: label, hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPlaceholder),
        prefixIcon: Padding(padding: EdgeInsets.only(left: 10), child: AppIconBadge(icon: icon.outline, size: 32, iconSize: 16, backgroundColor: AppColors.surfaceVariant, borderColor: AppColors.border)),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        filled: true, fillColor: AppColors.surfaceVariant,
        border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border, width: 0.5), borderRadius: BorderRadius.circular(10)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary, width: 1), borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
