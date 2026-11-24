import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/utils/storage_util.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/bank_detail/bank_detail_view.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import 'bank_detail_report_pdf.dart';

String _catDisplay(String category, AppLocalizations l10n) {
  final key = personalCategoryKey(category);
  if (key != null) return l10n.translate('cat_$key');
  if (category.startsWith('ادخار - ')) {
    return '${l10n.translate('cat_saving')} - ${category.substring('ادخار - '.length)}';
  }
  return category;
}

String _accountTypeLabel(AppLocalizations l10n, String type) {
  switch (type) {
    case 'checking': return l10n.translate('accountTypeChecking');
    case 'savings': return l10n.translate('accountTypeSavings');
    case 'credit': return l10n.translate('accountTypeCredit');
    case 'cash': return l10n.translate('accountTypeCash');
    case 'wallet': return l10n.translate('accountTypeWallet');
    default: return l10n.translate('accountTypeChecking');
  }
}

/// Personal bank detail. Data comes from the personal finance store exactly
/// as before (local first, no extra network calls); the presentation is the
/// shared [BankDetailView] (also used by Business banks).
class BankDetailPage extends ConsumerStatefulWidget {
  final String bankName;
  const BankDetailPage({super.key, required this.bankName});
  @override
  ConsumerState<BankDetailPage> createState() => _BankDetailPageState();
}

class _BankDetailPageState extends ConsumerState<BankDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).load(); });
  }

  String get _displayName => isCashAccount(widget.bankName) ? cashDisplayName() : widget.bankName;

  Future<void> _export(BankReportBundle bundle) async {
    final l10n = AppLocalizations.of(context);
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: DotsLoader()),
    );
    await Future.delayed(Duration.zero);
    try {
      final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('bank_report');
      final pdfBytes = await BankDetailReportPdf.generate(
        bundle: bundle,
        tr: (k, [p]) => l10n.translate(k, params: p),
        isAr: isAr,
        footerText: preset.footerText == 'FYONA ERP' ? null : preset.footerText,
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'fyona_bank_$timestamp.pdf';
      final file = File('${Directory.systemTemp.path}/$fileName');
      await file.writeAsBytes(pdfBytes);
      if (mounted) {
        await StorageUtil.showPdfOptions(context, file, fileName);
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
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
    final state = ref.watch(personalFinanceProvider);
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    final allAccounts = state.bankAccounts.where((a) => a.bankName == widget.bankName).toList();
    final ids = allAccounts.map((a) => a.id).toSet();
    final bankTxs = state.transactions.where((t) => ids.contains(t.accountId)).toList();

    final accounts = [
      for (final a in allAccounts)
        BankDetailAccount(
          id: a.id,
          currency: a.currency,
          typeLabel: _accountTypeLabel(l10n, a.accountType),
          balance: a.balance,
          note: a.notes,
        ),
    ];
    final movements = [
      for (final t in bankTxs)
        BankDetailMovement(
          id: t.id,
          accountId: t.accountId ?? '',
          currency: t.currency,
          isIn: t.type == 'income',
          amount: t.amount,
          date: t.date,
          title: t.type == 'income' ? l10n.translate('deposit') : l10n.translate('withdrawal'),
          category: _catDisplay(t.category, l10n),
          note: t.description,
          color: t.type == 'income' ? AppColors.success : AppColors.danger,
          icon: t.type == 'income' ? TwoToneIcons.arrowDown : TwoToneIcons.arrowUp,
        ),
    ];

    return BankDetailView(
      bankName: _displayName,
      accounts: accounts,
      movements: movements,
      walletCurrency: walletCurrency,
      toWallet: (amount, from) {
        if (from == walletCurrency) return amount;
        final converted = engine.convert(amount, from, walletCurrency);
        return converted != 0 ? converted : amount;
      },
      onRefresh: () => ref.read(personalFinanceProvider.notifier).load(),
      onExport: _export,
    );
  }
}
