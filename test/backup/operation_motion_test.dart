// The restore/import motion follows the real work: percentage from the
// work, the completion mark only after it returned, a calm failure state.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/presentation/operation_motion.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<BuildContext> host(WidgetTester tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    AppLocalizations.setStaticLanguage('ar');
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold();
      }),
    ));
    await tester.pumpAndSettle();
    return ctx;
  }

  testWidgets('percentage from the work; the check only after it finished', (tester) async {
    final ctx = await host(tester);
    final gate = Completer<void>();
    late MotionController mc;
    final run = OperationMotion.run(ctx, kind: MotionKind.cloudRestore, doneText: 'تمت', work: (m) async {
      mc = m;
      m.stage('التحقق من السجلات', 0.5);
      await gate.future;
      return 42;
    });
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(find.text('التحقق من السجلات'), findsOneWidget);
    expect(find.textContaining('%'), findsOneWidget);
    expect(find.byKey(const Key('motion-close')), findsNothing); // not done yet
    final shown = int.parse(RegExp(r'(\d+)%').firstMatch(
        tester.widgetList<Text>(find.textContaining('%')).first.data!)!.group(1)!);
    expect(shown, inInclusiveRange(30, 50)); // follows the work, never ahead
    mc.progress(0.9);
    gate.complete();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('تمت'), findsOneWidget);
    await tester.tap(find.byKey(const Key('motion-close')));
    await tester.pumpAndSettle();
    expect(await run, 42);
  });

  testWidgets('a failure shows why, nothing claims success, and the error reaches the caller', (tester) async {
    final ctx = await host(tester);
    Object? caught;
    final run = OperationMotion.run<void>(ctx,
        kind: MotionKind.deviceRestore,
        failureText: (e) => 'المساحة غير كافية',
        work: (m) async {
          m.stage('قراءة الملف', 0.2);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          throw StateError('disk full');
        }).catchError((Object e) => caught = e);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('المساحة غير كافية'), findsOneWidget);
    expect(find.text(AppLocalizations.t('motionDone')), findsNothing);
    await tester.tap(find.byKey(const Key('motion-mute')));
    await tester.pump();
    expect((await SharedPreferences.getInstance()).getBool('operation_motion_muted'), isTrue);
    await tester.tap(find.byKey(const Key('motion-close')));
    await tester.pumpAndSettle();
    await run;
    expect(caught, isA<StateError>());
  });
}
