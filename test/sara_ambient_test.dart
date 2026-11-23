import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_ambient_controller.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_ambient_scene.dart';

void advance(SaraAmbientController controller, int milliseconds) {
  for (var i = 0; i < milliseconds; i += 10) {
    controller.advance(Duration(milliseconds: (milliseconds - i).clamp(0, 10)));
  }
}

void resumeApp(WidgetTester tester) {
  final binding = tester.binding;
  if (binding.lifecycleState == AppLifecycleState.paused) binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  if (binding.lifecycleState == AppLifecycleState.hidden) binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  if (binding.lifecycleState == AppLifecycleState.inactive || binding.lifecycleState == AppLifecycleState.detached) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

void main() {
  test('focus, continuous edits, deletion, empty and 500ms quiet settle', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    expect(c.phase, SaraAmbientPhase.idle);
    c.focus(true);
    advance(c, 250);
    expect(c.phase, SaraAmbientPhase.focus);
    expect(c.focusGlow, greaterThan(.95));
    c.edit('م'); advance(c, 40);
    c.edit('مر'); advance(c, 40);
    c.edit('مرحبا'); advance(c, 40);
    expect(c.phase, SaraAmbientPhase.typing);
    expect(c.typingEnergy, greaterThan(.1));
    c.edit('مرح'); advance(c, 80);
    expect(c.contraction, lessThan(0));
    advance(c, 500);
    expect(c.phase, SaraAmbientPhase.focus);
    expect(c.typingEnergy, closeTo(0, .001));
    c.edit('');
    expect(c.phase, SaraAmbientPhase.focus);
    c.focus(false); advance(c, 250);
    expect(c.phase, SaraAmbientPhase.idle);
    expect(c.focusGlow, lessThan(.05));
  });

  test('sending, pending request, thinking, real words and completed are distinct', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.send();
    c.setActivity(SaraAmbientActivity.thinking);
    expect(c.phase, SaraAmbientPhase.sending);
    advance(c, 440);
    expect(c.phase, SaraAmbientPhase.waiting);
    advance(c, 260);
    expect(c.phase, SaraAmbientPhase.thinking);
    c.responseReady(c.generation);
    c.setActivity(SaraAmbientActivity.thinking);
    expect(c.phase, SaraAmbientPhase.waiting);
    c.registerReply('reply');
    c.replyStarted('reply');
    c.setActivity(SaraAmbientActivity.responding);
    expect(c.phase, SaraAmbientPhase.responding);
    for (var i = 0; i < 8; i++) { c.word('reply'); advance(c, 30); }
    expect(c.wordEnergy, greaterThan(.4));
    c.replyFinished('reply');
    expect(c.phase, SaraAmbientPhase.completed);
    expect(c.operationActive, isFalse);
    advance(c, 510);
    expect(c.phase, SaraAmbientPhase.idle);
  });

  test('a fast response interrupts sending immediately instead of fake waiting', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.send(); advance(c, 30);
    c.registerReply('fast'); c.replyStarted('fast');
    expect(c.phase, SaraAmbientPhase.responding);
    expect(c.sendProgress, lessThan(1));
  });

  test('only confirmed operations produce success, not reads or queued writes', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.send(); c.setActivity(SaraAmbientActivity.thinking); advance(c, 700);
    c.finishOperation(confirmed: true);
    expect(c.phase, isNot(SaraAmbientPhase.success));
    c.beginOperation();
    expect(c.phase, SaraAmbientPhase.executing);
    c.finishOperation(confirmed: false);
    expect(c.phase, isNot(SaraAmbientPhase.success));
    c.beginOperation(); c.finishOperation(confirmed: true);
    expect(c.phase, SaraAmbientPhase.success);
    advance(c, 510);
    expect(c.phase, SaraAmbientPhase.idle);
    c.beginOperation(); c.finishOperation(confirmed: false, failed: true);
    expect(c.phase, SaraAmbientPhase.error);
    c.registerReply('error-text'); c.replyStarted('error-text'); c.replyFinished('error-text');
    expect(c.phase, SaraAmbientPhase.error);
    advance(c, 310);
    expect(c.phase, SaraAmbientPhase.idle);
  });

  test('cancel and retry retire every old reply and result generation', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.send(); c.registerReply('old'); c.replyStarted('old');
    final oldGeneration = c.generation;
    c.cancel();
    expect(c.phase, SaraAmbientPhase.cancelling);
    c.word('old'); c.replyFinished('old'); c.finishOperation(confirmed: true);
    expect(c.phase, SaraAmbientPhase.cancelling);
    advance(c, 260);
    expect(c.phase, SaraAmbientPhase.idle);
    c.send();
    expect(c.generation, greaterThan(oldGeneration));
    c.replyStarted('old'); c.replyFinished('old');
    expect(c.phase, SaraAmbientPhase.sending);
  });

  test('late requests and old operation tokens cannot complete a newer operation', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.send();
    final oldGeneration = c.generation;
    final oldOperation = c.beginOperation();
    c.cancel(); c.send();
    final newOperation = c.beginOperation();
    expect(c.registerReply('late', generation: oldGeneration), isFalse);
    c.error(generation: oldGeneration);
    c.finishOperation(confirmed: true, token: oldOperation);
    expect(c.phase, SaraAmbientPhase.executing);
    expect(c.operationActive, isTrue);
    c.finishOperation(confirmed: true, token: newOperation);
    expect(c.phase, SaraAmbientPhase.success);
  });

  test('a phase interrupted mid-morph preserves its current mixture', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.focus(true); advance(c, 80);
    c.edit('سارة'); advance(c, 60);
    c.send(); advance(c, 50);
    final before = c.phaseWeights;
    c.registerReply('fast'); c.replyStarted('fast');
    final after = c.phaseWeights;
    for (final phase in SaraAmbientPhase.values) {
      expect(after[phase] ?? 0, closeTo(before[phase] ?? 0, .0001));
    }
    expect(after.values.reduce((a, b) => a + b), closeTo(1, .0001));
  });

  test('suggestion feedback is a bounded touch cue, not a fake request or result', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.suggestion(const Offset(160, 600));
    expect(c.touchOrigin, const Offset(160, 600));
    expect(c.hasRequest, isFalse);
    expect(c.phase, SaraAmbientPhase.idle);
    advance(c, 200);
    expect(c.touchProgress, greaterThan(0));
    expect(c.touchProgress, lessThan(1));
    c.cancel();
    expect(c.touchProgress, 1);
  });

  test('old messages, section instances and off-page callbacks cannot start waves', () {
    final personal = SaraAmbientController(), business = SaraAmbientController();
    addTearDown(personal.dispose); addTearDown(business.dispose);
    personal.replyStarted('history'); personal.word('history'); personal.replyFinished('history');
    expect(personal.phase, SaraAmbientPhase.idle);
    personal.send(); personal.beginOperation(); personal.setVisible(false);
    personal.finishOperation(confirmed: true);
    expect(personal.phase, SaraAmbientPhase.hidden);
    expect(personal.phaseWeights, {SaraAmbientPhase.hidden: 1});
    expect(business.phase, SaraAmbientPhase.idle);
    personal.setVisible(true);
    expect(personal.registerReply('late-after-return'), isFalse);
    personal.setActivity(SaraAmbientActivity.responding);
    expect(personal.phase, SaraAmbientPhase.idle);
    expect(personal.phaseWeights.containsKey(SaraAmbientPhase.executing), isFalse);
  });

  test('scroll-cached replies cannot replay later or finish with an offscreen pulse', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.send(); c.registerReply('cached'); advance(c, 3500);
    c.replyStarted('cached');
    expect(c.phase, isNot(SaraAmbientPhase.responding));
    c.send(); c.registerReply('offscreen');
    c.replyStarted('offscreen', visible: false); advance(c, 500);
    c.replyStarted('offscreen');
    expect(c.phase, isNot(SaraAmbientPhase.responding));
    c.registerReply('visible'); c.replyStarted('visible');
    c.replyFinished('visible', visible: false);
    expect(c.phase, isNot(SaraAmbientPhase.completed));
  });

  test('geometry morphs and reduced motion freezes clocks and pulse geometry', () {
    final c = SaraAmbientController();
    addTearDown(c.dispose);
    c.setGeometry(const SaraAmbientGeometry(input: Rect.fromLTWH(40, 600, 230, 44)));
    expect(c.geometry.input, const Rect.fromLTWH(40, 600, 230, 44));
    advance(c, 260);
    c.setGeometry(const SaraAmbientGeometry(input: Rect.fromLTWH(40, 300, 230, 44)));
    advance(c, 100);
    expect(c.geometry.input!.top, inExclusiveRange(300, 600));
    advance(c, 160);
    expect(c.geometry.input!.top, 300);
    c.setReducedMotion(true);
    c.focus(true); c.edit('مرحبا'); c.send(); c.advance(const Duration(seconds: 5));
    expect(c.canAnimate, isFalse);
    expect(c.typingEnergy, 0);
    expect(c.wordEnergy, 0);
    expect(c.sendProgress, 1);
  });

  testWidgets('actual focus and keyboard edits work through both visual layers', (tester) async {
    final c = SaraAmbientController();
    await tester.pumpWidget(_Harness(controller: c));
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 260));
    expect(c.phase, SaraAmbientPhase.focus);
    await tester.enterText(find.byType(TextField), 'مرحبا سارة');
    await tester.pump(const Duration(milliseconds: 50));
    expect(c.phase, SaraAmbientPhase.typing);
    await tester.enterText(find.byType(TextField), 'مرحبا');
    await tester.pump(const Duration(milliseconds: 100));
    expect(c.contraction, lessThan(0));
    await tester.tap(find.text('Send'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(c.phase, SaraAmbientPhase.sending);
    expect(find.text('Message sent'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('reduced motion and app pause produce no ambient animation frames', (tester) async {
    addTearDown(() => resumeApp(tester));
    final c = SaraAmbientController();
    await tester.pumpWidget(_Harness(controller: c, reduced: true));
    final before = c.paintCount;
    await tester.pump(const Duration(seconds: 2));
    expect(c.paintCount, before);
    await tester.pumpWidget(_Harness(controller: c));
    await tester.pump(const Duration(milliseconds: 50));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final paused = c.paintCount;
    await tester.pump(const Duration(seconds: 2));
    expect(c.paintCount, paused);
    expect(c.visible, isFalse);
    resumeApp(tester);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('covered route fades, stops and does not replay the previous request', (tester) async {
    final c = SaraAmbientController();
    await tester.pumpWidget(_Harness(controller: c));
    await tester.tap(find.text('Send'));
    await tester.pump(const Duration(milliseconds: 700));
    final state = tester.state<_HarnessState>(find.byType(_Harness));
    unawaited(state.nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Another page')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 650));
    final covered = c.paintCount;
    await tester.pump(const Duration(seconds: 1));
    expect(c.paintCount, covered);
    expect(c.visible, isFalse);
    state.nav.currentState!.pop();
    await tester.pump(); await tester.pump(const Duration(milliseconds: 650));
    expect(c.phase, SaraAmbientPhase.idle);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  for (final dark in [false, true]) {
    for (final rtl in [false, true]) {
      testWidgets('narrow layout and keyboard redistribution dark=$dark rtl=$rtl', (tester) async {
        tester.view.physicalSize = const Size(340, 700); tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final c = SaraAmbientController();
        await tester.pumpWidget(_Harness(controller: c, dark: dark, rtl: rtl));
        await tester.pump(const Duration(milliseconds: 260));
        final old = c.geometry.input!.top;
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pump(); await tester.pump(const Duration(milliseconds: 300));
        expect(c.geometry.input!.top, lessThan(old));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      });
    }
  }
}

class _Harness extends StatefulWidget {
  const _Harness({required this.controller, this.dark = false, this.rtl = true, this.reduced = false});
  final SaraAmbientController controller;
  final bool dark, rtl, reduced;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final nav = GlobalKey<NavigatorState>();
  final input = GlobalKey(), avatar = GlobalKey(), user = GlobalKey(), reply = GlobalKey();
  final focus = FocusNode();
  final text = TextEditingController();
  var activity = SaraAmbientActivity.none;
  var sent = false;
  @override
  void initState() { super.initState(); focus.addListener(() => widget.controller.focus(focus.hasFocus)); }
  @override
  void dispose() { focus.dispose(); text.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => MaterialApp(navigatorKey: nav,
    theme: ThemeData(brightness: widget.dark ? Brightness.dark : Brightness.light, colorSchemeSeed: const Color(0xFF9B1735)),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: widget.reduced), child: child!),
    home: Directionality(textDirection: widget.rtl ? TextDirection.rtl : TextDirection.ltr, child: Scaffold(
      appBar: AppBar(title: SizedBox(key: avatar, width: 40, height: 40, child: const Icon(Icons.person))),
      body: Stack(children: [
        Positioned.fill(child: SaraAmbientScene(controller: widget.controller, activity: activity,
          inputKey: input, avatarKey: avatar, userKey: user, replyKey: reply)),
        Column(children: [
          Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [
            Align(alignment: AlignmentDirectional.centerEnd, child: Card(key: user, child: const Padding(
              padding: EdgeInsets.all(18), child: Text('User message')))),
            Align(alignment: AlignmentDirectional.centerStart, child: Card(key: reply, child: const Padding(
              padding: EdgeInsets.all(18), child: Text('Sara reply')))),
            if (sent) const Text('Message sent'),
          ])),
          Padding(padding: const EdgeInsets.all(14), child: TextField(key: input, controller: text,
            focusNode: focus, onTap: widget.controller.touchInput, onChanged: widget.controller.edit,
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Write…'))),
          TextButton(onPressed: () {
            widget.controller.send(); text.clear();
            setState(() { sent = true; activity = SaraAmbientActivity.thinking; });
          }, child: const Text('Send')),
        ]),
        Positioned.fill(child: SaraAmbientAccents(controller: widget.controller)),
      ]),
    )),
  );
}
