import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/invoice_design_models.dart';
import '../providers/invoice_design_provider.dart';
import '../widgets/invoice_preview_card.dart';

/// Business invoice customization hub. Same horizontal compact cards as the
/// Personal receipt hub, but each card shows a REAL miniature of that invoice
/// design (rendered with the SAME preview widget) — not a generic placeholder.
class InvoiceDesignHubPage extends ConsumerWidget {
  const InvoiceDesignHubPage({super.key});

  Map<String, dynamic> _saleSample() => {
        'invoice_number': 'INV-2026-0001',
        'invoice_date': DateTime.now().toIso8601String(),
        'customer_name': 'أحمد محمد سالم',
        'currency': 'SAR',
        'branch_name': 'الفرع الرئيسي',
        'subtotal': 240.0,
        'discount_amount': 0.0,
        'tax_amount': 0.0,
        'total': 240.0,
        'paid_amount': 240.0,
        'balance': 0,
        'notes': '',
        'items': [
          {'description': 'ساعة فيونا', 'quantity': 2, 'unit_price': 120, 'discount': 0, 'total': 240},
        ],
      };

  Map<String, dynamic> _returnSample() => {
        'invoice_number': 'RET-2026-0001',
        'invoice_type': 'sale_return',
        'customer_name': 'أحمد محمد سالم',
        'invoice_date': DateTime.now().toIso8601String(),
        'currency': 'SAR',
        'branch_name': 'الفرع الرئيسي',
        'total': 120.0,
        'notes': 'منتج تالف',
        'original_invoice': 'INV-2026-0001',
        'items': [
          {'description': 'ساعة فيونا', 'quantity': 1, 'unit_price': 120, 'discount': 0, 'total': 120},
        ],
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final designs = ref.watch(invoiceDesignProvider);

    final sale = ['paper', 'thermal', 'thermal58'];
    final returns = ['return_paper', 'return_thermal', 'return_thermal58'];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              color: AppColors.textPrimary, size: 20),
          onPressed: () => context.pop(),
        ),
        title: Text(l10n.translate('invDesignHubTitle'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        centerTitle: true,
      ),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, 12)),
        children: [
          _sectionHeader(context, l10n.translate('invDesignSalesSection')),
          ...sale.map((id) => _DesignCard(
                design: designs[id] ?? InvoiceDesignPreset.defaults(id),
                sample: _saleSample(),
                onOpen: () => context.push(
                    '${RouteNames.invoicesDesignEdit}?template=$id'),
                onReset: () => ref
                    .read(invoiceDesignProvider.notifier)
                    .resetToDefaults(id),
              )),
          SizedBox(height: R.spacing(context, 6)),
          _sectionHeader(context, l10n.translate('invDesignReturnSection')),
          ...returns.map((id) => _DesignCard(
                design: designs[id] ?? InvoiceDesignPreset.defaults(id),
                sample: _returnSample(),
                onOpen: () => context.push(
                    '${RouteNames.invoicesDesignEdit}?template=$id'),
                onReset: () => ref
                    .read(invoiceDesignProvider.notifier)
                    .resetToDefaults(id),
              )),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String t) => Padding(
        padding: EdgeInsets.fromLTRB(R.spacing(context, 2),
            R.spacing(context, 4), R.spacing(context, 2), R.spacing(context, 10)),
        child: Text(t,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.font(context),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      );
}

class _DesignCard extends StatelessWidget {
  final InvoiceDesignPreset design;
  final Map<String, dynamic> sample;
  final VoidCallback onOpen;
  final VoidCallback onReset;
  const _DesignCard(
      {required this.design,
      required this.sample,
      required this.onOpen,
      required this.onReset});

  String _titleKey(String id) => switch (id) {
        'paper' => 'invDesignPaperTitle',
        'thermal' => 'invDesignThermalTitle',
        'thermal58' => 'invDesignThermal58Title',
        'return_paper' => 'invDesignReturnPaperTitle',
        'return_thermal' => 'invDesignReturnThermalTitle',
        'return_thermal58' => 'invDesignReturnThermal58Title',
        _ => 'invDesignPaperTitle',
      };

  String _hintKey(String id) => switch (id) {
        'paper' => 'invDesignPaperHint',
        'thermal' => 'invDesignThermalHint',
        'thermal58' => 'invDesignThermal58Hint',
        'return_paper' => 'invDesignPaperHint',
        'return_thermal' => 'invDesignThermalHint',
        'return_thermal58' => 'invDesignThermal58Hint',
        _ => 'invDesignPaperHint',
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isThermal = design.templateId.contains('thermal');
    final isNarrow = design.templateId.endsWith('thermal58');
    return Container(
      margin: EdgeInsets.only(bottom: R.spacing(context, 10)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onOpen,
          child: Padding(
            padding: EdgeInsets.all(R.spacing(context, 12)),
            child: Row(
              children: [
                // REAL miniature of this exact design.
                Container(
                  width: 72,
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border, width: 0.5),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: isNarrow ? 200 : (isThermal ? 260 : 595),
                      child: InvoicePreviewCard(
                        invoice: sample,
                        design: design,
                        isPurchase: false,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: R.spacing(context, 12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.translate(_titleKey(design.templateId)),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.font(context),
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 4),
                      Text(l10n.translate(_hintKey(design.templateId)),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.font(context, 'caption'),
                              color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.restart_alt,
                      size: 18, color: AppColors.textSecondary),
                  tooltip: l10n.translate('clear'),
                  onPressed: onReset,
                ),
                Icon(Icons.arrow_back_ios_new,
                    size: 18, color: AppColors.textDisabled),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
