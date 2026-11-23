import 'dart:convert';
import 'dart:io' show zlib, File;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/recon_report_pdf.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('probe: dump streams of the produced PDF', () async {
    late Uint8List bytes;
    await binding.runAsync(() async {
      bytes = await ReconReportPdf.build(
          record: {
            'ref_code': 'RCN-T',
            'rtype': 'bank',
            'status': 'approved',
            'measured_at': '2026-10-12T01:00:00',
            'lines': [
              {'currency': 'SAR', 'name': 'ريال سعودي', 'bank_name': 'ريال سعودي',
               'system': 8.9, 'actual': 100, 'diff': 91.1}
            ],
          }, isBank: true, isAr: true, scope: {'name': 'X'});
    });
    await binding.runAsync(() async {
      File('/home/abdulrhman2/.fyona-tmp/probe.pdf').writeAsBytesSync(bytes);
    });
    final data = bytes;
    print('total len ${data.length}');
    var count = 0;
    for (var i = 0; i < data.length - 6; i++) {
      if (data[i] == 115 && data[i+1] == 116 && data[i+2] == 114 &&
          data[i+3] == 101 && data[i+4] == 97 && data[i+5] == 109) {
        // 'stream'
        count++;
        final head = String.fromCharCodes(data.sublist(i + 6, (i + 6 + 30).clamp(0, data.length)));
        print('stream@$i head=${head.replaceAll('\n', '|').replaceAll('\r', '|')}');
      }
    }
    print('stream count: $count');
    // find Filter declarations
    final s = String.fromCharCodes(data);
    final fm = RegExp(r'/Filter\s*\[([^\]]*)\]').allMatches(s);
    for (final m in fm) { print('filter: ${m.group(1)?.trim()}'); }
    final fm2 = RegExp(r'/Filter\s*/(\w+)').allMatches(s);
    for (final m in fm2) { print('filter2: ${m.group(1)}'); }
  });
}
// appended probe: dump rg ops from the built PDF
