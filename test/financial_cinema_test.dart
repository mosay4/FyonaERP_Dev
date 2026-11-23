import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/widgets/financial_cinema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Cairo')
          ..addFont(rootBundle.load('assets/fonts/Cairo-400.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Cairo-700.ttf')))
        .load();
  });

  testWidgets('seven original sound assets really exist and are distinct', (
    tester,
  ) async {
    final fingerprints = <int>{};
    for (final scene in FinancialScene.values) {
      final bytes = await rootBundle.load(
        'assets/audio/financial_${scene.name}.ogg',
      );
      expect(bytes.lengthInBytes, greaterThan(8000));
      final data = bytes.buffer.asUint8List();
      expect(String.fromCharCodes(data.take(4)), 'OggS');
      fingerprints.add(Object.hashAll(data));
    }
    expect(fingerprints.length, 7);
  });

  testWidgets('late operation cannot show results before backend completion', (
    tester,
  ) async {
    final pending = Completer<dynamic>();
    var results = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FinancialOperationScene(
          scene: FinancialScene.precision,
          title: 'جاري المطابقة',
          processingText: 'بانتظار البيانات الفعلية',
          future: pending.future,
          onResult: (_, result) {
            expect(result['id'], 'real');
            results++;
          },
          onError: (_, error) => fail('$error'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(results, 0);
    expect(find.text('بانتظار البيانات الفعلية'), findsOneWidget);
    pending.complete({'id': 'real'});
    await tester.pump();
    await tester.pumpAndSettle();
    expect(results, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(results, 1);
  });

  testWidgets(
    'failure never invokes success; stale retry results are discarded',
    (tester) async {
      final old = Completer<dynamic>();
      final fresh = Completer<dynamic>();
      final results = <String>[];
      Object? failure;
      Widget page(Future<dynamic> future) => MaterialApp(
        home: FinancialOperationScene(
          scene: FinancialScene.sales,
          title: 'sales',
          processingText: 'wait',
          future: future,
          onResult: (_, result) => results.add('$result'),
          onError: (_, error) => failure = error,
        ),
      );
      await tester.pumpWidget(page(old.future));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(page(fresh.future));
      old.complete('old');
      fresh.completeError(StateError('documented rate missing'));
      await tester.pump();
      await tester.pump();
      expect(results, isEmpty);
      expect(failure, isA<StateError>());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all seven scenes fit dark/light compact and landscape layouts', (
    tester,
  ) async {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final dark in [true, false]) {
        for (final ar in [true, false]) {
          for (final scene in FinancialScene.values) {
            final future = Completer<dynamic>();
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? ThemeData.dark() : ThemeData.light(),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: Directionality(
                    textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
                    child: FinancialOperationScene(
                      key: ValueKey('$size-$dark-$scene-$ar'),
                      scene: scene,
                      title: ar
                          ? 'محرك التحليل والمطابقة المالية الدقيقة'
                          : 'Precision financial intelligence and reconciliation',
                      processingText: 'البيانات قيد التحليل',
                      future: future.future,
                      onResult: (_, __) {},
                      onError: (_, __) {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 1600));
            expect(
              tester.takeException(),
              isNull,
              reason: '$size/$dark/$scene/$ar',
            );
          }
        }
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('export real Flutter geometry frames for visual inspection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 400);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    final fingerprints = <int>{};
    for (final scene in FinancialScene.values) {
      for (final dark in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: dark ? const Color(0xFF101013) : const Color(0xFFF0F2F4),
                child: CustomPaint(
                  painter: FinancialScenePainter(
                    scene: scene,
                    progress: .62,
                    dark: dark,
                    confirmed: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final data = bytes!.buffer.asUint8List();
          fingerprints.add(Object.hashAll(data));
          final dir = Directory('build/financial_previews');
          await dir.create(recursive: true);
          await File(
            '${dir.path}/${scene.name}_${dark ? 'dark' : 'light'}.png',
          ).writeAsBytes(data);
          image.dispose();
        });
      }
    }
    expect(fingerprints.length, 14);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets(
    'Perfect Balance reveals its typography after the verified seal',
    (tester) async {
      tester.view.physicalSize = const Size(390, 420);
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: const ColoredBox(
                  color: Color(0xFFF0F2F4),
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: FinancialSuccessScene(message: 'تمت مساواة الكاش'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('تمت مساواة الكاش'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build/financial_previews');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/perfect_balance.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
