import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../widgets/recon_art.dart';
import '../widgets/recon_widgets.dart';
import '../../../employees/presentation/providers/employee_providers.dart';

/// Reconciliation home — exactly TWO main luxury cards (bank/cash +
/// inventory) with the archive as a quiet secondary link below.
class ReconciliationHomePage extends ConsumerWidget {
  const ReconciliationHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => reconBack(context),
        ),
        title: Text(l10n.translate('recon'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 18),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text(l10n.translate('reconSubtitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    color: AppColors.textSecondary)),
            const SizedBox(height: 26),
            if (ref.watch(employeeCanProvider('reconciliation.bank')) &&
                ref.watch(employeeCanProvider('banks.balances'))) _MainCard(
              title: l10n.translate('reconBankTitle'),
              subtitle: l10n.translate('reconBankSubtitle'),
              art: ReconArtKind.bank,
              dark: dark,
              onTap: () => context.push(RouteNames.reconciliationBank),
            ),
            const SizedBox(height: 18),
            if (ref.watch(employeeCanProvider('reconciliation.inventory')) && ref.watch(employeeCanProvider('inventory.count'))) _MainCard(
              title: l10n.translate('reconInventoryTitle'),
              subtitle: l10n.translate('reconInventorySubtitle'),
              art: ReconArtKind.inventory,
              dark: dark,
              onTap: () => context.push(RouteNames.reconciliationInventory),
            ),
            const SizedBox(height: 18),
            // Third SUB button — past matches (secondary style, full width).
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: AppColors.primary.withAlpha(120)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => context.push(RouteNames.reconciliationArchive),
                icon: const Icon(Icons.history_rounded,
                    size: 20, color: AppColors.primary),
                label: Text(l10n.translate('reconArchive'),
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: AppColors.primary)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MainCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final ReconArtKind art;
  final bool dark;
  final VoidCallback onTap;
  const _MainCard({
    required this.title,
    required this.subtitle,
    required this.art,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ReconTiltCard(
      onTap: onTap,
      elevation: 10,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.primary.withAlpha(70)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(18),
                borderRadius: BorderRadius.circular(16),
              ),
              child: ReconGlyph(art == ReconArtKind.inventory
                        ? ReconGlyphKind.inventory
                        : ReconGlyphKind.bank,
                    size: 48),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 15),
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 6),
                  Text(subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          height: 1.4,
                          color: AppColors.textSecondary)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text(AppLocalizations.of(context).translate('reconStartRecon'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 12),
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary)),
                    const SizedBox(width: 6),
                    const Icon(Icons.arrow_forward_rounded,
                        size: 15, color: AppColors.primary),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
