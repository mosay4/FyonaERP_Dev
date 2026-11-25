import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_ambient_controller.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_ambient_scene.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Sara background loads and paints a calm, quiet gradient', (
    tester,
  ) async {
    expect(File('assets/shaders/sara_fluid.frag').existsSync(), isTrue);
    expect(File(SaraFluidProgram.asset).lengthSync(), greaterThan(1024));
    final bytes = await rootBundle.load(SaraFluidProgram.asset);
    expect(bytes.lengthInBytes, greaterThan(1024));
    // The compiled container includes SkSL, so the software test engine can
    // load AND execute it. Native Impeller device performance is a separate gate.
    final program = await tester.runAsync(SaraFluidProgram.load);
    expect(program, isNotNull);
    final shader = program!.fragmentShader();
    final c = SaraAmbientController();
    await tester.runAsync(() async {
      for (final dark in [false, true]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        SaraAmbientPainter(
          controller: c,
          primary: Colors.red,
          ink: Colors.black,
          dark: dark,
          shader: shader,
        ).paint(canvas, const Size(120, 240));
        final picture = recorder.endRecording();
        final image = await picture.toImage(120, 240);
        final raw = (await image.toByteData())!;
        int at(int x, int y, int ch) => raw.getUint8((y * 120 + x) * 4 + ch);
        // Calm design (owner's request): an opaque, quiet gradient in the
        // theme's own tones — a faint warm tint near the header fading into
        // the plain page tone; no bright swirls anywhere.
        for (final x in [20, 60, 100]) {
          expect(at(x, 228, 3), 255, reason: 'opaque bottom x=$x');
          final top = at(x, 2, 0) - at(x, 2, 2); // red minus blue (warmth)
          final bottom = at(x, 228, 0) - at(x, 228, 2);
          expect(top, greaterThanOrEqualTo(bottom), reason: 'tint fades x=$x');
          expect(top.abs(), lessThan(40), reason: 'quiet colour x=$x');
        }
        image.dispose();
        picture.dispose();
      }
    });
    shader.dispose();
    c.dispose();
  });

  test('send impulse decays monotonically for two seconds across phases', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.send();
    expect(c.sendImpulse, 1);
    c.setActivity(SaraAmbientActivity.thinking);
    var last = c.sendImpulse;
    for (var i = 0; i < 20; i++) {
      c.advance(const Duration(milliseconds: 100));
      expect(c.sendImpulse, lessThanOrEqualTo(last));
      last = c.sendImpulse;
    }
    expect(c.sendImpulse, closeTo(0, 1e-10));
    expect(c.fluidSendProgress, 1);
  });

  test(
    'time and integrated flow never reset; reduced motion freezes clocks',
    () {
      final c = SaraAmbientController();
      addTearDown(c.dispose);
      c.advance(const Duration(seconds: 2));
      for (final change in <void Function()>[
        () => c.edit('Sara'),
        c.send,
        () => c.setActivity(SaraAmbientActivity.thinking),
        () {
          c.registerReply('r');
          c.replyStarted('r');
        },
        () => c.replyFinished('r'),
      ]) {
        final time = c.time, flow = c.fluidFlow;
        change();
        expect(c.time, time);
        expect(c.fluidFlow, flow);
        c.advance(const Duration(milliseconds: 100));
        expect(c.time, greaterThan(time));
        expect(c.fluidFlow, greaterThan(flow));
      }
      c.setReducedMotion(true);
      final frozen = c.time, flow = c.fluidFlow;
      c.advance(const Duration(seconds: 20));
      expect(c.time, frozen);
      expect(c.fluidFlow, flow);
      c.setReducedMotion(false);
      c.advance(const Duration(milliseconds: 16));
      expect(c.time, closeTo(frozen + .016, 1e-10));
    },
  );

  test('reveal swell is deterministic from actual word progress', () {
    final a = SaraAmbientController(), b = SaraAmbientController();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    for (final c in [a, b]) {
      c.send();
      c.registerReply('r');
      c.replyStarted('r');
    }
    expect(a.revealPulse, 0);
    for (var i = 0; i < 10; i++) {
      a.word('r');
      b.word('r');
      expect(a.revealPulse, b.revealPulse);
      expect(a.revealPulse, inInclusiveRange(0, 1));
      final pulse = a.revealPulse;
      a.advance(const Duration(milliseconds: 50));
      b.advance(const Duration(milliseconds: 50));
      expect(a.revealPulse, lessThan(pulse));
      expect(a.revealPulse, b.revealPulse);
    }
  });

  for (final dark in [false, true]) {
    testWidgets(
      'scene schedules real shader in theme dark=$dark and pauses smoothly',
      (tester) async {
        final c = SaraAmbientController();
        final sceneKey = GlobalKey();
        final input = GlobalKey(),
            avatar = GlobalKey(),
            user = GlobalKey(),
            reply = GlobalKey();
        Widget app({
          bool reduced = false,
          bool enabled = true,
          bool ticker = true,
        }) => MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: TickerMode(
              enabled: ticker,
              child: SizedBox.expand(
                child: SaraAmbientScene(
                  key: sceneKey,
                  controller: c,
                  activity: SaraAmbientActivity.none,
                  inputKey: input,
                  avatarKey: avatar,
                  userKey: user,
                  replyKey: reply,
                  enabled: enabled,
                  business: dark,
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(app());
        await tester.runAsync(SaraFluidProgram.load);
        await tester.pump();
        final paints = tester.widgetList<CustomPaint>(
          find.descendant(
            of: find.byKey(sceneKey),
            matching: find.byType(CustomPaint),
          ),
        );
        expect(paints.single.painter, isA<SaraAmbientPainter>());
        expect(
          (paints.single.painter! as SaraAmbientPainter).shader,
          isNotNull,
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(c.time, greaterThan(0));
        await tester.pumpWidget(app(reduced: true));
        final time = c.time, count = c.paintCount;
        await tester.pump(const Duration(seconds: 10));
        expect(c.time, time);
        expect(c.paintCount, count);
        await tester.pumpWidget(app());
        await tester.pump(const Duration(milliseconds: 16));
        expect(c.time, closeTo(time + .016, .001));
        for (final variant in [app(enabled: false), app(ticker: false)]) {
          await tester.pumpWidget(variant);
          final paused = c.time;
          await tester.pump(const Duration(seconds: 5));
          expect(c.time, paused);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }

  testWidgets('idle aurora settles and stops scheduling frames; events wake it', (tester) async {
    final c = SaraAmbientController();
    final keys = List.generate(4, (_) => GlobalKey());
    await tester.pumpWidget(MaterialApp(home: SizedBox.expand(child: SaraAmbientScene(
      controller: c, activity: SaraAmbientActivity.none,
      inputKey: keys[0], avatarKey: keys[1], userKey: keys[2], replyKey: keys[3]))));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.time, greaterThan(0)); // entrance bloom
    // Idle: finite — pumpAndSettle returns, the clock stops.
    await tester.pumpAndSettle();
    final rested = c.time;
    await tester.pump(const Duration(seconds: 5));
    expect(c.time, rested);
    // Typing wakes it, then it settles again.
    c.edit('سارة');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.time, greaterThan(rested));
    await tester.pumpAndSettle();
    final again = c.time;
    await tester.pump(const Duration(seconds: 3));
    expect(c.time, again);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
