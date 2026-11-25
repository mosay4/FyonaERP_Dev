import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/reports/presentation/widgets/legacy/report_scenes_v1.dart';
import 'package:fyona_flutter/features/reports/presentation/widgets/report_scenes.dart';

/// Report opening gate v2: synced sound cues, the v1 backup, reduced motion.
void main() {
  test('every cue is a small registered asset, in timeline order, and the '
      'settle chime sits on the hold point', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final scene in ReportScene.values) {
      final cues = reportSceneCues(scene);
      expect(cues.length, greaterThanOrEqualTo(3), reason: '$scene');
      for (var i = 0; i < cues.length; i++) {
        final file = File('assets/${cues[i].asset}');
        expect(file.existsSync(), isTrue, reason: cues[i].asset);
        expect(file.lengthSync(), lessThan(80 * 1024), reason: cues[i].asset);
        expect(pubspec, contains('- assets/${cues[i].asset}'));
        expect(cues[i].at, inInclusiveRange(0, 1));
        if (i > 0) expect(cues[i].at, greaterThan(cues[i - 1].at));
      }
      expect(cues.last.at, kReportSceneHold, reason: '$scene settle cue');
    }
    expect(kUseLegacyReportScenes, isFalse);
  });

  Widget host(Widget child, {bool reduced = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: child,
    ),
  );

  testWidgets('reduced motion skips to the final frame and still delivers', (
    tester,
  ) async {
    dynamic revealed;
    await tester.pumpWidget(
      host(
        ReportSceneOverlay(
          scene: ReportScene.inventory,
          sceneText: 'x',
          processingText: 'y',
          future: Future.value({'ok': true}),
          onResult: (_, r) => revealed = r,
          onError: (_, e) {},
        ),
        reduced: true,
      ),
    );
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<ReportScenePainter>()
        .single;
    expect(painter.t, 1);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(revealed, isNotNull);
  });

  testWidgets('the v1 backup motions still render and complete', (
    tester,
  ) async {
    for (final scene in ReportScene.values) {
      dynamic revealed;
      await tester.pumpWidget(
        host(
          ReportSceneOverlayV1(
            scene: scene,
            sceneText: 'x',
            processingText: 'y',
            future: Future.value({'ok': true}),
            onResult: (_, r) => revealed = r,
            onError: (_, e) {},
          ),
        ),
      );
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(revealed, isNotNull, reason: 'v1 $scene');
    }
  });

  testWidgets('a failing report surfaces the error instead of the scene', (
    tester,
  ) async {
    Object? error;
    await tester.pumpWidget(
      host(
        ReportSceneOverlay(
          scene: ReportScene.debts,
          sceneText: 'x',
          processingText: 'y',
          future: Future<dynamic>(() => throw StateError('offline')),
          onResult: (_, r) => fail('must not reveal'),
          onError: (_, e) => error = e,
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(error, isA<StateError>());
  });
}
