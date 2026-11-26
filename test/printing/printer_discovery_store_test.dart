import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/printing/data/printer_discovery.dart';
import 'package:fyona_flutter/features/printing/data/printer_store.dart';
import 'package:fyona_flutter/features/printing/domain/printer_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('network sweep finds a real raw printer and a real IPP printer', () async {
    // Real listeners on 127.0.0.1 (unprivileged ports stand in for 9100 /
    // 631, which a CI runner cannot bind).
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final ipp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await raw.close();
      await ipp.close();
    });
    raw.listen((s) => s.destroy());
    ipp.listen((s) => s.destroy());
    final found = await PrinterDiscovery(
      sweepHosts: ['127.0.0.1'],
      sweepPorts: {raw.port: PrinterKind.network, ipp.port: PrinterKind.ipp},
      timeout: const Duration(seconds: 1),
    ).discover().toList();
    expect(found.map((d) => d.id),
        containsAll(['net:127.0.0.1:${raw.port}', 'ipp:127.0.0.1:${ipp.port}/ipp/print']));
    expect(found.firstWhere((d) => d.port == ipp.port).kind, PrinterKind.ipp);
    // Each printer once, even when several paths see it.
    expect(found.map((d) => d.id).toSet().length, found.length);
  });

  test('discovery ends quickly when nothing is there', () async {
    final sw = Stopwatch()..start();
    final found = await PrinterDiscovery(sweepHosts: ['127.0.0.1'], timeout: const Duration(seconds: 1))
        .discover()
        .where((d) => d.address == '127.0.0.1' && d.port == 1)
        .toList();
    expect(found, isEmpty);
    expect(sw.elapsed, lessThan(const Duration(seconds: 15)));
  });

  group('default printer per device and branch', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    const thermal = PrinterDevice(
        id: 'bt:AA', name: 'Receipt', kind: PrinterKind.bluetooth, address: 'AA');
    const office = PrinterDevice(
        id: 'ipp:10.0.0.5:631/ipp/print',
        name: 'Office',
        kind: PrinterKind.ipp,
        address: '10.0.0.5',
        port: 631,
        username: 'u',
        password: 'p',
        thermal: false);

    test('each branch keeps its own printer, paper and copies', () async {
      var scope = 'org/branch-1';
      final store = PrinterStore(scope: () => scope);
      await store.save(const PrintPrefs(printer: thermal, paper: PrintPaper.thermal58, copies: 2));
      scope = 'org/branch-2';
      await store.save(const PrintPrefs(printer: office, paper: PrintPaper.a4, autoCut: false));

      scope = 'org/branch-1';
      final b1 = await store.load();
      expect(b1.printer, thermal);
      expect(b1.paper, PrintPaper.thermal58);
      expect(b1.copies, 2);
      scope = 'org/branch-2';
      final b2 = await store.load();
      expect(b2.printer!.id, office.id);
      expect(b2.printer!.username, 'u');
      expect(b2.paper, PrintPaper.a4);
      expect(b2.autoCut, isFalse);
      // Both are remembered on the device for quick reuse.
      expect((await store.saved()).map((d) => d.id), containsAll([thermal.id, office.id]));
    });

    test('forgetting a printer clears it as default', () async {
      final store = PrinterStore(scope: () => 'org/b');
      await store.save(const PrintPrefs(printer: thermal));
      await store.forget(thermal.id);
      expect((await store.load()).printer, isNull);
      expect(await store.saved(), isEmpty);
    });

    test('the old device-wide setting is picked up once', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.biz_print_printer': 'id=net:10.0.0.9:9100&name=Old&kind=network&address=10.0.0.9&port=9100',
        'flutter.biz_print_paper': 'thermal58',
        'flutter.biz_print_copies': 3,
      });
      final prefs = await PrinterStore(scope: () => 'org/b').load();
      expect(prefs.printer!.address, '10.0.0.9');
      expect(prefs.printer!.port, 9100);
      expect(prefs.paper, PrintPaper.thermal58);
      expect(prefs.copies, 3);
    });
  });
}
