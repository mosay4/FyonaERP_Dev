import 'dart:io';
import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/utils/storage_util.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/bank_detail/bank_detail_view.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../data/business_bank_models.dart';
import '../providers/business_banks_providers.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../bank_transaction_visual.dart';
import '../../../personal/presentation/providers/receipt_design_provider.dart';
import '../../../personal/presentation/pages/bank_detail_report_pdf.dart';

/// Business bank detail. Data is org-level and fully separate from Personal:
/// accounts from [businessBanksProvider], movements from the same source's
/// `history` (the on-device ledger in local mode — offline keeps working).
/// The presentation is the shared [BankDetailView] (currency selector,
/// key figures, in/out analysis, accounts, movements, PDF export).
class BusinessBankDetailPage extends ConsumerStatefulWidget {
  final String bankName;
  final String? groupId;
  const BusinessBankDetailPage({super.key, required this.bankName,
      this.groupId});
  @override
  ConsumerState<BusinessBankDetailPage> createState() =>
      _BusinessBankDetailPageState();
}

class _BusinessBankDetailPageState
    extends ConsumerState<BusinessBankDetailPage> {
  List<Map<String, dynamic>> _allTxs = [];
  bool _txLoading = false;
  bool _txFailed = false;
  int _loadGeneration = 0;

  Future<void> _unlinkAccounts() async {
    if (!BranchScope.allMode || !ref.read(employeeCanProvider('banks.add_delete'))) return;
    final l10n = AppLocalizations.of(context);
    final source = ref.read(businessBanksProvider.notifier);
    final ids = ref
        .read(businessBanksProvider)
        .accounts
        .where(_matchesGroup)
        .map((a) => a.id)
        .toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.translate('bankLinkUnlink'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 15)),
        content: Text(l10n.translate('bankLinkBody'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 11)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('bankLinkUnlink'),
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok != true || !mounted || !source.isCurrent || !BranchScope.allMode ||
        !ref.read(employeeCanProvider('banks.add_delete'))) return;
    try {
      await ref.read(businessBanksApiProvider).unlinkAccounts(ids);
      await ref.read(businessBanksProvider.notifier).load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('bankLinkUnlinked'),
              style: const TextStyle(fontFamily: 'Cairo'))));
      context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$e',
                style: const TextStyle(fontFamily: 'Cairo'))));
      }
    }
  }

  bool _matchesGroup(BusinessBankAccount a) =>
      widget.groupId != null && widget.groupId!.isNotEmpty
          ? a.groupKey == widget.groupId
          : a.bankName == widget.bankName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    await ref.read(businessBanksProvider.notifier).load();
    if (!mounted) return;
    await _loadAllTx();
  }

  Future<void> _loadAllTx() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final source = ref.read(businessBanksProvider.notifier);
    final accounts = ref.read(businessBanksProvider).accounts;
    final mine = accounts.where(_matchesGroup).toList();
    if (mine.isEmpty) {
      if (mounted) setState(() => _allTxs = []);
      return;
    }
    setState(() {
      _txLoading = true;
      _txFailed = false;
    });
    try {
      final rows = await source.history(mine.map((a) => a.id).toList());
      if (!mounted || !source.isCurrent || generation != _loadGeneration) return;
      setState(() {
        _allTxs = rows;
        _txLoading = false;
      });
    } catch (_) {
      if (mounted && source.isCurrent && generation == _loadGeneration) {
        setState(() {
          _allTxs = [];
          _txLoading = false;
          _txFailed = true;
        });
      }
    }
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  DateTime? _txDate(Map<String, dynamic> t) {
    try {
      final raw = t['date']?.toString();
      if (raw == null || raw.isEmpty) return null;
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  double _inWallet(double amount, String currency, String wallet,
      BusinessBanksNotifier source) {
    if (currency == wallet) return amount;
    final converted = source.convert(amount, currency, wallet);
    return source.isLocal || converted != 0 ? converted : amount;
  }

  Future<void> _export(
      BankReportBundle bundle, BusinessBanksNotifier source) async {
    final l10n = AppLocalizations.of(context);
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    bool canExport() => mounted && source.isCurrent &&
        ref.read(businessBankBalanceReadProvider) &&
        ref.read(employeeCanProvider('reports.view')) &&
        ref.read(employeeCanProvider('reports.export')) &&
        (!source.isLocal || ref.read(employeeCanProvider('banks.details')));
    if (!canExport()) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: DotsLoader()),
    );
    await Future.delayed(Duration.zero);

    try {
      final preset = ref
          .read(personalReceiptDesignProvider.notifier)
          .getPreset('bank_report');
      final pdfBytes = await BankDetailReportPdf.generate(
        bundle: bundle,
        tr: (k, [p]) => l10n.translate(k, params: p),
        isAr: isAr,
        footerText:
            preset.footerText == 'FYONA ERP' ? null : preset.footerText,
      );

      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (!canExport()) return;

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'fyona_bank_$timestamp.pdf';
      final file = File('${Directory.systemTemp.path}/$fileName');
      await file.writeAsBytes(pdfBytes);

      if (canExport()) {
        await StorageUtil.showPdfOptions(context, file, fileName);
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              l10n.translate('pdfExportFailed',
                  params: {'error': '$e'}),
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(businessBanksProvider);
    final source = ref.watch(businessBanksProvider.notifier);
    final details = ref.watch(employeeCanProvider('banks.details'));
    ref.listen(businessBanksProvider.notifier, (_, _) {
      _loadGeneration++;
      _allTxs = [];
      _txLoading = _txFailed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    });
    if (source.isLocal) {
      ref.listen(businessBankRevisionProvider, (_, _) => _loadAllTx());
      ref.listen(employeeCanProvider('banks.details'), (_, allowed) {
        if (allowed) {
          _loadAllTx();
        } else {
          _loadGeneration++;
          _allTxs = [];
          _txLoading = _txFailed = false;
        }
      });
    }
    final balanceRead = ref.watch(businessBankBalanceReadProvider);
    final canExport = balanceRead &&
        ref.watch(employeeCanProvider('reports.view')) &&
        ref.watch(employeeCanProvider('reports.export'));
    final canUnlink = (widget.groupId ?? '').startsWith('link:') &&
        ref.watch(employeeCanProvider('banks.add_delete'));

    final allAccounts = state.accounts
        .where((_) => !source.isLocal || details)
        .where(_matchesGroup)
        .toList();
    final walletCurrency = state.walletCurrency;
    final byId = {for (final a in allAccounts) a.id: a};
    final bankTxs = source.isLocal
        ? _allTxs.where((row) => byId.containsKey(row['bank_account_id']))
        : _allTxs;

    final accounts = [
      for (final a in allAccounts)
        BankDetailAccount(
          id: a.id,
          currency: a.currency,
          typeLabel: a.accountType == 'savings'
              ? l10n.translate('accountTypeSavings')
              : l10n.translate('accountTypeChecking'),
          balance: a.balance,
          note: [
            if (a.accountName.trim().isNotEmpty &&
                a.accountName.trim() != a.bankName.trim())
              a.accountName.trim(),
            if (a.accountNumber.trim().isNotEmpty) a.accountNumber.trim(),
          ].join(' · '),
        ),
    ];
    var index = 0;
    final movements = [
      for (final t in bankTxs)
        () {
          final visual = BankTransactionVisual('${t['tx_type'] ?? ''}');
          final accountId = (t['bank_account_id'] ?? '').toString();
          final currency = (t['currency'] ?? '').toString().trim();
          index++;
          return BankDetailMovement(
            id: (t['id'] ?? 'row$index').toString(),
            accountId: accountId,
            currency: currency.isNotEmpty
                ? currency
                : (byId[accountId]?.currency ?? walletCurrency),
            isIn: visual.isIn,
            amount: _asDouble(t['amount']).abs(),
            date: _txDate(t),
            title: visual.label(l10n),
            note: (t['description'] ?? '').toString(),
            color: visual.color,
            icon: visual.icon,
          );
        }(),
    ];

    return BankDetailView(
      bankName: isBizCashAccount(widget.bankName)
          ? l10n.translate('cashAccount')
          : widget.bankName,
      accounts: accounts,
      movements: movements,
      walletCurrency: walletCurrency,
      toWallet: (amount, from) =>
          _inWallet(amount, from, walletCurrency, source),
      showBalances: balanceRead,
      canExport: canExport,
      headerActions: [
        if (canUnlink)
          IconButton(
            tooltip: l10n.translate('bankLinkUnlink'),
            icon: const Icon(Icons.link_off_rounded, color: Colors.white),
            onPressed: _unlinkAccounts,
          ),
      ],
      onRefresh: () async {
        await ref.read(businessBanksProvider.notifier).load();
        await _loadAllTx();
      },
      onExport: (bundle) => _export(bundle, source),
      movementsLoading: _txLoading && !source.isLocal,
      failureText: _txFailed
          ? l10n.translate(
              source.isLocal ? 'txOperationFailed' : 'coreNetworkError')
          : null,
      onRetry: _loadAllTx,
    );
  }
}
