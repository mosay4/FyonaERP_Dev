import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/bank_gradients.dart';
import '../../../../core/utils/currency_formatter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/widgets/app_icon_badge.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../../services/debt_reminder_service.dart';
import '../providers/receipt_design_provider.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../../di/personal_providers.dart' show personalFinanceServiceProvider;
import '../../domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class PersonalDebtsPage extends ConsumerStatefulWidget {
  final String? debtId;
  const PersonalDebtsPage({super.key, this.debtId});
  @override
  ConsumerState<PersonalDebtsPage> createState() => _PersonalDebtsPageState();
}

class _PersonalDebtsPageState extends ConsumerState<PersonalDebtsPage> with SingleTickerProviderStateMixin {
  String _filter = 'all';
  // Display totals default to USD always (user-changeable, persisted).
  String _displayCurrency = 'USD';
  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  bool _detailOpened = false;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(duration: Duration(milliseconds: 500), vsync: this);
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(begin: Offset(0, 0.03), end: Offset.zero).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();
    _loadDisplayCurrency();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAlarms());
  }

  Future<void> _loadDisplayCurrency() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('debt_display_currency');
    if (saved != null && mounted) setState(() => _displayCurrency = saved);
  }

  Future<void> _checkAlarms() async {
    if (!mounted) return;
    await DebtReminderService.checkAndShowAlarms(() => context);
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _load() => ref.read(personalFinanceProvider.notifier).load();

  List<PersonalDebt> _filteredList(List<PersonalDebt> all) {
    switch (_filter) {
      case 'payable': return all.where((d) => d.type == 'payable' && d.status != 'paid').toList();
      case 'receivable': return all.where((d) => d.type == 'receivable' && d.status != 'paid').toList();
      case 'overdue': return all.where((d) => d.isOverdue).toList();
      case 'paid': return all.where((d) => d.status == 'paid').toList();
      case 'partiallyPaid': return all.where((d) => d.paid > 0 && d.status != 'paid').toList();
      default: return all.toList();
    }
  }

  void _confirmDelete(PersonalDebt d) {
    HapticFeedback.lightImpact();
    final l10n = AppLocalizations.of(context);
    final label = d.type == 'payable'
        ? '${l10n.translate('oweDebtPrefix')} ${d.personName}'
        : '${l10n.translate('owedDebtPrefix')} ${d.personName}';
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.translate('deleteDebtTitle'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
      content: Text(l10n.translate('confirmDeleteDebt', params: {'label': label}), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))),
        TextButton(onPressed: () async {
          Navigator.pop(ctx);
          final ok = await ref.read(personalFinanceProvider.notifier).deleteDebt(d.id);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Row(children: [
              Icon(ok ? Icons.check_circle : Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text(
                ok ? l10n.translate('deletedSuccessfully') : l10n.translate('personalErrDeleteDebt'),
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

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(personalFinanceProvider);
    final allDebts = st.debts;
    final filtered = _filteredList(allDebts);

    final engine = ref.watch(currencyEngineProvider);
    double convertDebt(String type) {
      double sum = 0;
      for (final d in allDebts.where((d) => d.type == type && d.status != 'paid')) {
        final amt = d.remaining;
        if (d.currency == _displayCurrency) { sum += amt; continue; }
        final converted = engine.convert(amt, d.currency, _displayCurrency);
        sum += converted != 0 ? converted : amt;
      }
      return sum;
    }
    final totalPayable = convertDebt('payable');
    final totalReceivable = convertDebt('receivable');
    final overdueCount = allDebts.where((d) => d.isOverdue).length;
    final activeCount = allDebts.where((d) => d.status != 'paid').length;

    if (!_detailOpened && widget.debtId != null && !st.isLoading && allDebts.isNotEmpty) {
      _detailOpened = true;
      final target = allDebts.where((d) => d.id == widget.debtId).firstOrNull;
      if (target != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showDetail(target);
        });
      }
    }

    return st.isLoading
          ? _buildSkeleton()
          : FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: RefreshIndicator(
                  onRefresh: () async => _load(),
                  color: AppColors.primary,
                  backgroundColor: AppColors.surface,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 100),
                    physics: BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    children: [
                      _HeroDebtCard(
                        totalPayable: totalPayable,
                        totalReceivable: totalReceivable,
                        activeCount: activeCount,
                        overdueCount: overdueCount,
                        displayCurrency: _displayCurrency,
                        onCurrencyChanged: (v) {
                          setState(() => _displayCurrency = v);
                          SharedPreferences.getInstance().then((p) => p.setString('debt_display_currency', v));
                        },
                      ),
                      SizedBox(height: 16),
                      // ── Add Debt Button ──
                      _buildAddDebtButton(),
                      SizedBox(height: 20),
                      _buildStatCards(totalPayable, totalReceivable, overdueCount),
                      SizedBox(height: 20),
                      _buildFilterSection(filtered, totalPayable, totalReceivable, overdueCount, activeCount),
                      SizedBox(height: 12),
                      if (filtered.isEmpty)
                        _buildEmptyState()
                      else
                        ...filtered.map((d) => _DebtCard(
                          debt: d,
                          onDelete: () => _confirmDelete(d),
                          onPay: () => _showPayDialog(d),
                          onDetail: () => _showDetail(d),
                          onEdit: () => _showEditForm(d),
                        )),
                    ],
                  ),
                ),
              ),
    );
  }

  Widget _buildAddDebtButton() {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: () => _showAddForm(),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFFB82040), AppColors.primary]),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(50), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TwoToneIcon(data: TwoToneIcons.plus, size: 18, outlineColor: Colors.white),
            SizedBox(width: 10),
            Text(
              l10n.translate('addNewDebt'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCards(double payable, double receivable, int overdue) {
    final l10n = AppLocalizations.of(context);
    return Row(children: [
      Expanded(child: _StatMiniCard(
        label: l10n.translate('debtOwedByMe'), value: fmtNum(payable), color: AppColors.danger,
        icon: TwoToneIcons.arrowUp,
      )),
      SizedBox(width: 10),
      Expanded(child: _StatMiniCard(
        label: l10n.translate('debtOwedToMe'), value: fmtNum(receivable), color: AppColors.success,
        icon: TwoToneIcons.arrowDown,
      )),
      SizedBox(width: 10),
      Expanded(child: _StatMiniCard(
        label: l10n.translate('debtOverdue'), value: '$overdue', color: AppColors.warning,
        icon: TwoToneIcons.warning,
      )),
    ]);
  }

  Widget _buildFilterSection(List<PersonalDebt> filtered, double tp, double tr, int overdue, int active) {
    final l10n = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _FilterChip(label: l10n.translate('debtAllFilter'), value: 'all', active: _filter == 'all', onTap: (v) => setState(() => _filter = v)),
          SizedBox(width: 6),
          _FilterChip(label: l10n.translate('debtOwedByMe'), value: 'payable', active: _filter == 'payable', onTap: (v) => setState(() => _filter = v)),
          SizedBox(width: 6),
          _FilterChip(label: l10n.translate('debtOwedToMe'), value: 'receivable', active: _filter == 'receivable', onTap: (v) => setState(() => _filter = v)),
          SizedBox(width: 6),
          _FilterChip(label: l10n.translate('debtOverdue'), value: 'overdue', active: _filter == 'overdue', onTap: (v) => setState(() => _filter = v)),
          SizedBox(width: 6),
          _FilterChip(label: l10n.translate('debtPaid'), value: 'paid', active: _filter == 'paid', onTap: (v) => setState(() => _filter = v)),
          SizedBox(width: 6),
          _FilterChip(label: l10n.translate('debtPartiallyPaid'), value: 'partiallyPaid', active: _filter == 'partiallyPaid', onTap: (v) => setState(() => _filter = v)),
        ]),
      ),
    ]);
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 60),
      child: Column(children: [
        AppIconBadge(
          icon: TwoToneIcons.check.outline, size: 72, iconSize: 32,
          backgroundColor: AppColors.success.withAlpha(20),
          borderColor: AppColors.success.withAlpha(40),
        ),
        SizedBox(height: 16),
        Text(l10n.translate('noDebts'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
        SizedBox(height: 6),
        Text(l10n.translate('addFirstDebtHint'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled)),
      ]),
    );
  }

  Widget _buildSkeleton() {
    return ListView(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: List.generate(5, (i) => Container(
        margin: EdgeInsets.only(bottom: 12),
        height: 80,
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
      )),
    );
  }

  void _showAddForm() {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DebtFormSheet(onSave: (debt) {
        ref.read(personalFinanceProvider.notifier).addDebt(debt);
        Navigator.pop(context);
      }),
    );
  }

  void _showEditForm(PersonalDebt debt) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DebtFormSheet(initial: debt, onSave: (debt) {
        ref.read(personalFinanceProvider.notifier).updateDebt(debt);
        Navigator.pop(context);
      }),
    );
  }

  void _showPayDialog(PersonalDebt debt) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DebtPaySheet(debt: debt, onPay: (amount, method, bankId, notes, opId, currency, debtAmount) async {
        Navigator.pop(context);
        final l10n = AppLocalizations.of(context);
        try {
          await ref.read(personalFinanceProvider.notifier).payDebt(debt.id, amount, DateTime.now(), method: method, bankAccountId: bankId, notes: notes, clientOperationId: opId, currency: currency, debtAmount: debtAmount);
          if (mounted) {
            // debtAmount is the credit in debt currency (amount itself may
            // be converted into the account currency).
            final isPartial = debtAmount < debt.remaining - 0.001;
            final msg = isPartial ? l10n.translate('debtPartialPaid') : l10n.translate('success');
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg, style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.success));
          }
        } catch (e) {
          final msg = e.toString();
          final isInsufficient = msg.contains('الرصيد غير كاف') || msg.contains('Insufficient');
          if (mounted) {
            showDialog(context: context, builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(children: [Icon(Icons.error_outline, color: AppColors.danger), SizedBox(width: 8), Text(isInsufficient ? l10n.translate('insufficientBalance') : l10n.translate('errorOccurred'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))]),
              content: Text(isInsufficient ? l10n.translate('insufficientBalance') : msg, style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo')))],
            ));
          }
        }
      }),
    );
  }

  void _showDetail(PersonalDebt debt) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _DebtDetailPage(debt: debt),
    ));
  }
}

// ═══════════════════════════════════════════════════════════════
// Hero Card
// ═══════════════════════════════════════════════════════════════
class _HeroDebtCard extends StatelessWidget {
  final double totalPayable;
  final double totalReceivable;
  final int activeCount;
  final int overdueCount;
  final String displayCurrency;
  final ValueChanged<String> onCurrencyChanged;
  const _HeroDebtCard({required this.totalPayable, required this.totalReceivable, required this.activeCount, required this.overdueCount, required this.displayCurrency, required this.onCurrencyChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-1.0, -1.0), end: Alignment(1.5, 1.5),
          colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: AppColors.primary.withAlpha(100), blurRadius: 32, offset: Offset(0, 12)),
          BoxShadow(color: AppColors.primaryDark.withAlpha(60), blurRadius: 48, offset: Offset(0, 24)),
        ],
      ),
      child: Stack(children: [
        Positioned(top: -30, right: -20, child: Container(width: 100, height: 100,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(15)))),
        Positioned(bottom: -40, left: -10, child: Container(width: 120, height: 120,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(10)))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppIconBadge(
              icon: TwoToneIcons.debt.outline, size: 44, iconSize: 22,
              backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30),
            ),
            SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.translate('debtsTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
              SizedBox(height: 2),
              Text(l10n.translate('debtsActiveLine', params: {'count': '$activeCount'}) + (overdueCount > 0 ? ' · ${l10n.translate('debtsOverdueLine', params: {'count': '$overdueCount'})}' : ''),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(180))),
            ])),
            GestureDetector(
              onTap: () => _showCurrencyPicker(context),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.white.withAlpha(25), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withAlpha(40))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(currencySymbol(displayCurrency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w700, color: Colors.white)),
                  SizedBox(width: 2),
                  Icon(Icons.expand_more, size: 14, color: Colors.white.withAlpha(180)),
                ]),
              ),
            ),
          ]),
          SizedBox(height: 24),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.translate('debtOwedToMe'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(160))),
              SizedBox(height: 2),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(fmtNum(totalReceivable), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: Colors.white)),
                SizedBox(width: 4),
                Text(currencySymbol(displayCurrency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(180))),
              ])),
            ])),
            SizedBox(width: 16),
            Container(width: 1, height: 36, color: Colors.white.withAlpha(20)),
            SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.translate('debtOwedByMe'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(160))),
              SizedBox(height: 2),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(fmtNum(totalPayable), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: Colors.white)),
                SizedBox(width: 4),
                Text(currencySymbol(displayCurrency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(180))),
              ])),
            ])),
          ]),
        ]),
      ]),
    );
  }

  void _showCurrencyPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(AppLocalizations.of(context).translate('currencyLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(height: 12),
          CurrencySelector(
            label: '',
            value: displayCurrency,
            showCode: false,
            onChanged: (v) { onCurrencyChanged(v); Navigator.pop(ctx); },
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Stat Mini Card
// ═══════════════════════════════════════════════════════════════
class _StatMiniCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final TwoToneIconData icon;
  const _StatMiniCard({required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(children: [
        TwoToneIcon(data: icon, size: 18, outlineColor: color),
        SizedBox(height: 6),
        FittedBox(
          child: Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ),
        SizedBox(height: 2),
        FittedBox(
          child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textDisabled)),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Filter Chip
// ═══════════════════════════════════════════════════════════════
class _FilterChip extends StatelessWidget {
  final String label;
  final String value;
  final bool active;
  final ValueChanged<String> onTap;
  const _FilterChip({required this.label, required this.value, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () { HapticFeedback.lightImpact(); onTap(value); },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? AppColors.primary : AppColors.border, width: 0.5),
        ),
        child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w500, color: active ? Colors.white : AppColors.textSecondary)),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Debt Card
// ═══════════════════════════════════════════════════════════════
class _DebtCard extends StatelessWidget {
  final PersonalDebt debt;
  final VoidCallback onDelete;
  final VoidCallback onPay;
  final VoidCallback onDetail;
  final VoidCallback onEdit;
  const _DebtCard({required this.debt, required this.onDelete, required this.onPay, required this.onDetail, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isPayable = debt.type == 'payable';
    final statusColor = debt.status == 'paid'
        ? AppColors.success
        : debt.isOverdue ? AppColors.danger : AppColors.warning;
    final statusText = debt.status == 'paid' ? l10n.translate('debtPaid') : debt.isOverdue ? l10n.translate('debtOverdue') : l10n.translate('debtActive');
    final gradient = bankGradients[debt.personName.hashCode.abs() % bankGradients.length];
    final typeLabel = isPayable ? l10n.translate('oweDebtPrefix') : l10n.translate('owedDebtPrefix');

    return GestureDetector(
      onTap: onDetail,
      child: Container(
        margin: EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 20, offset: Offset(0, 8))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── Header ──
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment(1, -0.5), end: Alignment(-1, 0.5), colors: gradient),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Row 1: Icon + Name + Amount
              Row(children: [
                AppIconBadge(
                  icon: (isPayable ? TwoToneIcons.arrowUp : TwoToneIcons.arrowDown).outline,
                  size: 40, iconSize: 18,
                  backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // "دين علي لـ" or "لي دين عند" + person name
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(text: typeLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(160))),
                          TextSpan(text: ' ', style: TextStyle(fontSize: 4)),
                          TextSpan(text: debt.personName, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ]),
                ),
                SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('${fmtNum(debt.remaining)} ${currencySymbol(debt.currency)}',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
              ]),
              SizedBox(height: 10),
              // Row 2: Badges + Date
              Row(children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.white.withAlpha(25), borderRadius: BorderRadius.circular(4)),
                  child: Text(isPayable ? l10n.translate('debtOwedByMe') : l10n.translate('debtOwedToMe'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: Colors.white.withAlpha(200))),
                ),
                SizedBox(width: 6),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: statusColor.withAlpha(60), borderRadius: BorderRadius.circular(4)),
                  child: Text(statusText, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: Colors.white)),
                ),
                Spacer(),
                if (debt.dueDate != null)
                  Text(DateFormat('yyyy/MM/dd').format(debt.dueDate!),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: Colors.white.withAlpha(160))),
              ]),
              // Row 3: Progress bar
              if (debt.amount > 0 && debt.paid > 0) ...[
                SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: debt.progress, minHeight: 6,
                    backgroundColor: Colors.white.withAlpha(30),
                    valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                  ),
                ),
                SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(l10n.translate('paidLine', params: {'amount': fmtNum(debt.paid)}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: Colors.white.withAlpha(180))),
                  Text('${(debt.progress * 100).toStringAsFixed(0)}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: Colors.white.withAlpha(180))),
                ]),
              ],
            ]),
          ),
          // ── Action Buttons ──
          if (debt.status != 'paid')
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
              ),
              child: IntrinsicHeight(
                child: Row(children: [
                  Expanded(child: TextButton.icon(
                    onPressed: onPay,
                    icon: TwoToneIcon(data: TwoToneIcons.check, size: 16, outlineColor: AppColors.success),
                    label: FittedBox(child: Text(l10n.translate(debt.type == 'payable' ? 'pay' : 'collect'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.success))),
                  )),
                  VerticalDivider(width: 0.5, color: AppColors.border),
                  Expanded(child: TextButton.icon(
                    onPressed: onEdit,
                    icon: TwoToneIcon(data: TwoToneIcons.edit, size: 16, outlineColor: AppColors.primary),
                    label: FittedBox(child: Text(l10n.translate('edit'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.primary))),
                  )),
                  VerticalDivider(width: 0.5, color: AppColors.border),
                  Expanded(child: TextButton.icon(
                    onPressed: onDetail,
                    icon: TwoToneIcon(data: TwoToneIcons.info, size: 16, outlineColor: AppColors.warning),
                    label: FittedBox(child: Text(l10n.translate('details'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.warning))),
                  )),
                  VerticalDivider(width: 0.5, color: AppColors.border),
                  Expanded(child: TextButton.icon(
                    onPressed: onDelete,
                    icon: TwoToneIcon(data: TwoToneIcons.delete, size: 16, outlineColor: AppColors.danger),
                    label: FittedBox(child: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.danger))),
                  )),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Debt Form Bottom Sheet
// ═══════════════════════════════════════════════════════════════
class _DebtFormSheet extends ConsumerStatefulWidget {
  final ValueChanged<PersonalDebt> onSave;
  final PersonalDebt? initial;
  const _DebtFormSheet({required this.onSave, this.initial});
  @override
  ConsumerState<_DebtFormSheet> createState() => _DebtFormSheetState();
}

class _DebtFormSheetState extends ConsumerState<_DebtFormSheet> {
  String _type = 'payable';
  final _personCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  String _currency = 'USD';
  bool _currencyTouched = false;
  DateTime? _dueDate;
  bool _reminder = false;
  TimeOfDay? _reminderTime;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    if (d != null) {
      _type = d.type;
      _personCtrl.text = d.personName;
      _amountCtrl.text = d.amount.toStringAsFixed(0);
      _currency = d.currency;
      _currencyTouched = true;
      _notesCtrl.text = d.description ?? '';
      _dueDate = d.dueDate;
      _reminder = d.reminder;
      _debtBudgetId = d.budgetId;
      if (_reminder) _reminderTime = const TimeOfDay(hour: 9, minute: 0);
    } else {
      _resolveCurrencyDefault();
    }
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

  Future<void> _pickReminderTime() async {
    final initial = _reminderTime ?? const TimeOfDay(hour: 9, minute: 0);
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      builder: (ctx, child) {
        return MediaQuery(
          data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: false),
          child: Theme(
            data: Theme.of(ctx).copyWith(
              timePickerTheme: TimePickerThemeData(
                backgroundColor: Colors.black,
                hourMinuteShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                hourMinuteColor: const Color(0xFF1A1A1A),
                hourMinuteTextColor: const Color(0xFF7A1020),
                dialBackgroundColor: Colors.black,
                dialHandColor: const Color(0xFF7A1020),
                dialTextColor: const Color(0xFF7A1020),
              ),
              colorScheme: const ColorScheme.dark(primary: Color(0xFF7A1020), onPrimary: Colors.white, surface: Colors.black, onSurface: Color(0xFF7A1020)),
            ),
            child: child!,
          ),
        );
      },
    );
    if (picked != null) setState(() => _reminderTime = picked);
  }

  Future<void> _handleReminderToggle(bool v) async {
    if (v) {
      setState(() => _reminder = true);
      if (_dueDate == null) {
        final now = DateTime.now();
        final pickedDate = await showDatePicker(context: context, firstDate: now, lastDate: DateTime(2035), initialDate: now.add(const Duration(days: 30)));
        setState(() => _dueDate = pickedDate ?? now);
      }
      // Request permissions only if not already granted (check before requesting)
      // 1. Notification permission (Android 13+)
      final notifOk = await DebtReminderService.ensureNotificationPermission();
      if (!notifOk && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).translate('debtNotifPermission'), style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.warning));
      }
      // 2. Exact alarm permission (Android 12+) — already checks internally
      await DebtReminderService.requestExactAlarmPermissionIfNeeded();
      // 3. Full-screen intent permission (Android 14+) — only opens settings if not granted
      await DebtReminderService.requestFullScreenIntentPermissionIfNeeded();
      // 4. Battery exemption for Samsung / aggressive OEMs — only opens settings if not exempt
      await DebtReminderService.requestBatteryExemption();
      if (_reminderTime == null) {
        setState(() => _reminderTime = const TimeOfDay(hour: 9, minute: 0));
      }
    } else {
      setState(() { _reminder = false; _reminderTime = null; });
    }
  }

  @override
  void dispose() {
    _personCtrl.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  String? _debtBudgetId;

  void _submit() {
    final name = _personCtrl.text.trim();
    final amt = double.tryParse(_amountCtrl.text.replaceAll(',', ''));
    if (name.isEmpty) return;
    if (amt == null || amt <= 0) return;
    final debt = PersonalDebt(
      id: widget.initial?.id ?? '', type: _type, personName: name, amount: amt,
      currency: _currency, description: _notesCtrl.text.trim(),
      dueDate: _dueDate, reminder: _reminder,
      budgetId: _debtBudgetId ?? widget.initial?.budgetId,
    );
    widget.onSave(debt);
    if (_reminder && _dueDate != null) {
      final t = _reminderTime ?? const TimeOfDay(hour: 9, minute: 0);
      DebtReminderService.schedule(debt, _dueDate!, t);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(children: [
        Container(
          margin: EdgeInsets.only(top: 12),
          width: 40, height: 4,
          decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(children: [
            Text(_isEdit ? l10n.translate('editDebt') : l10n.translate('addNewDebt'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            Spacer(),
            IconButton(onPressed: () => Navigator.pop(context), icon: TwoToneIcon(data: TwoToneIcons.close, size: 20, outlineColor: AppColors.textSecondary)),
          ]),
        ),
        Expanded(child: ListView(
          padding: EdgeInsets.symmetric(horizontal: 20),
          children: [
            // Type selector
            Row(children: [
              Expanded(child: _typeBtn(l10n.translate('debtFormOweType'), 'payable', TwoToneIcons.arrowUp, AppColors.danger)),
              SizedBox(width: 10),
              Expanded(child: _typeBtn(l10n.translate('debtFormOwedType'), 'receivable', TwoToneIcons.arrowDown, AppColors.success)),
            ]),
            SizedBox(height: 16),
            _buildField(controller: _personCtrl, label: l10n.translate('personNameLabel'), icon: TwoToneIcons.user),
            SizedBox(height: 12),
            _buildField(controller: _amountCtrl, label: l10n.translate('amountRequiredLabel'), icon: TwoToneIcons.money, keyboardType: TextInputType.number),
            SizedBox(height: 12),
            CurrencySelector(
              label: l10n.translate('currencyLabel'),
              value: _currency,
              showCode: false,
              onChanged: (v) =>
                  setState(() => {_currency = v, _currencyTouched = true}),
            ),
            SizedBox(height: 12),
            _buildDateField(l10n),
            SizedBox(height: 12),
            Row(children: [
              TwoToneIcon(data: TwoToneIcons.bell, size: 16, outlineColor: AppColors.textSecondary),
              SizedBox(width: 8),
              Expanded(child: Text(l10n.translate('reminderLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary))),
              Switch(
                value: _reminder,
                onChanged: _handleReminderToggle,
                activeColor: AppColors.primary,
              ),
            ]),
            if (_reminder) ...[
              SizedBox(height: 8),
              GestureDetector(
                onTap: _pickReminderTime,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.primary.withAlpha(60))),
                  child: Row(children: [
                    Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.black, shape: BoxShape.circle, border: Border.all(color: Color(0xFF7A1020), width: 1.5)), child: Icon(Icons.access_time, color: Color(0xFF7A1020), size: 18)),
                    SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l10n.translate('dueTime'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                      Text(_reminderTime != null ? _reminderTime!.format(context) : l10n.translate('pickTime'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF7A1020))),
                    ])),
                    Icon(Icons.chevron_left, color: AppColors.textDisabled, size: 18),
                  ]),
                ),
              ),
            ],
            SizedBox(height: 12),
            _buildField(controller: _notesCtrl, label: l10n.translate('notesLabel'), icon: TwoToneIcons.info, maxLines: 2),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Text(_isEdit ? l10n.translate('saveChanges') : l10n.translate('addDebt'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            SizedBox(height: 20),
          ],
        )),
      ]),
    );
  }

  Widget _typeBtn(String label, String val, TwoToneIconData icon, Color color) {
    final active = _type == val;
    return GestureDetector(
      onTap: () => setState(() => _type = val),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: active ? color.withAlpha(30) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? color : AppColors.border, width: active ? 1.5 : 0.5),
        ),
        child: Column(children: [
          TwoToneIcon(data: icon, size: 20, outlineColor: active ? color : AppColors.textSecondary),
          SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w700, color: active ? color : AppColors.textSecondary, height: 1.3)),
        ]),
      ),
    );
  }

  Widget _buildField({required TextEditingController controller, required String label, required TwoToneIconData icon, TextInputType? keyboardType, int maxLines = 1}) {
    return FyonaTextField(
      controller: controller, keyboardType: keyboardType, maxLines: maxLines,
      textAlign: TextAlign.right,
      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: label,
        hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPlaceholder),
        prefixIcon: Padding(padding: EdgeInsets.only(left: 10), child: AppIconBadge(
          icon: icon.outline, size: 32, iconSize: 16,
          backgroundColor: AppColors.surfaceVariant, borderColor: AppColors.border,
        )),
        prefixIconConstraints: BoxConstraints(minWidth: 44, maxWidth: 44, minHeight: 32),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        filled: true, fillColor: AppColors.surfaceVariant,
        border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border, width: 0.5), borderRadius: BorderRadius.circular(10)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary, width: 1), borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _buildDateField(AppLocalizations l10n) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime(2035), initialDate: _dueDate ?? DateTime.now().add(Duration(days: 30)));
        if (picked != null) setState(() => _dueDate = picked);
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _dueDate != null ? AppColors.primary.withAlpha(80) : AppColors.border, width: 0.5),
        ),
        child: Row(children: [
          AppIconBadge(icon: TwoToneIcons.calendar.outline, size: 32, iconSize: 16, backgroundColor: AppColors.surfaceVariant, borderColor: AppColors.border),
          SizedBox(width: 10),
          Expanded(child: Text(
            _dueDate != null ? DateFormat('yyyy/MM/dd').format(_dueDate!) : l10n.translate('dueDateLabel'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: _dueDate != null ? AppColors.textPrimary : AppColors.textPlaceholder),
          )),
          if (_dueDate != null)
            GestureDetector(
              onTap: () => setState(() => _dueDate = null),
              child: TwoToneIcon(data: TwoToneIcons.close, size: 16, outlineColor: AppColors.textSecondary),
            ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Pay Bottom Sheet
// ═══════════════════════════════════════════════════════════════
/// Splits a typed debt-payment amount — ALWAYS in the SELECTED ACCOUNT
/// currency (the user types what leaves/enters the chosen account) — into
/// the account movement (account currency, as typed) and the debt credit
/// (debt currency, converted at [rate]).
/// [rate] is the account→debt rate. A null/non-positive rate keeps 1:1
/// (offline-safe: never blocks the user; same fallback philosophy as goals).
({double bankMove, double debtCredit}) splitDebtPayment({
  required double amount,
  required String accountCurrency,
  required String debtCurrency,
  required double? rate,
}) {
  final bankMove = amount;
  var debtCredit = amount;
  if (accountCurrency.toUpperCase() != debtCurrency.toUpperCase() &&
      rate != null &&
      rate > 0) {
    debtCredit = amount * rate;
  }
  return (bankMove: bankMove, debtCredit: debtCredit);
}

/// Collection split for debts owed TO the user (receivable): the typed
/// amount is ALWAYS in the DEBT currency (what the person hands over against
/// the debt); the receiving account is credited the converted value.
/// [rate] is the debt→account rate. A null/non-positive rate keeps 1:1
/// (offline-safe: never blocks the user).
({double bankMove, double debtCredit}) splitReceivableCollection({
  required double amount,
  required String accountCurrency,
  required String debtCurrency,
  required double? rate,
}) {
  var bankMove = amount;
  if (accountCurrency.toUpperCase() != debtCurrency.toUpperCase() &&
      rate != null &&
      rate > 0) {
    bankMove = amount * rate;
  }
  return (bankMove: bankMove, debtCredit: amount);
}
class _DebtPaySheet extends ConsumerStatefulWidget {
  final PersonalDebt debt;
  final Function(double amount, String method, String? bankId, String? notes,
      String opId, String currency, double debtAmount) onPay;
  const _DebtPaySheet({required this.debt, required this.onPay});
  @override
  ConsumerState<_DebtPaySheet> createState() => _DebtPaySheetState();
}

class _DebtPaySheetState extends ConsumerState<_DebtPaySheet> {
  final _amountCtrl = TextEditingController();
  String _method = 'cash';
  String? _bankId;
  String? _selBankName;
  final _notesCtrl = TextEditingController();
  bool _submitting = false;
  late final String _opId;

  @override
  void initState() {
    super.initState();
    // One idempotency key per sheet session: every tap/retry of THIS payment
    // shares it, so the backend executes it exactly once.
    _opId = ref.read(personalFinanceServiceProvider).newOperationId();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
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
      if (r.fromCurrency == to && r.toCurrency == from && r.rate != 0) {
        return 1.0 / r.rate;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(personalFinanceProvider);
    final l10n = AppLocalizations.of(context);
    final title = widget.debt.type == 'payable'
        ? l10n.translate('payDebtOweTitle', params: {'name': widget.debt.personName})
        : l10n.translate('payDebtOwedTitle', params: {'name': widget.debt.personName});
    return Container(
      height: MediaQuery.of(context).size.height * 0.62,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(children: [
        Container(
          margin: EdgeInsets.only(top: 12),
          width: 40, height: 4,
          decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(children: [
            Expanded(child: Text(title, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis)),
            SizedBox(width: 8),
            Text(l10n.translate('remainingAmount', params: {'amount': fmtNum(widget.debt.remaining)}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
          ]),
        ),
        Expanded(child: ListView(
          padding: EdgeInsets.symmetric(horizontal: 20),
          children: [
            FyonaTextField(
              controller: _amountCtrl, keyboardType: TextInputType.number,
              inputFormatters: [AmountInputFormatter()],
              textAlign: TextAlign.right,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: l10n.translate('payAmountHint'),
                hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPlaceholder),
                prefixIcon: Padding(padding: EdgeInsets.only(left: 10), child: AppIconBadge(
                  icon: TwoToneIcons.money.outline, size: 32, iconSize: 16,
                  backgroundColor: AppColors.surfaceVariant, borderColor: AppColors.border,
                )),
                prefixIconConstraints: BoxConstraints(minWidth: 44, maxWidth: 44, minHeight: 32),
                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                filled: true, fillColor: AppColors.surfaceVariant,
                border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(10)),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border, width: 0.5), borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary, width: 1), borderRadius: BorderRadius.circular(10)),
              ),
            ),
            SizedBox(height: 8),
            Row(children: [
              Text('${l10n.translate('paidAmount')}: ${fmtNum(widget.debt.paid)} ${currencySymbol(widget.debt.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
              Spacer(),
              Text('${l10n.translate('remainingAfterPay')}: ${fmtNum(widget.debt.remaining)} ${currencySymbol(widget.debt.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w700, color: widget.debt.type == 'payable' ? AppColors.danger : AppColors.success)),
            ]),
            SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                // Full remaining, expressed in the TYPED currency: raw debt
                // currency for collections (typed in debt currency),
                // converted to the account currency for payments (typed in
                // account currency). Falls back to the raw remaining when
                // the account — or a rate — is not known yet.
                onPressed: () => setState(() {
                    var fill = widget.debt.remaining;
                    if (widget.debt.type == 'payable') {
                      final acc = st.bankAccounts
                          .where((a) => a.id == _bankId)
                          .firstOrNull;
                      if (acc != null &&
                          acc.currency.toUpperCase() !=
                              widget.debt.currency.toUpperCase()) {
                        final r = _findRate(
                            widget.debt.currency.toUpperCase(),
                            acc.currency.toUpperCase(),
                            st.exchangeRates);
                        if (r != null && r > 0) {
                          fill = widget.debt.remaining * r;
                        }
                      }
                    }
                    _amountCtrl.text = fill == fill.roundToDouble()
                        ? fill.toStringAsFixed(0)
                        : fill.toStringAsFixed(2);
                  }),
                icon: Icon(Icons.bolt, size: 14, color: AppColors.primary),
                label: Text(l10n.translate('fullAmount'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.primary)),
                style: OutlinedButton.styleFrom(side: BorderSide(color: AppColors.primary.withAlpha(60)), padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6), minimumSize: Size(0, 32)),
              ),
            ),
            SizedBox(height: 16),
            Text(l10n.translate('payMethodLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
            SizedBox(height: 8),
            Row(children: [
              Expanded(child: _payMethodBtn(l10n.translate('payMethodCash'), TwoToneIcons.money, 'cash')),
              SizedBox(width: 10),
              Expanded(child: _payMethodBtn(l10n.translate('payMethodBank'), TwoToneIcons.bank, 'bank')),
            ]),
            if (_method == 'cash') ...[
              SizedBox(height: 12),
              Builder(builder: (_) {
                // One chip per cash bucket (summed balance): duplicate mirror
                // rows can never list a currency twice here.
                final cashAccs = PersonalFinanceService.canonicalCashAccounts(
                    st.bankAccounts);
                if (cashAccs.isEmpty) {
                  return Text(l10n.translate('noBankAccounts'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.warning));
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.translate('selectCurrency'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                    SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final a in cashAccs)
                          _currencyChip(
                            label: '${a.currency} · ${fmtNum(a.balance)}',
                            selected: _bankId == a.id,
                            onTap: () => setState(() {
                              if (cashAccs.length == 1) {
                                _bankId = a.id;
                              } else {
                                _bankId = _bankId == a.id ? null : a.id;
                              }
                            }),
                          ),
                      ],
                    ),
                  ],
                );
              }),
            ],
            if (_method == 'bank') ...[
              SizedBox(height: 12),
              Builder(builder: (_) {
                final bankNames = <String>[];
                for (final a in st.bankAccounts.where((a) => !isCashAccount(a.bankName))) {
                  if (!bankNames.contains(a.bankName)) bankNames.add(a.bankName);
                }
                if (bankNames.isEmpty) {
                  return Text(l10n.translate('noBankAccounts'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.warning));
                }
                final bankAccs = _selBankName == null
                    ? const <PersonalBankAccount>[]
                    : st.bankAccounts.where((a) => a.bankName == _selBankName).toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.translate('selectAccount'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                    SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final name in bankNames)
                          _currencyChip(
                            label: name,
                            selected: _selBankName == name,
                            onTap: () => setState(() {
                              if (_selBankName == name) {
                                _selBankName = null;
                                _bankId = null;
                              } else {
                                _selBankName = name;
                                final accs = st.bankAccounts.where((a) => a.bankName == name).toList();
                                _bankId = accs.length == 1 ? accs.first.id : null;
                              }
                            }),
                          ),
                      ],
                    ),
                    if (_selBankName != null && bankAccs.isNotEmpty) ...[
                      SizedBox(height: 12),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeInOutCubic,
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.primary.withAlpha(40)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l10n.translate('selectCurrency'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: AppColors.primary)),
                              SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final a in bankAccs)
                                    _currencyChip(
                                      // Single-currency banks show their only
                                      // currency pre-selected below.
                                      label: _bankCurrencyLabel(bankAccs, a),
                                      selected: _bankId == a.id || (bankAccs.length == 1),
                                      onTap: () => setState(() => _bankId = _bankId == a.id ? null : a.id),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              }),
            ],
            SizedBox(height: 12),
            FyonaTextField(
              controller: _notesCtrl,
              textAlign: TextAlign.right,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: l10n.translate('notesLabel'),
                hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPlaceholder),
                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                filled: true, fillColor: AppColors.surfaceVariant,
                border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(10)),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _submitting
                  ? null
                  : () async {
                if (_submitting) return;
                setState(() => _submitting = true);
                try {
                final amt = double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
                if (amt <= 0) return;
                // The overpay guard runs AFTER currency conversion below (the
                // typed amount is in the account currency, the remaining is
                // in the debt currency).
                if (st.bankAccounts.isEmpty) {
                  showDialog(context: context, builder: (ctx) => AlertDialog(
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    title: Row(children: [Icon(Icons.account_balance_wallet_outlined, color: AppColors.danger), SizedBox(width: 8), Text(l10n.translate('debtNoAccount'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))]),
                    content: Text(l10n.translate('debtNoPayAccount'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo')))],
                  ));
                  return;
                }
                if (_method == 'bank' && _selBankName == null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.translate('selectAccount'), style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.warning));
                  return;
                }
                if (_method == 'bank' && _bankId == null) {
                  // Defensive: a single-currency bank always resolves to its
                  // only account even if the tap handler state was missed.
                  if (_selBankName != null) {
                    final accs = st.bankAccounts.where((a) => a.bankName == _selBankName).toList();
                    if (accs.length == 1) {
                      _bankId = accs.first.id;
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.translate('selectCurrency'), style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.warning));
                      return;
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.translate('selectCurrency'), style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.warning));
                    return;
                  }
                }
                if (_method == 'cash') {
                  final cashAccs =
                      PersonalFinanceService.canonicalCashAccounts(
                          st.bankAccounts);
                  if (cashAccs.isEmpty) {
                    showDialog(context: context, builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Row(children: [Icon(Icons.account_balance_wallet_outlined, color: AppColors.danger), SizedBox(width: 8), Text(l10n.translate('debtNoAccount'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))]),
                      content: Text(l10n.translate('debtNoPayAccount'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
                      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo')))],
                    ));
                    return;
                  }
                  if (_bankId == null) {
                    if (cashAccs.length == 1) {
                      _bankId = cashAccs.first.id;
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.translate('selectCurrency'), style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.warning));
                      return;
                    }
                  }
                }
                // Typed-amount rule per debt direction (never mixed):
                // - receivable (owed TO me): the typed amount is in DEBT
                //   currency — it credits the debt 1:1 and the account
                //   receives the converted value (e.g. collecting 100 USD
                //   into SAR adds ~385 SAR);
                // - payable (I owe): the typed amount is in the SELECTED
                //   ACCOUNT currency and converts into the debt credit.
                // Conversion uses the latest known rate (offline-safe: last
                // synced rates, never blocking the user).
                final selAcc = st.bankAccounts.where((a) => a.id == _bankId).firstOrNull;
                final accountCurrency = (selAcc?.currency ?? widget.debt.currency).toUpperCase();
                final debtCurrency = widget.debt.currency.toUpperCase();
                final isReceivable = widget.debt.type != 'payable';
                double? rate;
                double bankMove;
                double debtCredit;
                if (isReceivable) {
                  if (accountCurrency != debtCurrency) {
                    rate = _findRate(debtCurrency, accountCurrency, st.exchangeRates);
                  }
                  final split = splitReceivableCollection(
                      amount: amt,
                      accountCurrency: accountCurrency,
                      debtCurrency: debtCurrency,
                      rate: rate);
                  bankMove = split.bankMove;
                  debtCredit = split.debtCredit;
                  if (amt > widget.debt.remaining + 0.001) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                      l10n.translate('debtPaymentExceeds', params: {'amount': fmtNum(amt), 'remaining': fmtNum(widget.debt.remaining)}),
                      style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.danger));
                    return;
                  }
                } else {
                  if (accountCurrency != debtCurrency) {
                    rate = _findRate(accountCurrency, debtCurrency, st.exchangeRates);
                  }
                  final split = splitDebtPayment(
                      amount: amt,
                      accountCurrency: accountCurrency,
                      debtCurrency: debtCurrency,
                      rate: rate);
                  bankMove = split.bankMove;
                  debtCredit = split.debtCredit;
                  // Overpay guard AFTER conversion: compare the converted debt
                  // credit against the remaining (both in debt currency). When
                  // no rate is known the amounts are in different currencies
                  // and cannot be judged — allow instead of false-warning.
                  if (rate != null && debtCredit > widget.debt.remaining + 0.001) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                      l10n.translate('debtPaymentExceeds', params: {'amount': fmtNum(debtCredit), 'remaining': fmtNum(widget.debt.remaining)}),
                      style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.danger));
                    return;
                  }
                }
                if (widget.debt.type == 'payable') {
                  // Payable: money LEAVES the account -> balance required.
                  // Receivable (owed to me): money ENTERS the account -> no
                  // balance requirement, the check is skipped entirely.
                  if (selAcc == null) {
                    showDialog(context: context, builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Row(children: [Icon(Icons.warning_amber_rounded, color: AppColors.danger), SizedBox(width: 8), Text(l10n.translate('insufficientBalance'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))]),
                      content: Text(l10n.translate('debtNoPayAccount'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
                      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo')))],
                    ));
                    return;
                  }
                  final bal = selAcc.balance;
                  if (bal < bankMove) {
                    showDialog(context: context, builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Row(children: [Icon(Icons.warning_amber_rounded, color: AppColors.danger), SizedBox(width: 8), Text(l10n.translate('insufficientBalance'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))]),
                      content: Text(l10n.translate('insufficientBalance'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
                      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo')))],
                    ));
                    return;
                  }
                }
                await widget.onPay(bankMove, _method, _bankId, _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(), _opId, accountCurrency, debtCredit);
                } finally {
                  if (mounted) setState(() => _submitting = false);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                padding: EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: _submitting
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Text(l10n.translate(widget.debt.type == 'payable' ? 'confirmPayment' : 'confirmCollection'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ],
        )),
      ]),
    );
  }

  Widget _payMethodBtn(String label, TwoToneIconData icon, String val) {
    final active = _method == val;
    return GestureDetector(
      onTap: () => setState(() { _method = val; _bankId = null; _selBankName = null; }),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? AppColors.primary.withAlpha(20) : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? AppColors.primary : AppColors.border, width: active ? 1.5 : 0.5),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TwoToneIcon(data: icon, size: 16, outlineColor: active ? AppColors.primary : AppColors.textSecondary),
          SizedBox(width: 6),
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: active ? AppColors.primary : AppColors.textSecondary)),
        ]),
      ),
    );
  }

  /// Currency/bank selectable chip with animated selection feedback.
  Widget _currencyChip({required String label, required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOutCubic,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider.withOpacity(0.35),
            width: selected ? 1.2 : 0.6,
          ),
          boxShadow: selected
              ? [BoxShadow(color: AppColors.primary.withAlpha(70), blurRadius: 10, offset: const Offset(0, 3))]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 14, color: Colors.white),
              SizedBox(width: 5),
            ],
            Text(label, style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : AppColors.textSecondary,
            )),
          ],
        ),
      ),
    );
  }

  /// Currency chip label with per-currency balance. When the same currency
  /// exists twice in one bank (e.g. checking + savings), appends the type.
  String _bankCurrencyLabel(List<PersonalBankAccount> bankAccs, PersonalBankAccount a) {
    final base = '${a.currency} · ${fmtNum(a.balance)}';
    final dupes = bankAccs.where((x) => x.currency == a.currency).length;
    if (dupes <= 1) return base;
    return '$base (${_shortAccountType(a.accountType)})';
  }

  String _shortAccountType(String type) {
    final l10n = AppLocalizations.of(context);
    switch (type) {
      case 'savings': return l10n.translate('accountTypeSavings');
      case 'credit': return l10n.translate('accountTypeCredit');
      case 'wallet': return l10n.translate('accountTypeWallet');
      case 'cash': return l10n.translate('accountTypeCash');
      case 'checking':
      default: return l10n.translate('accountTypeChecking');
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Detail Page (inline)
// ═══════════════════════════════════════════════════════════════
class _DebtDetailPage extends ConsumerWidget {
  final PersonalDebt debt;
  const _DebtDetailPage({required this.debt});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isPayable = debt.type == 'payable';
    final color = isPayable ? AppColors.danger : AppColors.success;
    final gradient = bankGradients[debt.personName.hashCode.abs() % bankGradients.length];
    final headerLabel = isPayable ? l10n.translate('oweDebtPrefix') : l10n.translate('owedDebtPrefix');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: AppColors.textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(left: 8),
            child: GestureDetector(
              onTap: () => _exportDetailPng(context, ref),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withAlpha(60), width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TwoToneIcon(data: TwoToneIcons.image, size: 18, outlineColor: AppColors.primary),
                    SizedBox(width: 6),
                    Text(l10n.translate('exportImage'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 100),
        physics: BouncingScrollPhysics(),
        children: [
          // ── Header ──
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment(-1, -1), end: Alignment(1.5, 1.5), colors: gradient),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(100), blurRadius: 32, offset: Offset(0, 12))],
            ),
            child: Stack(children: [
              Positioned(top: -20, right: -15, child: Container(width: 80, height: 80,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(15)))),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(debt.personName, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 20), fontWeight: FontWeight.w700, color: Colors.white), overflow: TextOverflow.ellipsis),
                SizedBox(height: 4),
                Text(headerLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: Colors.white.withAlpha(160))),
                SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white.withAlpha(25), borderRadius: BorderRadius.circular(4)),
                    child: Text(isPayable ? l10n.translate('debtOwedByMe') : l10n.translate('debtOwedToMe'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white)),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: color.withAlpha(60), borderRadius: BorderRadius.circular(4)),
                    child: Text(debt.status == 'paid' ? l10n.translate('debtPaid') : debt.isOverdue ? l10n.translate('debtOverdue') : l10n.translate('debtActive'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white)),
                  ),
                ]),
                SizedBox(height: 20),
                FittedBox(
                  child: Text('${fmtNum(debt.remaining)} ${currencySymbol(debt.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
                Text(l10n.translate('remainingOfTotal', params: {'amount': fmtNum(debt.amount)}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(160))),
                if (debt.paid > 0) ...[
                  SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: debt.progress, minHeight: 8, backgroundColor: Colors.white.withAlpha(30), valueColor: AlwaysStoppedAnimation<Color>(AppColors.success)),
                  ),
                  SizedBox(height: 4),
                  Text(l10n.translate('paidPercent', params: {'percent': (debt.progress * 100).toStringAsFixed(0)}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(180))),
                ],
              ]),
            ]),
          ),
          SizedBox(height: 20),
          // ── Stats ──
          Row(children: [
            Expanded(child: _detailStat(context, l10n.translate('detailAmount'), '${fmtNum(debt.amount)}', TwoToneIcons.money)),
            SizedBox(width: 10),
            Expanded(child: _detailStat(context, l10n.translate('detailPaid'), '${fmtNum(debt.paid)}', TwoToneIcons.check)),
            SizedBox(width: 10),
            Expanded(child: _detailStat(context, l10n.translate('detailRemaining'), '${fmtNum(debt.remaining)}', TwoToneIcons.arrowDown)),
          ]),
          SizedBox(height: 16),
          // ── Details ──
          _detailInfoRow(context, l10n.translate('currencyDetail'), debt.currency),
          if (debt.dueDate != null) _detailInfoRow(context, l10n.translate('dueDateLabel'), DateFormat('yyyy/MM/dd').format(debt.dueDate!)),
          if (debt.description != null && debt.description!.isNotEmpty) _detailInfoRow(context, l10n.translate('notesLabel'), debt.description!),
          _detailInfoRow(context, l10n.translate('reminderDetail'), debt.reminder ? l10n.translate('reminderOn') : l10n.translate('reminderOff')),
          SizedBox(height: 20),
          // ── Linked operations: the exact transactions behind this debt.
          // Reads the same provider list as home, so deleting an operation
          // anywhere removes it here too. Tap opens that operation's own
          // receipt; the trash icon deletes it after confirmation.
          Text(l10n.translate('paymentHistoryDetail'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          SizedBox(height: 8),
          ..._debtOpRows(context, ref, debt),
          SizedBox(height: 20),
        ],
      ),
    );
  }

  /// Display name of the app user for receipts ("me" side).
  String _myName(WidgetRef ref, AppLocalizations l10n) {
    try {
      final u = ref.read(currentUserProvider);
      final name = ((u?.fullName ?? u?.username) ?? '').trim();
      if (name.isNotEmpty) return name;
    } catch (_) {}
    return l10n.translate('myself');
  }

  List<Widget> _debtOpRows(
      BuildContext context, WidgetRef ref, PersonalDebt debt) {
    final l10n = AppLocalizations.of(context);
    final st = ref.watch(personalFinanceProvider);
    final ops = st.transactions.where((t) => t.debtId == debt.id).toList();
    sortTransactionsNewestExecutedFirst(ops);
    if (ops.isEmpty) {
      return [
        Container(
          padding: EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(Icons.receipt_long_outlined,
                size: 18, color: AppColors.textDisabled),
            SizedBox(width: 8),
            Expanded(
              child: Text(l10n.translate('noTransactions'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textSecondary)),
            ),
          ]),
        ),
      ];
    }
    return ops.map((t) {
      final isIncome = t.type == 'income';
      final color = isIncome ? AppColors.success : AppColors.danger;
      return Container(
        margin: EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          leading: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: color.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
                isIncome
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
                size: 18, color: color),
          ),
          title: Text(
            (t.description != null && t.description!.isNotEmpty)
                ? t.description!
                : t.category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary),
          ),
          subtitle: Text(
            t.date != null
                ? DateFormat('yyyy/MM/dd').format(t.date!)
                : '',
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 10),
                color: AppColors.textDisabled),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${isIncome ? '+' : '-'}${fmtNum(t.amount)} ${currencySymbol(t.currency)}',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w700,
                    color: color),
              ),
              SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded,
                    size: 19, color: AppColors.danger),
                tooltip: l10n.translate('delete'),
                onPressed: () => _confirmDeleteOp(context, ref, t),
              ),
            ],
          ),
          onTap: () => _showOpReceipt(context, ref, debt, t),
        ),
      );
    }).toList();
  }

  Future<void> _confirmDeleteOp(
      BuildContext context, WidgetRef ref, PersonalTransaction t) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.translate('confirmDeleteTransactionTitle'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.bold)),
        content: Text(l10n.translate('confirmDeleteTransaction'),
            style: TextStyle(
                fontFamily: 'Cairo', fontSize: R.fontSize(context, 13))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text(l10n.translate('cancel'),
                  style: TextStyle(fontFamily: 'Cairo'))),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text(l10n.translate('delete'),
                  style: TextStyle(
                      fontFamily: 'Cairo', color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final deleted = await ref
        .read(personalFinanceProvider.notifier)
        .deleteTransaction(t.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          deleted
              ? l10n.translate('txDeleted')
              : l10n.translate('personalErrDeleteTx'),
          style: TextStyle(fontFamily: 'Cairo')),
      backgroundColor: deleted ? AppColors.success : AppColors.danger,
    ));
  }

  /// Receipt of one debt-linked operation: from/to are the debt person and
  /// the app user (never a dash). Payable (I owe) settles من=me إلى=person;
  /// receivable (owed to me) settles من=person إلى=me.
  void _showOpReceipt(BuildContext context, WidgetRef ref, PersonalDebt debt,
      PersonalTransaction t) {
    final l10n = AppLocalizations.of(context);
    final isIncome = t.type == 'income';
    final isPayable = debt.type == 'payable';
    final me = _myName(ref, l10n);
    // Debt operations render the debt customization (or the unified
    // Default when that mode is on).
    final preset = ref
        .read(personalReceiptDesignProvider.notifier)
        .getPreset('debt');
    ReceiptModal.show(
      context,
      ReceiptData(
        title: isIncome
            ? l10n.translate('deposit')
            : l10n.translate('withdrawal'),
        amount: t.amount,
        currencySymbol: currencySymbol(t.currency),
        dateTime: t.date != null
            ? DateFormat('yyyy/MM/dd HH:mm').format(t.date!)
            : '-',
        referenceNumber: '#TX-${t.id}',
        senderName: isPayable ? me : debt.personName,
        receiverName: isPayable ? debt.personName : me,
        details: [
          ReceiptDetail(
              label: l10n.translate('txDetailCategory'), value: t.category),
          ReceiptDetail(
              label: l10n.translate('txDetailType'),
              value: isIncome
                  ? l10n.translate('deposit')
                  : l10n.translate('withdrawal')),
          if (t.description != null && t.description!.isNotEmpty)
            ReceiptDetail(
                label: l10n.translate('description'),
                value: t.description!),
        ],
      ),
      preset: preset,
    );
  }

  Widget _detailStat(BuildContext context, String label, String value, TwoToneIconData icon) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border, width: 0.5)),
      child: Column(children: [
        TwoToneIcon(data: icon, size: 18, outlineColor: AppColors.primary),
        SizedBox(height: 6),
        FittedBox(child: Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
        SizedBox(height: 2),
        FittedBox(child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textDisabled))),
      ]),
    );
  }

  Widget _detailInfoRow(BuildContext context, String label, String value) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
        Spacer(),
        Flexible(fit: FlexFit.loose, child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerEnd,
          child: Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        )),
      ]),
    );
  }

  Future<void> _exportDetailPng(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final isPayable = debt.type == 'payable';
    // Settlement direction with the app user's real name: payable (I owe)
    // settles من=me إلى=person; receivable (owed to me) settles من=person
    // إلى=me.
    final me = _myName(ref, l10n);
    final payerName = isPayable ? me : debt.personName;
    final receiverName = isPayable ? debt.personName : me;

    List<ReceiptDetail> details = [
      ReceiptDetail(label: l10n.translate('statusDetail'), value: debt.status == 'paid' ? l10n.translate('debtPaid') : debt.isOverdue ? l10n.translate('debtOverdue') : l10n.translate('debtActive')),
      ReceiptDetail(label: l10n.translate('totalAmountDetail'), value: '${fmtNum(debt.amount)} ${debt.currency}'),
      ReceiptDetail(label: l10n.translate('detailPaid'), value: '${fmtNum(debt.paid)} ${debt.currency}'),
      ReceiptDetail(label: l10n.translate('paymentPercentDetail'), value: '${(debt.progress * 100).toStringAsFixed(0)}%'),
    ];

    if (debt.dueDate != null) details.add(ReceiptDetail(label: l10n.translate('dueDateLabel'), value: DateFormat('yyyy/MM/dd').format(debt.dueDate!)));
    if (debt.description != null && debt.description!.isNotEmpty) details.add(ReceiptDetail(label: l10n.translate('notesLabel'), value: debt.description!));

    try {
      final rawPayments = await ref.read(personalFinanceProvider.notifier).getDebtPayments(debt.id);
      final paymentsStr = rawPayments.map((p) {
        final date = DateFormat('yyyy/MM/dd').format(p.paymentDate);
        return '$date — ${fmtNum(p.amount)} ${debt.currency}';
      }).join('\n');
      if (paymentsStr.isNotEmpty) details.add(ReceiptDetail(label: l10n.translate('paymentHistoryDetail'), value: paymentsStr));
    } catch (_) {}

    final debtDetailPreset = ref.read(personalReceiptDesignProvider.notifier).getPreset('debt');
    ReceiptModal.show(context, ReceiptData(
      title: isPayable
          ? l10n.translate('debtOweTitle', params: {'name': debt.personName})
          : l10n.translate('debtOwedTitle', params: {'name': debt.personName}),
      amount: debt.remaining,
      currencySymbol: currencySymbol(debt.currency),
      dateTime: DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now()),
      senderName: payerName,
      receiverName: receiverName,
      details: details,
    ), preset: debtDetailPreset);
  }
}
