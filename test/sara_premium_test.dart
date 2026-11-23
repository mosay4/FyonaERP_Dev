import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_premium.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_sounds.dart';

void main() {
  test('one welcome per user across Personal, Business and persisted launches', () async {
    SharedPreferences.setMockInitialValues({'sara_first_encounter_previous': true});
    expect(await SaraWelcomeLedger.claim('previous'), isFalse);
    expect(await SaraWelcomeLedger.claim('new-premium-user'), isTrue);
    expect(await SaraWelcomeLedger.claim('new-premium-user'), isFalse);
    expect((await SharedPreferences.getInstance()).getBool('sara_first_encounter_new-premium-user'), isTrue);
    expect(await SaraWelcomeLedger.claim('guest'), isFalse);
  });

  testWidgets('all six original sound assets exist and contain real PCM wave data', (tester) async {
    final lengths = <int>{};
    for (final sound in SaraSound.values) {
      final bytes = await rootBundle.load('assets/audio/sara_${sound.name}.wav');
      expect(String.fromCharCodes(bytes.buffer.asUint8List(0, 4)), 'RIFF');
      expect(bytes.lengthInBytes, greaterThan(2000));
      expect(bytes.lengthInBytes, lessThan(60000));
      lengths.add(bytes.lengthInBytes);
    }
    expect(lengths.length, 6);
  });

  testWidgets('new reply reveals whole words, tap finishes once, old reply never replays', (tester) async {
    var starts = 0, completes = 0;
    const text = 'رصيد حساب الكاش مئة دولار أمريكي.\nالرصيد متاح في الفرع الحالي.';
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SaraWordReveal(text: text,
      style: const TextStyle(fontSize: 15), direction: TextDirection.rtl, animate: true,
      onStart: () => starts++, onComplete: () => completes++))));
    await tester.pump(const Duration(milliseconds: 60));
    expect(starts, 1);
    expect(find.text(text, findRichText: true), findsNothing);
    await tester.tap(find.byType(SaraWordReveal));
    await tester.pump();
    expect(find.text(text, findRichText: true), findsOneWidget);
    expect(completes, 1);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SaraWordReveal(key: ValueKey('old'),
      text: text, style: TextStyle(fontSize: 15), direction: TextDirection.rtl, animate: false))));
    expect(find.text(text, findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a long reply completes quickly without a per-word waiting penalty', (tester) async {
    var complete = false;
    final text = List.filled(900, 'تفصيل').join(' ');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SaraWordReveal(
      text: text, style: const TextStyle(fontSize: 12), direction: TextDirection.rtl, animate: true,
      onComplete: () => complete = true)))));
    await tester.pump(const Duration(milliseconds: 2200));
    expect(complete, isTrue);
    expect(find.text(text, findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('welcome moves the same portrait to the measured header rect and supports skip', (tester) async {
    final target = GlobalKey();
    var done = 0;
    await tester.pumpWidget(MaterialApp(home: Stack(children: [
      Positioned(left: 28, top: 24, child: SizedBox(key: target, width: 40, height: 40)),
      Positioned.fill(child: SaraFirstEncounter(targetKey: target, arabic: true, onComplete: () => done++)),
    ])));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(SaraPremiumAvatar), findsOneWidget);
    final start = tester.getRect(find.byType(SaraPremiumAvatar));
    expect(start.width, greaterThan(100));
    await tester.tap(find.byType(SaraFirstEncounter));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 190));
    await tester.pump();
    final end = tester.getRect(find.byType(SaraPremiumAvatar));
    expect(end.left, closeTo(tester.getRect(find.byKey(target)).left, 1));
    expect(end.top, closeTo(tester.getRect(find.byKey(target)).top, 1));
    expect(end.width, closeTo(40, 1));
    expect(done, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    for (final arabic in [false, true]) {
      testWidgets('header states stay readable: $brightness arabic=$arabic on narrow screen', (tester) async {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = const Size(340, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        for (final state in SaraVisualState.values) {
          await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: brightness), home: Scaffold(body:
            Directionality(textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
              child: SizedBox(width: 270, child: SaraIntelligentHeader(avatarKey: key, state: state,
                arabic: arabic, hidden: false, business: true, onBack: () {}))))));
          await tester.pump(const Duration(milliseconds: 240));
          expect(tester.takeException(), isNull);
          expect(find.byIcon(Icons.volume_off), findsNothing);
          expect(find.byIcon(Icons.volume_up), findsNothing);
          final back = find.byIcon(Icons.arrow_back_rounded);
          expect(back, findsOneWidget);
          expect(tester.getCenter(back).dx, lessThan(tester.getCenter(find.byType(SaraPremiumAvatar)).dx));
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('shared portrait stays aligned when the route scales during entry', (tester) async {
    final target = GlobalKey();
    final scale = ValueNotifier(.82);
    await tester.pumpWidget(MaterialApp(home: ValueListenableBuilder<double>(valueListenable: scale,
      builder: (context, factor, _) => Transform.scale(scale: factor, alignment: Alignment.topLeft,
        child: Stack(children: [
          Positioned(left: 28, top: 24, child: SizedBox(key: target, width: 40, height: 40)),
          Positioned.fill(child: SaraFirstEncounter(targetKey: target, arabic: true, onComplete: () {})),
        ])))));
    await tester.pump(const Duration(milliseconds: 400));
    scale.value = 1;
    await tester.pump();
    await tester.tap(find.byType(SaraFirstEncounter));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final actual = tester.getRect(find.byType(SaraPremiumAvatar));
    final expected = tester.getRect(find.byKey(target));
    expect(actual.left, closeTo(expected.left, 1));
    expect(actual.top, closeTo(expected.top, 1));
    await tester.pumpWidget(const SizedBox());
    scale.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets('render premium visual review ${dark ? 'dark' : 'light'}', (tester) async {
      final font = FontLoader('Cairo')..addFont(rootBundle.load('assets/fonts/Cairo-400.ttf'));
      await font.load();
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final avatar = GlobalKey();
      await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light,
        fontFamily: 'Cairo', colorSchemeSeed: const Color(0xFF9B1735)),
        home: RepaintBoundary(key: capture, child: Scaffold(body: Directionality(textDirection: TextDirection.rtl,
          child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
            const SizedBox(height: 22),
            SaraIntelligentHeader(avatarKey: avatar, state: SaraVisualState.thinking,
              arabic: true, hidden: false, business: dark),
            const SizedBox(height: 80),
            SaraPremiumAvatar(size: 150, state: SaraVisualState.thinking, business: dark),
            const SizedBox(height: 36),
            Card(child: Padding(padding: const EdgeInsets.all(20), child: SaraWordReveal(
              text: 'حساب الكاش\nالرصيد: ١٬٥٠٠ ريال سعودي\n\nجاهز أساعدك في الخطوة التالية.',
              style: TextStyle(fontFamily: 'Cairo', fontSize: 15, height: 1.8, color: dark ? Colors.white : Colors.black87),
              direction: TextDirection.rtl, animate: false))),
            const SizedBox(height: 24),
            SaraPressable(child: FilledButton(onPressed: () {}, child: const Text('مراجعة تفاصيل العملية'))),
          ])))))));
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await (capture.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/home/abdulrhman2/fyona-build-logs/sara-premium-${dark ? 'dark' : 'light'}.png').writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
}
