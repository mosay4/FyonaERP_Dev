import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../inventory/presentation/providers/warehouse_settings.dart';
import '../widgets/recon_art.dart';
import '../widgets/recon_widgets.dart';

/// Inventory reconciliation scope — THREE SQUARE cards (icon + name +
/// one-line simple description) with tight, even spacing. The category card
/// appears only when categories are enabled in the warehouse settings.
class ReconInventoryScopePage extends ConsumerWidget {
  const ReconInventoryScopePage({super.key});

  void _go(BuildContext context, String scope) {
    unawaited(ScanSfx.warmUp());
    context.push('${RouteNames.reconciliationInventoryPick}?scope=$scope');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ws = ref.watch(warehouseSettingsProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cards = <(String, String, ReconArtKind, String)>[
      (
        l10n.translate('reconInvProduct'),
        l10n.translate('reconInvProductDesc'),
        ReconArtKind.inventory,
        'product'
      ),
      if (ws.categories)
        (
          l10n.translate('reconInvCategory'),
          l10n.translate('reconInvCategoryDesc'),
          ReconArtKind.inventory,
          'category'
        ),
      (
        l10n.translate('reconInvFull'),
        l10n.translate('reconInvFullDesc'),
        ReconArtKind.inventory,
        'full'
      ),
    ];
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
        title: Text(l10n.translate('reconInventoryTab'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (title, desc, art, scope) in cards)
                SizedBox(
                  width: (MediaQuery.of(context).size.width - 44) / 2,
                  child: _ScopeSquare(
                    title: title,
                    desc: desc,
                    art: art,
                    dark: dark,
                    onTap: () => _go(context, scope),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScopeSquare extends StatelessWidget {
  final String title;
  final String desc;
  final ReconArtKind art;
  final bool dark;
  final VoidCallback onTap;
  const _ScopeSquare({
    required this.title,
    required this.desc,
    required this.art,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // Square-ish card: art on top, name, then a simple description line.
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.primary.withAlpha(55)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withAlpha(dark ? 110 : 24),
                blurRadius: 14,
                offset: const Offset(0, 6)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ReconGlyph(ReconGlyphKind.inventory, size: 40),
            ),
            const SizedBox(height: 10),
            Text(title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12.5),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text(desc,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    height: 1.35,
                    color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
