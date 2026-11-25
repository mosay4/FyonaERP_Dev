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

/// Reconciliation motions: the opening scenes (financial / inventory), the
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

  testWidgets('opening scene plays, then reveals the SAME page state '
      '(both scenes, both themes)', (tester) async {
    await preload(tester);
    for (final brightness in Brightness.values) {
      for (final scene in ReconOpenScene.values) {
        _Probe.mounts = 0;
        await tester.pumpWidget(
          host(
            ReconOpeningGate(scene: scene, child: const _Probe()),
            brightness: brightness,
          ),
        );
        await tester.pump(); // localizations
        expect(find.byKey(sceneKey), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byKey(sceneKey), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(find.byKey(sceneKey), findsNothing, reason: '$scene');
        expect(find.text('PAGE'), findsOneWidget);
        expect(_Probe.mounts, 1, reason: 'page must not remount on reveal');
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('scene is short (< 2 s total) and holds while not ready',
      (tester) async {
    await preload(tester);
    Widget gate(bool ready) => host(
      ReconOpeningGate(
        scene: ReconOpenScene.financial,
        ready: ready,
        child: const Text('PAGE'),
      ),
    );
    await tester.pumpWidget(gate(true));
    await tester.pump(); // localizations
    expect(find.byKey(sceneKey), findsOneWidget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(sceneKey), findsNothing, reason: 'gone within 2 s');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(gate(false));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byKey(sceneKey), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.byKey(sceneKey)));
    expect(find.text(l10n.translate('reconProcessing')), findsOneWidget);
    await tester.pumpWidget(gate(true));
    await tester.pumpAndSettle();
    expect(find.byKey(sceneKey), findsNothing);
    expect(find.text('PAGE'), findsOneWidget);
  });

  testWidgets('back during the motion leaves the page', (tester) async {
    await preload(tester);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ReconOpeningGate(
                  scene: ReconOpenScene.inventory,
                  child: Text('PAGE'),
                ),
              ),
            ),
            child: const Text('OPEN'),
          ),
        ),
      ),
    );
    await tester.pump(); // localizations
    await tester.tap(find.text('OPEN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(sceneKey), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    expect(find.byKey(sceneKey), findsNothing);
    expect(find.text('PAGE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);
  });

  testWidgets('reduced motion: the page shows at once', (tester) async {
    await preload(tester);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: host(
          const ReconOpeningGate(
            scene: ReconOpenScene.financial,
            child: Text('PAGE'),
          ),
        ),
      ),
    );
    await tester.pump(); // localizations
    expect(find.byKey(sceneKey), findsNothing);
    expect(find.text('PAGE'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(sceneKey), findsNothing);
  });

  testWidgets('inventory scope page opens through its scene', (tester) async {
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
    expect(find.byKey(sceneKey), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.byKey(sceneKey)));
    expect(find.text(l10n.translate('reconOpenInvLine')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(sceneKey), findsNothing);
    expect(find.text(l10n.translate('reconInvProduct')), findsOneWidget);
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
