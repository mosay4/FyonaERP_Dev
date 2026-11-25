import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/warehouse_settings.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_scope_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_motion.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_scenes.dart';

/// Reconciliation motions: the matching scenes (financial / inventory) that
/// play after «بدء المطابقة», the
/// settle («balanced») mark and their sound assets.
void main() {
  const sceneKey = ValueKey('recon-opening-scene');

  Future<void> preload(WidgetTester tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
  }

  Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: child,
      );

  /// Opens the matching scene from a button and records its outcome.
  Widget launcher(
    Future<Object?> Function() future,
    void Function(ReconMatchOutcome<Object?>) done, {
    ReconOpenScene scene = ReconOpenScene.financial,
  }) => Builder(
    builder: (context) => TextButton(
      onPressed: () async => done(
        await runReconMatching<Object?>(
          context,
          scene: scene,
          future: future(),
        ),
      ),
      child: const Text('START'),
    ),
  );

  testWidgets('matching scene plays after start, then closes with the result '
      '(both scenes, both themes)', (tester) async {
    await preload(tester);
    for (final brightness in Brightness.values) {
      for (final scene in ReconOpenScene.values) {
        ReconMatchOutcome<Object?>? outcome;
        await tester.pumpWidget(
          host(
            launcher(() async => 'RESULT', (o) => outcome = o, scene: scene),
            brightness: brightness,
          ),
        );
        await tester.pump(); // localizations
        expect(find.byKey(sceneKey), findsNothing, reason: 'not before start');
        await tester.tap(find.text('START'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byKey(sceneKey), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(outcome, isNull, reason: 'results wait for the motion');
        await tester.pumpAndSettle();
        expect(find.byKey(sceneKey), findsNothing, reason: '$scene');
        expect(outcome?.ok, isTrue);
        expect(outcome?.result, 'RESULT');
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('scene is short (< 2 s) and holds while the check runs',
      (tester) async {
    await preload(tester);
    ReconMatchOutcome<Object?>? outcome;
    await tester.pumpWidget(
      host(launcher(() async => 1, (o) => outcome = o)),
    );
    await tester.pump();
    await tester.tap(find.text('START'));
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outcome?.result, 1, reason: 'results open within 1.8 s');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(sceneKey), findsNothing, reason: 'faded out');

    final pending = Completer<Object?>();
    outcome = null;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      host(launcher(() => pending.future, (o) => outcome = o)),
    );
    await tester.pump();
    await tester.tap(find.text('START'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byKey(sceneKey), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.byKey(sceneKey)));
    expect(find.text(l10n.translate('reconProcessing')), findsOneWidget);
    expect(outcome, isNull);
    pending.complete({'ref_code': 'RCN-X'});
    await tester.pumpAndSettle();
    expect(find.byKey(sceneKey), findsNothing);
    expect((outcome?.result as Map?)?['ref_code'], 'RCN-X');
  });

  testWidgets('a failed check closes the scene at once with the error',
      (tester) async {
    await preload(tester);
    ReconMatchOutcome<Object?>? outcome;
    final pending = Completer<Object?>();
    await tester.pumpWidget(
      host(launcher(() => pending.future, (o) => outcome = o)),
    );
    await tester.pump();
    await tester.tap(find.text('START'));
    await tester.pump(const Duration(milliseconds: 1400));
    pending.completeError(StateError('boom'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(sceneKey), findsNothing);
    expect(outcome?.ok, isFalse);
    expect(outcome?.error, isA<StateError>());
  });

  testWidgets('back during the motion leaves it', (tester) async {
    await preload(tester);
    ReconMatchOutcome<Object?>? outcome;
    await tester.pumpWidget(
      host(
        launcher(
          () => Completer<Object?>().future,
          (o) => outcome = o,
          scene: ReconOpenScene.inventory,
        ),
      ),
    );
    await tester.pump(); // localizations
    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(sceneKey), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    expect(find.byKey(sceneKey), findsNothing);
    expect(find.text('START'), findsOneWidget);
    expect(outcome?.left, isTrue);
  });

  testWidgets('reduced motion: still scene, closes when the check ends',
      (tester) async {
    await preload(tester);
    ReconMatchOutcome<Object?>? outcome;
    final pending = Completer<Object?>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: host(launcher(() => pending.future, (o) => outcome = o)),
      ),
    );
    await tester.pump(); // localizations
    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(sceneKey), findsOneWidget);
    pending.complete('R');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(sceneKey), findsNothing);
    expect(outcome?.result, 'R');
  });

  testWidgets('inventory scope page opens straight away (no motion before '
      'start)', (tester) async {
    await preload(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseSettingsProvider.overrideWith(
            (ref) =>
                WarehouseSettingsNotifier()
                  ..state = const WarehouseSettings(categories: true),
          ),
        ],
        child: host(const ReconInventoryScopePage()),
      ),
    );
    await tester.pump(); // localizations
    expect(find.byKey(sceneKey), findsNothing);
    expect(find.text('مطابقة منتج معين'), findsOneWidget);
  });

  testWidgets('settle mark completes in < 1 s and settles (both themes)',
      (tester) async {
    await preload(tester);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        host(
          const Scaffold(
            body: Center(child: ReconSettleMark(message: 'تمت مساواة البنك')),
          ),
          brightness: brightness,
        ),
      );
      await tester.pump(); // localizations; the mark starts here
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'no infinite animation (${brightness.name})');
      await tester.pumpAndSettle();
      expect(find.text('تمت مساواة البنك'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('settle dialog uses the new mark and returns the action',
      (tester) async {
    await preload(tester);
    ReconSuccessAction? action;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              action = await showCrystalSuccess(
                context,
                kind: ReconEqualizeKind.store,
                onAgain: () {},
                onExit: () {},
              );
            },
            child: const Text('SETTLE'),
          ),
        ),
      ),
    );
    await tester.pump(); // localizations
    await tester.tap(find.text('SETTLE'));
    await tester.pumpAndSettle();
    expect(find.byType(ReconSettleMark), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.text('SETTLE')));
    expect(find.text(l10n.translate('reconEqStore')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pumpAndSettle();
    expect(action, ReconSuccessAction.exit);
  });

  test('every motion sound exists, is registered, short and soft', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(reconMotionSoundAssets.toSet().length, 5);
    for (final asset in reconMotionSoundAssets) {
      final file = File('assets/$asset');
      expect(file.existsSync(), isTrue, reason: asset);
      expect(pubspec.contains('- assets/$asset'), isTrue, reason: asset);
      final bytes = file.readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      final rate = data.getUint32(24, Endian.little);
      final byteRate = data.getUint32(28, Endian.little);
      final seconds = (bytes.length - 44) / byteRate;
      expect(rate, 22050, reason: asset);
      expect(seconds, lessThan(1.2), reason: asset);
      var peak = 0;
      for (var i = 44; i + 1 < bytes.length; i += 2) {
        peak = peak < data.getInt16(i, Endian.little).abs()
            ? data.getInt16(i, Endian.little).abs()
            : peak;
      }
      expect(peak / 32767, lessThan(.5), reason: '$asset modest volume');
    }
  });
}

class _Probe extends StatefulWidget {
  const _Probe();
  static int mounts = 0;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.mounts++;
  }

  @override
  Widget build(BuildContext context) => const Text('PAGE');
}
