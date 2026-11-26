import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/widgets/premium_switch_transition.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Cairo')
          ..addFont(rootBundle.load('assets/fonts/Cairo-400.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Cairo-700.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'operation runs under cover and reveals only after data is ready',
    (tester) async {
      var invoked = 0;
      final data = Completer<void>();
      await tester.pumpWidget(
        const MaterialApp(home: PremiumSwitchHost(child: Text('workspace'))),
      );
      final result = PremiumSwitch.run(
        kind: PremiumSwitchKind.branch,
        from: 'الصافية',
        to: 'الحصبة',
        arabic: true,
        action: () async {
          invoked++;
          await data.future;
        },
      );
      await tester.pump();
      expect(invoked, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(invoked, 1);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(PremiumSwitch.current.value, isNotNull);
      var duplicate = false;
      await PremiumSwitch.run(
        kind: PremiumSwitchKind.personal,
        from: 'A',
        to: 'B',
        arabic: false,
        action: () async {
          duplicate = true;
        },
      );
      expect(duplicate, isFalse);
      data.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      await result;
      expect(PremiumSwitch.current.value, isNull);
      expect(find.text('workspace'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'curtain stays closed until the destination arrived and its data is held',
    (tester) async {
      var arrived = false;
      final destinationData = Completer<void>();
      await tester.pumpWidget(
        const MaterialApp(home: PremiumSwitchHost(child: Text('old'))),
      );
      var done = false;
      final result = PremiumSwitch.run(
        kind: PremiumSwitchKind.business,
        from: 'Personal',
        to: 'Business',
        arabic: false,
        arrived: () => arrived,
        action: () async {
          // The destination registers its first load while the switch runs.
          PremiumSwitch.hold(destinationData.future);
        },
      ).then((_) => done = true);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 1500));
      // The action is over but the router has not reached the destination.
      expect(PremiumSwitch.current.value, isNotNull);
      expect(done, isFalse);
      arrived = true;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      // Arrived, but its data is still loading: still covered.
      expect(PremiumSwitch.current.value, isNotNull);
      destinationData.complete();
      await tester.pumpAndSettle();
      await result;
      expect(done, isTrue);
      expect(PremiumSwitch.current.value, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('failure dismisses overlay, propagates error and permits retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: PremiumSwitchHost(child: Text('original'))),
    );
    Object? failure;
    final result =
        PremiumSwitch.run(
          kind: PremiumSwitchKind.business,
          from: 'Personal',
          to: 'Business',
          arabic: false,
          action: () async {
            throw StateError('offline');
          },
        ).catchError((Object e) {
          failure = e;
        });
    await tester.pump();
    await tester.pumpAndSettle();
    await result;
    expect(failure, isA<StateError>());
    expect(PremiumSwitch.current.value, isNull);
    expect(find.text('original'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion finishes without the depth choreography', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const PremiumSwitchHost(child: Text('ready')),
        ),
      ),
    );
    final result = PremiumSwitch.run(
      kind: PremiumSwitchKind.personal,
      from: 'Business',
      to: 'Personal',
      arabic: false,
      action: () async {},
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await result;
    expect(PremiumSwitch.current.value, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AR/EN, light/dark, long branch names and compact screens fit', (
    tester,
  ) async {
    for (final size in [
      const Size(320, 568),
      const Size(568, 320),
      const Size(390, 844),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final dark in [false, true]) {
        for (final arabic in [false, true]) {
          for (final kind in PremiumSwitchKind.values) {
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? ThemeData.dark() : ThemeData.light(),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(1.4),
                  ),
                  child: PremiumSwitchScene(
                    session: PremiumSwitchSession(
                      kind: kind,
                      from: arabic
                          ? 'فرع الصافية للإدارة والخدمات المالية'
                          : 'Business administration and services',
                      to: arabic
                          ? 'فرع الحصبة الجديد للمبيعات والمخزون'
                          : 'New financial services branch',
                      arabic: arabic,
                    ),
                    progress: .65,
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: '$size / $dark / $arabic / $kind',
            );
          }
        }
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('route uses RTL source/target order in Arabic', (tester) async {
    for (final arabic in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: PremiumSwitchScene(
            session: PremiumSwitchSession(
              kind: PremiumSwitchKind.branch,
              from: arabic ? 'الحصبه' : 'Al Hasbah',
              to: arabic ? 'الصافيه' : 'Al Safiyah',
              arabic: arabic,
            ),
            progress: .65,
          ),
        ),
      );
      await tester.pump();
      final from = tester.getCenter(
        find.byKey(const ValueKey('switch-route-from')),
      );
      final to = tester.getCenter(
        find.byKey(const ValueKey('switch-route-to')),
      );
      final arrow = tester.getCenter(
        find.byKey(const ValueKey('switch-route-arrow')),
      );
      if (arabic) {
        expect(from.dx, greaterThan(arrow.dx));
        expect(to.dx, lessThan(arrow.dx));
        expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      } else {
        expect(from.dx, lessThan(arrow.dx));
        expect(to.dx, greaterThan(arrow.dx));
        expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('export representative painted frames for visual inspection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    for (final kind in PremiumSwitchKind.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: PremiumSwitchScene(
              session: PremiumSwitchSession(
                kind: kind,
                from: 'الصافية',
                to: kind == PremiumSwitchKind.branch
                    ? 'الحصبة'
                    : kind == PremiumSwitchKind.business
                    ? 'الأعمال'
                    : 'الشخصي',
                arabic: true,
              ),
              progress: .65,
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
        final dir = Directory('build/motion_previews');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/${kind.name}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
