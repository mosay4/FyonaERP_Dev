import 'package:flutter/material.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/financial_cinema.dart';
import 'recon_scenes.dart';

enum ReconSceneVariant {
  bank,
  cash,
  inventoryProduct,
  inventoryCategory,
  inventoryFull,
}

enum ReconEqualizeKind { bank, cash, product, category, store }

enum ReconSuccessAction { again, exit }

class ReconCoreOverlay extends StatelessWidget {
  const ReconCoreOverlay({
    super.key,
    required this.variant,
    required this.processingText,
    required this.future,
    required this.onResult,
    required this.onError,
    this.duration = const Duration(milliseconds: 2700),
  });
  final ReconSceneVariant variant;
  final String processingText;
  final Future<dynamic> future;
  final void Function(BuildContext, dynamic) onResult;
  final void Function(BuildContext, Object) onError;
  final Duration duration;

  @override
  Widget build(BuildContext context) => FinancialOperationScene(
    scene: FinancialScene.precision,
    title: AppLocalizations.of(context).translate('reconScanningTitle'),
    statusText: AppLocalizations.of(context).translate('reconScanningStatus'),
    processingText: processingText,
    future: future,
    onResult: onResult,
    onError: onError,
    duration: duration,
  );
}

class CrystalBalanceSeal extends StatelessWidget {
  const CrystalBalanceSeal({super.key, this.size = 200});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: FittedBox(child: ReconSettleMark(size: size)),
  );
}

Future<ReconSuccessAction?> showCrystalSuccess(
  BuildContext context, {
  required ReconEqualizeKind kind,
  required VoidCallback onAgain,
  required VoidCallback onExit,
}) async {
  final l10n = AppLocalizations.of(context);
  final message = l10n.translate(switch (kind) {
    ReconEqualizeKind.bank => 'reconEqBank',
    ReconEqualizeKind.cash => 'reconEqCash',
    ReconEqualizeKind.product => 'reconEqProduct',
    ReconEqualizeKind.category => 'reconEqCategory',
    ReconEqualizeKind.store => 'reconEqStore',
  });
  final result = await showDialog<ReconSuccessAction>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The «balanced» settle mark (< 1 s, own soft cue).
            ReconSettleMark(message: message),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(ctx, ReconSuccessAction.again),
                  icon: const Icon(Icons.repeat_rounded, size: 18),
                  label: Text(
                    l10n.translate('reconAgain'),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, ReconSuccessAction.exit),
                  icon: const Icon(Icons.home_rounded, size: 18),
                  label: Text(
                    l10n.translate('reconExitHome'),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (result == ReconSuccessAction.again) onAgain();
  if (result == ReconSuccessAction.exit) onExit();
  return result;
}
