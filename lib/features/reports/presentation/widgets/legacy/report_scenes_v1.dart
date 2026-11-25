// FROZEN BACKUP (v1) of the report opening motions, as they were before the
// 2026-11 redesign. It renders the original isometric "financial cinema"
// scenes and their sounds (assets/audio/financial_*.ogg).
//
// To go back to these motions, set `kUseLegacyReportScenes = true` in
// ../report_scenes.dart. Nothing else needs to change.
import 'package:flutter/material.dart';

import '../report_scenes.dart' show ReportScene;
import 'financial_cinema_v1.dart';

V1FinancialScene _scene(ReportScene scene) => switch (scene) {
  ReportScene.sales => V1FinancialScene.sales,
  ReportScene.money => V1FinancialScene.treasury,
  ReportScene.inventory => V1FinancialScene.inventory,
  ReportScene.debts => V1FinancialScene.debts,
  ReportScene.overview => V1FinancialScene.executive,
  ReportScene.personal => V1FinancialScene.balance,
};

class ReportSceneOverlayV1 extends StatelessWidget {
  const ReportSceneOverlayV1({
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
  Widget build(BuildContext context) => V1FinancialOperationScene(
    scene: _scene(scene),
    title: sceneText,
    processingText: processingText,
    future: future,
    onResult: onResult,
    onError: onError,
    duration: duration,
  );
}

class ReportScenePainterV1 extends V1FinancialScenePainter {
  ReportScenePainterV1({
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
