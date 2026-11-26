import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/printing/data/print_engine.dart';
import 'package:fyona_flutter/features/printing/data/print_service.dart';
import 'package:fyona_flutter/features/printing/data/printer_discovery.dart';
import 'package:fyona_flutter/features/printing/data/printer_store.dart';
import 'package:fyona_flutter/features/printing/domain/printer_models.dart';
import 'package:fyona_flutter/features/printing/presentation/pages/print_page.dart';
import 'package:fyona_flutter/features/printing/presentation/providers/printing_providers.dart';
import 'package:fyona_flutter/features/printing/presentation/widgets/printer_scene.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_printers.dart';

Future<List<RasterPage>> _raster(Uint8List pdf, double dpi) async {
  const w = 576, h = 120;
  final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  return [(rgba: rgba, width: w, height: h)];
}

class _QuietDiscovery extends PrinterDiscovery {
  _QuietDiscovery() : super(sweep: false);
  @override
  Stream<PrinterDevice> discover() => const Stream.empty();
}

void main() {
  late FakeEscPosPrinter printer;

  Future<void> pumpPage(WidgetTester tester, FakeMode mode) async {
    await tester.runAsync(() async {
      await AppLocalizations.preload('ar');
      printer = await FakeEscPosPrinter.start(mode: mode);
    });
    final device = PrinterDevice(
        id: 'net:127.0.0.1:${printer.port}',
        name: 'Counter printer',
        kind: PrinterKind.network,
        address: '127.0.0.1',
        port: printer.port);
    final store = PrinterStore(scope: () => 'org/b1');
    await tester.runAsync(() => store.save(PrintPrefs(printer: device)));
    final service = PrintService(
      store: store,
      engine: PrintEngine(raster: _raster, confirmTimeout: const Duration(seconds: 2)),
      discovery: _QuietDiscovery.new,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [printServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const InvoicePrintPage(
          invoice: {
            'id': 'inv-1',
            'invoice_number': 'S-0001',
            'invoice_type': 'sale',
            'customer_name': 'عميل',
            'currency': 'SAR',
            'total': 10,
            'items': [
              {'description': 'منتج', 'quantity': 1, 'unit_price': 10, 'total': 10},
            ],
          },
          isPurchase: false,
          localPresets: {},
        ),
      ),
    ));
    for (var i = 0; i < 20 && find.byKey(const Key('print_now')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> printNow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('print_now')));
    // Let the real socket job run, pumping frames meanwhile.
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
      final finder = find.byKey(const Key('printer_scene'));
      if (finder.evaluate().isEmpty) continue; // still scrolling back up
      final scene = tester.widget<PrinterScene>(finder);
      if (scene.state == SceneState.printed ||
          scene.state == SceneState.sent ||
          scene.state == SceneState.failed) {
        break;
      }
    }
    await tester.pump(const Duration(milliseconds: 800));
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('«طباعة الآن» scrolls up to the printer and shows "printed" only '
      'after the printer confirms', (tester) async {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpPage(tester, FakeMode.full);
    // The default printer of this branch is already chosen.
    expect(find.text('Counter printer'), findsOneWidget);
    // Scroll down, then print.
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 300));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(scroll.pixels, greaterThan(0));
    await printNow(tester);
    expect(scroll.pixels, 0, reason: 'the page returns to the printer drawing');
    final scene = tester.widget<PrinterScene>(find.byKey(const Key('printer_scene')));
    expect(scene.state, SceneState.printed);
    expect(scene.progress, 1);
    final l10n = AppLocalizations(const Locale('ar'));
    await tester.runAsync(l10n.load);
    expect(find.text(l10n.translate('printPrinted')), findsOneWidget);
    expect(printer.count([0x1D, 0x76, 0x30, 0x00]), greaterThan(0));
    await tester.runAsync(printer.close);
  });

  testWidgets('a printer that cannot confirm is "sent", never a fake "printed"', (tester) async {
    await pumpPage(tester, FakeMode.silent);
    await printNow(tester);
    final scene = tester.widget<PrinterScene>(find.byKey(const Key('printer_scene')));
    expect(scene.state, SceneState.sent);
    final l10n = AppLocalizations(const Locale('ar'));
    await tester.runAsync(l10n.load);
    expect(find.text(l10n.translate('printSentNoConfirm')), findsOneWidget);
    expect(find.text(l10n.translate('printPrinted')), findsNothing);
    await tester.runAsync(printer.close);
  });

  testWidgets('out of paper: the paper stops and the reason is shown', (tester) async {
    await pumpPage(tester, FakeMode.paperOut);
    await printNow(tester);
    final scene = tester.widget<PrinterScene>(find.byKey(const Key('printer_scene')));
    expect(scene.state, SceneState.failed);
    expect(scene.progress, lessThan(1));
    final l10n = AppLocalizations(const Locale('ar'));
    await tester.runAsync(l10n.load);
    expect(find.text(l10n.translate('printErrPaper')), findsOneWidget);
    await tester.runAsync(printer.close);
  });

  testWidgets('a second tap while printing does not start a second job', (tester) async {
    await pumpPage(tester, FakeMode.full);
    await tester.tap(find.byKey(const Key('print_now')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('print_now')), warnIfMissed: false);
    await printNow(tester);
    expect(printer.count([0x1D, 0x56, 0x42, 0x00]), 1);
    await tester.runAsync(printer.close);
  });
}
