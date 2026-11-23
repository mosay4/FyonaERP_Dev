import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/core/utils/storage_util.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icon.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icons.dart';
import 'package:fyona_flutter/shared/widgets/dots_loader.dart';
import 'package:fyona_flutter/shared/widgets/app_icon_badge.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import 'account_tree_report_pdf.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class PersonalAccountTreePage extends ConsumerStatefulWidget {
  const PersonalAccountTreePage({super.key});
  @override
  ConsumerState<PersonalAccountTreePage> createState() => _PersonalAccountTreePageState();
}

class _PersonalAccountTreePageState extends ConsumerState<PersonalAccountTreePage> {
  final Set<String> _expandedBanks = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(personalFinanceProvider.notifier).load();
    });
  }

  void _load() => ref.read(personalFinanceProvider.notifier).load();

  Map<String, String> _buildTranslations(AppLocalizations l10n) => {
    for (final k in [
      'clientName', 'reportCreatedOn', 'banksSection', 'noBanks', 'goalsSection', 'noGoals',
      'debtsSection', 'noDebts', 'accountsCount', 'paidStatus', 'overdueStatus', 'activeStatus',
      'unknownPerson', 'totalAmount', 'paidLabel', 'remainingLabel', 'totalAssets', 'totalPayable',
      'totalReceivable', 'netWorth', 'exportedOn',
      'accountTypeChecking', 'accountTypeSavings', 'accountTypeCredit', 'accountTypeCash',
    ])
      k: l10n.translate(k),
  };

  Future<void> _exportReport() async {
    final l10n = AppLocalizations.of(context);
    final st = ref.read(personalFinanceProvider);
    final fn = ref.read(personalFinanceProvider.notifier);
    final user = ref.read(authProvider).user;

    final titleCtrl = TextEditingController(text: l10n.translate('accountTreeTitle'));
    final clientCtrl = TextEditingController(text: user?.fullName ?? '');
    final periodCtrl = TextEditingController(
      text: DateFormat('MMMM yyyy').format(DateTime.now()),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('reportOptionsTitle'), style:  TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FyonaTextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: l10n.translate('reportNameLabel'),
                labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                enabledBorder:  UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
              ),
            ),
            const SizedBox(height: 10),
            FyonaTextField(
              controller: clientCtrl,
              decoration: InputDecoration(
                labelText: l10n.translate('clientName'),
                labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                enabledBorder:  UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
              ),
            ),
            const SizedBox(height: 10),
            FyonaTextField(
              controller: periodCtrl,
              decoration: InputDecoration(
                labelText: l10n.translate('periodLabel'),
                labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                enabledBorder:  UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.translate('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.translate('generateReport'), style: const TextStyle(fontFamily: 'Cairo', color: AppColors.primary))),
        ],
      ),
    );

    final reportTitle = titleCtrl.text.isEmpty ? l10n.translate('accountTreeTitle') : titleCtrl.text;
    final clientName = clientCtrl.text;
    final period = periodCtrl.text;

    titleCtrl.dispose();
    clientCtrl.dispose();
    periodCtrl.dispose();
    if (confirmed != true || !mounted) return;

    final progressNotifier = ValueNotifier<String>(l10n.translate('stepPreparingData'));
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: progressNotifier,
            builder: (ctx, step, _) => Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const DotsLoader(),
                  const SizedBox(height: 16),
                  Text(
                    l10n.translate('exportProgressTitle'),
                    style:  TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 6),
                  Text(step, style:  TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await Future.delayed(Duration.zero);

    try {
      progressNotifier.value = l10n.translate('stepPreparingData');

      final accounts = st.bankAccounts;
      final goals = st.savingsGoals;
      final debts = st.debts;
      final totalAssets = st.walletTotalBalance;
      final totalPayable = fn.totalPayable;
      final totalReceivable = fn.totalReceivable;
      final netWorth = st.netWorth;
      final walletCurrency = currencySymbol(st.walletCurrency);

      progressNotifier.value = l10n.translate('stepBuildingReport');

      final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('report');
      Uint8List? logoBytes;
      try {
        final logoFile = File('${(await getApplicationDocumentsDirectory()).path}/logo.png');
        if (await logoFile.exists()) logoBytes = await logoFile.readAsBytes();
      } catch (_) {}
      logoBytes ??= await _loadDefaultLogo();

      final pdfBytes = await AccountTreeReportPdfGenerator.generate(
        reportTitle: reportTitle,
        clientName: clientName,
        period: period,
        banks: accounts,
        goals: goals,
        debts: debts,
        walletCurrency: walletCurrency,
        totalAssets: totalAssets,
        totalPayable: totalPayable,
        totalReceivable: totalReceivable,
        netWorth: netWorth,
        preset: preset,
        logoBytes: logoBytes,
        translations: _buildTranslations(l10n),
      );

      progressNotifier.value = l10n.translate('stepSavingFile');

      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'fyona_account_tree_$timestamp.pdf';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(pdfBytes);

      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      progressNotifier.dispose();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('exportCompleted'), style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 2),
        ));
        await StorageUtil.showPdfOptions(context, file, fileName);
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      progressNotifier.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('pdfExportFailed', params: {'error': '$e'}), style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = ref.watch(personalFinanceProvider);
    final fn = ref.read(personalFinanceProvider.notifier);

    final grouped = <String, List<PersonalBankAccount>>{};
    for (final a in st.bankAccounts) {
      grouped.putIfAbsent(a.bankName, () => []).add(a);
    }

    return st.isLoading
          ? Center(child: DotsLoader())
          : RefreshIndicator(
              onRefresh: () async => _load(),
              color: AppColors.primary,
              backgroundColor: AppColors.surface,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 100),
                children: [
                  _buildHeader(context, l10n, st),
                  _buildKpiCards(context, l10n, st, fn),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: _SectionTitle(title: l10n.translate('banksSection'), icon: TwoToneIcons.bank),
                  ),
                  if (grouped.isEmpty)
                    _buildEmpty(context, l10n, l10n.translate('noBanks'))
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: grouped.entries.map((e) => _BankTreeNode(
                          bankName: e.key,
                          accounts: e.value,
                          walletCurrency: st.walletCurrency,
                          notifier: ref.read(personalFinanceProvider.notifier),
                          expanded: _expandedBanks.contains(e.key),
                          onToggle: () {
                            setState(() {
                              if (!_expandedBanks.remove(e.key)) _expandedBanks.add(e.key);
                            });
                          },
                        )).toList(),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: _SectionTitle(title: l10n.translate('goalsSection'), icon: TwoToneIcons.savingsGoal),
                  ),
                  if (st.savingsGoals.isEmpty)
                    _buildEmpty(context, l10n, l10n.translate('noGoals'))
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: st.savingsGoals.map((g) => _GoalTreeNode(goal: g)).toList(),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: _SectionTitle(title: l10n.translate('debtsSection'), icon: TwoToneIcons.debt),
                  ),
                  if (st.debts.isEmpty)
                    _buildEmpty(context, l10n, l10n.translate('noDebts'))
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: st.debts.map((d) => _DebtTreeNode(debt: d)).toList(),
                      ),
                    ),
                ],
              ),
            );
  }

  Widget _buildEmpty(BuildContext context, AppLocalizations l10n, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          TwoToneIcon(data: TwoToneIcons.invoice, size: 30, outlineColor: AppColors.textDisabled),
          const SizedBox(height: 8),
          Text(text, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n, PersonalFinanceState st) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-1.0, -1.0), end: Alignment(1.5, 1.5),
          colors: [const Color(0xFFC01838), AppColors.primary, const Color(0xFF7A1020)],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        boxShadow: [
          BoxShadow(color: AppColors.primary.withAlpha(100), blurRadius: 32, offset: const Offset(0, 12)),
          BoxShadow(color: AppColors.primaryDark.withAlpha(60), blurRadius: 48, offset: const Offset(0, 24)),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(color: Colors.white.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 18),
              ),
            ),
            const SizedBox(width: 12),
            AppIconBadge(icon: TwoToneIcons.layers.outline, size: 44, iconSize: 22, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.translate('accountTreeTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
              const SizedBox(height: 2),
              Text(l10n.translate('accountTreeSubtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(180))),
            ])),
            IconButton(
              tooltip: l10n.translate('exportAccountTree'),
              icon: const Icon(Icons.receipt_long, color: Colors.white, size: 22),
              onPressed: _exportReport,
            ),
          ]),
          const SizedBox(height: 20),
          Text(l10n.translate('netWorth'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(160))),
          const SizedBox(height: 2),
          Text(fmtNum(st.netWorth), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 20), fontWeight: FontWeight.w700, color: Colors.white.withAlpha(220))),
        ]),
      ),
    );
  }

  Widget _buildKpiCards(BuildContext context, AppLocalizations l10n, PersonalFinanceState st, PersonalFinanceNotifier fn) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(children: [
        _KpiCard(label: l10n.translate('totalAssets'), amount: st.walletTotalBalance, color: AppColors.primary, icon: TwoToneIcons.bank),
        const SizedBox(width: 8),
        _KpiCard(label: l10n.translate('totalPayable'), amount: fn.totalPayable, color: const Color(0xFFC62828), icon: TwoToneIcons.arrowUp),
        const SizedBox(width: 8),
        _KpiCard(label: l10n.translate('totalReceivable'), amount: fn.totalReceivable, color: const Color(0xFF2E7D32), icon: TwoToneIcons.arrowDown),
      ]),
    );
  }

  Future<Uint8List?> _loadDefaultLogo() async {
    try {
      final data = await rootBundle.load('assets/images/logo.png');
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final TwoToneIconData icon;
  const _SectionTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AppIconBadge(icon: icon.outline, size: 28, iconSize: 14, backgroundColor: AppColors.primary.withAlpha(20), borderColor: AppColors.primary.withAlpha(40)),
      const SizedBox(width: 8),
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
    ]);
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final TwoToneIconData icon;
  const _KpiCard({required this.label, required this.amount, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            TwoToneIcon(data: icon, size: 14, outlineColor: color),
            const SizedBox(width: 6),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: AppColors.textSecondary))),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(fmtNum(amount), maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
      ),
    );
  }
}

class _BankTreeNode extends StatelessWidget {
  final String bankName;
  final List<PersonalBankAccount> accounts;
  final String walletCurrency;
  final PersonalFinanceNotifier notifier;
  final bool expanded;
  final VoidCallback onToggle;

  const _BankTreeNode({
    required this.bankName,
    required this.accounts,
    required this.walletCurrency,
    required this.notifier,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final convertedTotal = notifier.convertAccountsToWallet(accounts);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              AppIconBadge(icon: TwoToneIcons.bank.outline, size: 34, iconSize: 17, backgroundColor: AppColors.primary.withAlpha(18), borderColor: AppColors.primary.withAlpha(35)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(bankName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                Text('${accounts.length} ${AppLocalizations.of(context).translate('accountsCount', params: {'count': accounts.length})}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: AppColors.textSecondary)),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(fmtNum(convertedTotal), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.primary)),
                Text(currencySymbol(walletCurrency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: AppColors.textDisabled)),
              ]),
              const SizedBox(width: 6),
              Icon(expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: AppColors.textSecondary, size: 20),
            ]),
          ),
        ),
        if (expanded) ...[
          Divider(height: 1, color: AppColors.border),
          ...accounts.map((a) => _AccountLeaf(account: a)),
        ],
      ]),
    );
  }
}

class _AccountLeaf extends StatelessWidget {
  final PersonalBankAccount account;
  const _AccountLeaf({required this.account});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final typeLabel = account.accountType == 'cash'
        ? l10n.translate('accountTypeCash')
        : account.accountType == 'savings'
            ? l10n.translate('accountTypeSavings')
            : account.accountType == 'checking'
                ? l10n.translate('accountTypeChecking')
                : account.accountType == 'credit'
                    ? l10n.translate('accountTypeCredit')
                    : account.accountType;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 18, 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border.withAlpha(80)))),
      child: Row(children: [
        const SizedBox(width: 12),
        Container(width: 12, height: 1.5, color: AppColors.textDisabled),
        const SizedBox(width: 10),
        Expanded(child: Text(isCashAccount(account.bankName) ? cashDisplayName() : account.bankName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(6)),
          child: Text(typeLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: AppColors.textDisabled)),
        ),
        const SizedBox(width: 10),
        Text('${fmtNum(account.balance)} ${currencySymbol(account.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      ]),
    );
  }
}

class _GoalTreeNode extends StatelessWidget {
  final SavingsGoal goal;
  const _GoalTreeNode({required this.goal});

  @override
  Widget build(BuildContext context) {
    final pct = goal.progress;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIconBadge(icon: TwoToneIcons.savingsGoal.outline, size: 34, iconSize: 17, backgroundColor: AppColors.primary.withAlpha(18), borderColor: AppColors.primary.withAlpha(35)),
          const SizedBox(width: 10),
          Expanded(child: Text(goal.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
          Text('${(pct * 100).toStringAsFixed(1)}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: AppColors.primary)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Text(fmtNum(goal.currentAmount), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          Text(' / ${fmtNum(goal.targetAmount)} ${currencySymbol(goal.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
          if (goal.deadline != null && goal.deadline!.isNotEmpty) ...[
            const Spacer(),
            Icon(Icons.calendar_today, size: 11, color: AppColors.textDisabled),
            const SizedBox(width: 4),
            Text(goal.deadline!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: AppColors.textDisabled)),
          ],
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 6,
            backgroundColor: AppColors.surfaceVariant,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        ),
      ]),
    );
  }
}

class _DebtTreeNode extends StatelessWidget {
  final PersonalDebt debt;
  const _DebtTreeNode({required this.debt});

  @override
  Widget build(BuildContext context) {
    final isPayable = debt.type == 'payable';
    final color = isPayable ? const Color(0xFFC62828) : const Color(0xFF2E7D32);
    final status = debt.isPaid
        ? AppLocalizations.of(context).translate('paidStatus')
        : debt.isOverdue
            ? AppLocalizations.of(context).translate('overdueStatus')
            : AppLocalizations.of(context).translate('activeStatus');
    final pct = debt.progress;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIconBadge(icon: TwoToneIcons.debt.outline, size: 34, iconSize: 17, backgroundColor: color.withAlpha(18), borderColor: color.withAlpha(35)),
          const SizedBox(width: 10),
          Expanded(child: Text(debt.personName.isEmpty ? AppLocalizations.of(context).translate('unknownPerson') : debt.personName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withAlpha(18), borderRadius: BorderRadius.circular(8)),
            child: Text(status, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Text('${AppLocalizations.of(context).translate('totalAmount')}: ${fmtNum(debt.amount)} ${currencySymbol(debt.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
          const Spacer(),
          Text('${AppLocalizations.of(context).translate('paidLabel')}: ${fmtNum(debt.paid)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Text('${AppLocalizations.of(context).translate('remainingLabel')}: ', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
          Text('${fmtNum(debt.remaining)} ${currencySymbol(debt.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: color)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 6,
            backgroundColor: AppColors.surfaceVariant,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ]),
    );
  }
}
