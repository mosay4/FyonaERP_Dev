import 'package:flutter/material.dart';
import '../../../../shared/widgets/financial_cinema.dart';

enum ReportScene { sales, money, inventory, debts, overview }

FinancialScene _scene(ReportScene scene) => switch (scene) {
  ReportScene.sales => FinancialScene.sales,
  ReportScene.money => FinancialScene.treasury,
  ReportScene.inventory => FinancialScene.inventory,
  ReportScene.debts => FinancialScene.debts,
  ReportScene.overview => FinancialScene.executive,
};

class ReportSceneOverlay extends StatelessWidget {
  const ReportSceneOverlay({
    super.key,
    required this.scene,
    required this.sceneText,
    required this.processingText,
    required this.future,
    required this.onResult,
    required this.onError,
    this.duration = const Duration(milliseconds: 2800),
  });
  final ReportScene scene;
  final String sceneText, processingText;
  final Future<dynamic> future;
  final void Function(BuildContext, dynamic) onResult;
  final void Function(BuildContext, Object) onError;
  final Duration duration;

  @override
  Widget build(BuildContext context) => FinancialOperationScene(
    scene: _scene(scene),
    title: sceneText,
    processingText: processingText,
    future: future,
    onResult: onResult,
    onError: onError,
    duration: duration,
  );
}

class ReportScenePainter extends FinancialScenePainter {
  ReportScenePainter({
    required ReportScene scene,
    required double t,
    bool waiting = false,
    bool dark = true,
  }) : super(
         scene: _scene(scene),
         progress: t,
         dark: dark,
         confirmed: !waiting,
       );
}
