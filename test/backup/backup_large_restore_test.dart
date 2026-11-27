// Large continuous-backup restores on a NEW device (opt-in, heavy).
//
//   FYONA_LARGE_RESTORE=100,500,1000   target backup sizes in MB
//   FYONA_LARGE_DIR=/path/on/disk      work folder (needs ~6x the size)
//   FYONA_LARGE_KILLS=3                SIGKILLs of the restoring process (Linux)
//
// Each size: a real Business workspace with TWO branches (accounts, opening
// balances, customers, products with photos, sales with payments, made
// through the app's own APIs), grown with copies of those real invoices,
// plus photo / attachment files. Backed up by the continuous backup (with
// live changes and new attachments between runs), then restored on a new
// device — rebuild + verified copy + the app's own branch restore, for both
// branches — and compared table by table (SHA-256 of every row), balances,
// debts and every media file. Memory is sampled during each stage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_bridges.dart';
import 'package:fyona_flutter/core/backup/backup_crypto.dart';
import 'package:fyona_flutter/core/backup/backup_worker.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/media/media_store.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';

String _id() => const Uuid().v4();
// ignore: avoid_print
void _log(String s) => print(s);

Map<String, dynamic> _entitlement() => {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 2)).toIso8601String()}},
    };

DirectoryAccess _access(DirectoryWorkspace w, String branch) => DirectoryAccess(workspace: w, branchId: branch,
    readable: DirectoryPartyKind.values.toSet(), writable: DirectoryPartyKind.values.toSet(), financialCutover: true);

/// Peak resident memory while [body] runs (sampled every 20 ms).
Future<(T, int, int)> _measured<T>(Future<T> Function() body) async {
  final base = ProcessInfo.currentRss;
  var peak = base;
  final t = Timer.periodic(const Duration(milliseconds: 20), (_) => peak = max(peak, ProcessInfo.currentRss));
  final sw = Stopwatch()..start();
  try {
    final r = await body();
    return (r, sw.elapsedMilliseconds, max(0, max(peak, ProcessInfo.currentRss) - base));
  } finally {
    t.cancel();
  }
}

String _mb(int b) => (b / 1048576).toStringAsFixed(1);

/// Tables holding branch facts (excluding device-local / receipt state).
Future<List<String>> _branchTables(Database db) async {
  const local = {
    'business_backup_recoveries', '_bk_changes',
  };
  final out = <String>[];
  for (final r in await db.rawQuery("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) {
    final n = '${r['name']}';
    // Device-to-device sync bookkeeping is local to one install (a restored
    // ledger starts it fresh, as designed) — never part of a backup.
    if (local.contains(n) || n.startsWith('business_sync_')) continue;
    final cols = await db.rawQuery('PRAGMA table_info("$n")');
    if (cols.any((c) => c['name'] == 'branch_id')) out.add(n);
  }
  return out;
}

/// Row count + SHA-256 of every row of [branch] in [table] (streamed).
Future<(int, String)> _digest(Database db, String table, String branch) async {
  final info = await db.rawQuery('PRAGMA table_info("$table")');
  final cols = [for (final c in info) '${c['name']}']..remove('sequence'); // file-local order key
  final pk = [for (final c in info.where((c) => (c['pk'] as int) > 0).toList()..sort((a, b) => (a['pk'] as int) - (b['pk'] as int))) '"${c['name']}"'];
  final order = (pk.isEmpty ? cols.map((c) => '"$c"').toList() : pk).join(', ');
  final out = _Sink();
  final h = sha256.startChunkedConversion(out);
  var n = 0;
  final cur = await db.rawQueryCursor(
      'SELECT ${cols.map((c) => '"$c"').join(', ')} FROM "$table" WHERE branch_id = ? ORDER BY $order', [branch],
      bufferSize: 2000);
  try {
    while (await cur.moveNext()) {
      h.add(utf8.encode(jsonEncode(cur.current.map((k, v) => MapEntry(k, v is List<int> ? base64Encode(v) : v)))));
      h.add(const [10]);
      n++;
    }
  } finally {
    await cur.close();
  }
  h.close();
  return (n, out.value.toString());
}

class _Sink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest d) => value = d;
  @override
  void close() {}
}

/// The restore a new device runs, for every branch still empty. Used by the
/// test itself and by the child process that gets killed.
Future<Map<String, int>> _restoreNewDevice(Map<String, dynamic> cfg, {void Function(String)? stage}) async {
  final workspace = DirectoryWorkspace(server: '${cfg['server']}', accountId: '${cfg['account']}', organizationId: '${cfg['org']}');
  final root2 = Directory('${cfg['root2']}');
  final store2 = DirectoryPilotStore(root: () async => root2, keys: FixtureDirectoryKeys(Directory('${cfg['keys2']}')));
  final times = <String, int>{};
  try {
    for (final b in (cfg['branches'] as List).cast<String>()) {
      await store2.remember(_access(workspace, b), _entitlement());
    }
    for (final b in (cfg['branches'] as List).cast<String>()) {
      final access = _access(workspace, b);
      if (await _branchHasData(store2, access)) continue;
      stage?.call('rebuild $b');
      final copy = '${root2.path}/copy-$b.sqlite';
      final sw = Stopwatch()..start();
      final out = await runRestoreJob(setRoot: '${cfg['sets']}', backupId: '${cfg['backup']}',
          backupKey: base64Decode('${cfg['key']}'), targetPath: copy, dbKeyHex: '${cfg['dbKey']}',
          mediaRoot: '${cfg['media2']}', workRoot: '${root2.path}/restore-work');
      if (out.problems.isNotEmpty) throw StateError('not verified: ${out.problems.take(3)}');
      times['rebuild $b'] = sw.elapsedMilliseconds;
      stage?.call('apply $b');
      sw.reset();
      final r = await BackupBridges.applyBusiness(
          copyPath: copy, dbKeyHex: '${cfg['dbKey']}', access: access, live: store2, allowed: () => true);
      if (r.alreadyRestored) throw StateError('unexpected alreadyRestored');
      times['apply $b'] = sw.elapsedMilliseconds;
      stage?.call('done $b');
    }
  } finally {
    await store2.close();
  }
  return times;
}

Future<bool> _branchHasData(DirectoryPilotStore store, DirectoryAccess access) async {
  final grant = BusinessLedgerAccess(access, BusinessLedgerAction.values.toSet());
  return store.withLedger(grant, () => access, (l) async => (await l.accounts(grant)).isNotEmpty);
}

void main() {
  final child = Platform.environment['FYONA_LARGE_CHILD'];
  if (child != null) {
    test('large restore child', () async {
      sqfliteFfiInit();
      final cfg = jsonDecode(File(child).readAsStringSync()) as Map<String, dynamic>;
      await _restoreNewDevice(cfg, stage: (s) => stdout.writeln('CHILD_STAGE $s'));
      stdout.writeln('CHILD_DONE');
    }, timeout: Timeout.none);
    return;
  }
  final sizes = (Platform.environment['FYONA_LARGE_RESTORE'] ?? '')
      .split(',').map((s) => int.tryParse(s.trim())).whereType<int>().toList();
  final kills = int.tryParse(Platform.environment['FYONA_LARGE_KILLS'] ?? '') ?? 0;
  final base = Platform.environment['FYONA_LARGE_DIR'] ?? '${Platform.environment['HOME']}/.cache/fyona-large';
  if (sizes.isEmpty || !DirectoryPilotBuild.signupEnabled) {
    test('large restore', () {}, skip: 'set FYONA_LARGE_RESTORE=100,500,1000 (+ QA defines) to run');
    return;
  }
  final report = <String>[];
  tearDownAll(() {
    final f = File('$base/large-restore-report.txt')..writeAsStringSync('${report.join('\n')}\n');
    _log('LARGE_REPORT ${f.path}\n${report.join('\n')}');
  });

  for (final mb in sizes) {
    test('restore a $mb MB backup on a new device', () async {
      sqfliteFfiInit();
      final dir = Directory('$base/run-$mb');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final rnd = Random(mb);
      final workspace = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
      final branches = [_access(workspace, _id()), _access(workspace, _id())];
      final root1 = Directory('${dir.path}/device1')..createSync();
      final keys1 = FixtureDirectoryKeys();
      final store1 = DirectoryPilotStore(root: () async => root1, keys: keys1);
      final media1 = MediaStore(Directory('${dir.path}/device1-media'));
      MediaStore.rootProvider = () async => media1.root;
      MediaStore.reset();
      await MediaStore.instance();
      final client = ApiClient(dio: Dio());
      final target = mb * 1048576;

      Future<String> attachment(int size) async {
        final b = Uint8List(size);
        final w = b.buffer.asUint32List(0, size ~/ 4);
        for (var i = 0; i < w.length; i++) {
          w[i] = rnd.nextInt(1 << 32);
        }
        b.setRange(0, 4, const [0xFF, 0xD8, 0xFF, 0xE0]); // JPEG-looking
        return media1.put(b, mime: 'image/jpeg');
      }

      // ---- 1. Real app operations on two branches.
      final swBuild = Stopwatch()..start();
      final apis = <(LocalInventoryApi, LocalSalesApi, String, List<Map>, List<String>)>[];
      for (final a in branches) {
        await store1.remember(a, _entitlement());
        final grant = BusinessLedgerAccess(a, BusinessLedgerAction.values.toSet());
        final acct = await store1.withLedger(grant, () => a, (l) => l.createAccount(grant, commandId: _id(),
            bankName: 'Cash', accountName: 'Till', accountNumber: '1', currency: 'SAR', openingMinor: 5000000));
        final customers = <String>[];
        for (var i = 0; i < 12; i++) {
          final r = await store1.withLedger(grant, () => a, (l) => l.addPartyWithOpeningDebt(grant, DirectoryPartyKind.customer,
              commandId: _id(), name: 'عميل $i ${a.branchId.substring(0, 4)}',
              amountMinor: i.isEven ? 10000 + i * 100 : 0, currency: 'SAR'));
          customers.add('${r['party_id']}');
        }
        final inv = LocalInventoryApi(client, LocalCommerceBridge(store1, () => a, (_) => true));
        final sales = LocalSalesApi(client, LocalCommerceBridge(store1, () => a, (_) => true));
        final products = <Map>[];
        for (var i = 0; i < 40; i++) {
          products.add(await inv.createProduct({
            'name': 'منتج $i', 'unit': 'قطعة', 'price': 10.0 + i, 'stock': 100000,
            if (i % 4 == 0) 'image': await attachment(150 * 1024 + rnd.nextInt(200 * 1024)),
          }));
        }
        apis.add((inv, sales, '${acct['id']}', products, customers));
        for (var s = 0; s < 60; s++) {
          final p = products[s % products.length];
          await sales.issueSale({
            'currency': 'SAR', 'customer_id': customers[s % customers.length], 'idempotency_key': _id(),
            'items': [
              {'product_id': p['id'], 'description': 'بيع ${p['name']}', 'quantity': 1 + s % 3, 'unit_price': p['price'], 'discount': 0},
              {'product_id': products[(s + 7) % 40]['id'], 'description': 'إضافة', 'quantity': 1, 'unit_price': 5.0, 'discount': 0},
            ],
            if (s.isEven) 'payments': [{'bank_account_id': '${acct['id']}', 'amount': 5.0, 'payment_method': 'cash'}],
          });
        }
      }
      await store1.close();

      // ---- 2. Volume: copies of the real invoices (with their lines,
      // payments, balances), consistent ids, until the ledger file is big.
      final path = DirectoryDatabase.filePath(root1, workspace);
      final dbKey = keys1.memory[workspace.storageId]!;
      final dbTarget = (target * 1.5).round();
      {
        final db = await openLedgerFile(path, dbKey);
        const inv = 'business_commerce_invoices';
        final children = ['business_commerce_invoice_lines', 'business_commerce_invoice_payments', 'business_commerce_party_balances'];
        Future<List<String>> cols(String t) async => [for (final c in await db.rawQuery('PRAGMA table_info($t)')) '${c['name']}'];
        final invCols = await cols(inv);
        final childCols = {for (final t in children) t: await cols(t)};
        String sel(List<String> cs, Map<String, String> map) => cs.map((c) => map[c] ?? '"$c"').join(', ');
        for (var round = 1; File(path).lengthSync() < dbTarget; round++) {
          final size = File(path).lengthSync();
          final n = (await db.rawQuery('SELECT COUNT(*) AS n FROM $inv')).first['n'] as int;
          final per = size / max(1, n);
          final want = max(1, min(n, ((dbTarget - size) / per).ceil()));
          final sfx = "'~$round'";
          await db.transaction((tx) async {
            await tx.execute('CREATE TEMP TABLE IF NOT EXISTS pick (branch_id TEXT, id TEXT, PRIMARY KEY (branch_id, id))');
            await tx.execute('DELETE FROM pick');
            await tx.execute('INSERT INTO pick SELECT branch_id, id FROM $inv ORDER BY rowid LIMIT $want');
            await tx.execute('INSERT INTO $inv (${invCols.map((c) => '"$c"').join(', ')}) SELECT ${sel(invCols, {
                  'id': 'id || $sfx', 'number': 'number || $sfx',
                  'idempotency_key': 'CASE WHEN idempotency_key IS NULL THEN NULL ELSE idempotency_key || $sfx END',
                  // Real invoices differ: a note per copy (not trivially compressible).
                  'notes': "'ملاحظة العميل ' || hex(randomblob(36))",
                })} FROM $inv WHERE (branch_id, id) IN (SELECT branch_id, id FROM pick)');
            for (final t in children) {
              await tx.execute('INSERT INTO $t (${childCols[t]!.map((c) => '"$c"').join(', ')}) SELECT ${sel(childCols[t]!, {
                    'id': 'id || $sfx', 'invoice_id': 'invoice_id || $sfx',
                    if (t == 'business_commerce_invoice_lines') 'description': "description || ' ' || hex(randomblob(10))",
                  })} FROM $t WHERE (branch_id, invoice_id) IN (SELECT branch_id, id FROM pick)');
            }
          });
        }
        await db.close();
      }

      // ---- 3. Attachments on invoice lines (photos / scanned papers).
      Future<int> attach(double share) async {
        final db = await openLedgerFile(path, dbKey);
        var added = 0;
        try {
          final lines = await db.rawQuery(
              "SELECT rowid AS r FROM business_commerce_invoice_lines WHERE image IS NULL ORDER BY random() LIMIT 4000");
          var i = 0;
          while (added < target * share && i < lines.length) {
            final size = 1500 * 1024 + rnd.nextInt(5 * 1024 * 1024);
            final ref = await attachment(size);
            await db.rawUpdate('UPDATE business_commerce_invoice_lines SET image = ? WHERE rowid = ?', [ref, lines[i++]['r']]);
            added += size;
          }
        } finally {
          await db.close();
        }
        return added;
      }

      await attach(0.30);
      final buildMs = swBuild.elapsedMilliseconds;

      // ---- 4. Continuous backup: first set, live work, more attachments.
      final key = await BackupKeys.newKey();
      final keyBytes = await BackupKeys.keyBytes(key);
      final sets = '${dir.path}/backup/sets';
      var state = <String, dynamic>{};
      Future<(int, int, int)> backup() async {
        final (r, ms, rss) = await _measured(() => runBackupJob(BackupJob(dbPath: path, dbKeyHex: dbKey, backupKey: keyBytes,
            wrappedKey: const {}, scope: 'business:large', localRoot: sets, state: state, mediaRoot: media1.root.path)));
        expect(r.error, isNull);
        state = r.state;
        return (r.bytes, ms, rss);
      }

      final (b1, b1ms, b1rss) = await backup();
      int setBytes() => Directory('$sets/${state['id']}').listSync().whereType<File>().fold(0, (s, f) => s + f.lengthSync());
      // Live work after the first set (sales, payments) + attachments up to the target size.
      final store1b = DirectoryPilotStore(root: () async => root1, keys: keys1);
      for (var k = 0; k < branches.length; k++) {
        final sales = LocalSalesApi(client, LocalCommerceBridge(store1b, () => branches[k], (_) => true));
        final (_, _, acct, products, customers) = apis[k];
        for (var s = 0; s < 20; s++) {
          await sales.issueSale({
            'currency': 'SAR', 'customer_id': customers[s % customers.length], 'idempotency_key': _id(),
            'items': [{'product_id': products[s]['id'], 'description': 'بعد النسخة', 'quantity': 2, 'unit_price': 7.5, 'discount': 0}],
            'payments': [{'bank_account_id': acct, 'amount': 15.0, 'payment_method': 'cash'}],
          });
        }
      }
      await store1b.close();
      final gap = target - setBytes();
      if (gap > 0) await attach(gap / target);
      final (b2, b2ms, b2rss) = await backup();
      final total = setBytes();
      final files = Directory('$sets/${state['id']}').listSync().whereType<File>().length;
      final rowsFile = File(path).lengthSync();
      report.add('SIZE ${mb}MB: backup set ${_mb(total)} MB in $files files (ledger file ${_mb(rowsFile)} MB, '
          'media ${_mb(media1.root.listSync(recursive: true).whereType<File>().where((f) => !f.path.endsWith('.json')).fold(0, (s, f) => s + f.lengthSync()))} MB); '
          'data built in ${(buildMs / 1000).toStringAsFixed(1)} s');
      report.add('  backup #1 (new set): ${_mb(b1)} MB in ${(b1ms / 1000).toStringAsFixed(1)} s, RSS +${_mb(b1rss)} MB; '
          'backup #2 (changes): ${_mb(b2)} MB in ${(b2ms / 1000).toStringAsFixed(1)} s, RSS +${_mb(b2rss)} MB');

      // ---- 5. New device (empty), optionally killed mid-restore.
      final cfg = {
        'server': workspace.server, 'account': workspace.accountId, 'org': workspace.organizationId,
        'branches': [for (final b in branches) b.branchId], 'root2': '${dir.path}/device2', 'keys2': '${dir.path}/device2-keys',
        'media2': '${dir.path}/device2-media', 'sets': sets, 'backup': state['id'], 'key': base64Encode(keyBytes), 'dbKey': dbKey,
      };
      for (final d in ['root2', 'keys2', 'media2']) {
        Directory('${cfg[d]}').createSync(recursive: true);
      }
      final cfgFile = File('${dir.path}/child.json')..writeAsStringSync(jsonEncode(cfg));
      final live1 = await openLedgerFile(path, dbKey);
      final tables = await _branchTables(live1);
      final source = <String, (int, String)>{};
      for (final b in branches) {
        for (final t in tables) {
          source['$t/${b.branchId}'] = await _digest(live1, t, b.branchId);
        }
      }
      await live1.close();
      final path2 = DirectoryDatabase.filePath(Directory('${cfg['root2']}'), workspace);

      /// Each branch on the new device is either untouched (empty) or
      /// complete and identical — never half restored, never doubled.
      Future<Map<String, String>> check() async {
        final keys2 = FixtureDirectoryKeys(Directory('${cfg['keys2']}'));
        final k2 = await keys2.read(workspace.storageId);
        final out = <String, String>{};
        if (k2 == null || !File(path2).existsSync()) return {for (final b in branches) b.branchId: 'empty'};
        final db = await openLedgerFile(path2, k2);
        try {
          for (final b in branches) {
            var empty = true, same = true;
            final bad = <String>[];
            for (final t in tables) {
              final got = await _digest(db, t, b.branchId);
              if (got.$1 != 0) empty = false;
              if (got != source['$t/${b.branchId}']) {
                same = false;
                bad.add('$t ${got.$1}≠${source['$t/${b.branchId}']!.$1}');
              }
            }
            out[b.branchId] = same ? 'identical' : (empty ? 'empty' : 'PARTIAL: ${bad.take(4).join(', ')}');
          }
        } finally {
          await db.close();
        }
        return out;
      }

      if (kills > 0 && Platform.isLinux) {
        final defines = (Platform.environment['FYONA_QA_DEFINES'] ?? '').split(' ').where((s) => s.isNotEmpty);
        for (var k = 0; k < kills; k++) {
          final p = await Process.start('setsid', ['flutter', 'test', '--no-pub', ...defines, 'test/backup/backup_large_restore_test.dart'],
              environment: {'FYONA_LARGE_CHILD': cfgFile.path});
          var done = false;
          String last = '';
          p.stdout.transform(utf8.decoder).listen((s) {
            for (final m in RegExp(r'CHILD_STAGE ([^\n]+)').allMatches(s)) {
              last = m.group(1)!;
            }
            if (s.contains('CHILD_DONE')) done = true;
          });
          p.stderr.drain<void>();
          // Kill plan: inside the rebuild, then inside the live commit
          // (the app's branch restore) of the first and second branch.
          final plan = [('rebuild', 0, 150), ('apply', 0, 60), ('apply', 1, 60), ('rebuild', 1, 150)][k % 4];
          final want = '${plan.$1} ${branches[plan.$2].branchId}';
          final until = DateTime.now().add(const Duration(minutes: 30));
          while (!last.startsWith(want) && !done && DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await Future<void>.delayed(Duration(milliseconds: 100 + rnd.nextInt(max(1, mb * plan.$3 * 7 ~/ 10))));
          final at = last;
          Process.runSync('kill', ['-KILL', '--', '-${p.pid}']);
          await p.exitCode;
          // The whole process group must be gone (a big process takes a
          // moment to exit and release its file locks).
          while (Process.runSync('pgrep', ['-g', '${p.pid}']).exitCode == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final st = await check();
          report.add('  kill #${k + 1} during "$at"${done ? ' (already finished)' : ''}: ${st.values.join(' / ')}');
          expect(st.values.where((v) => v.startsWith('PARTIAL')), isEmpty, reason: 'after kill $k: $st');
        }
      }

      final stagePeak = <String, int>{};
      var stage = 'start', stageBase = ProcessInfo.currentRss;
      final sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final d = ProcessInfo.currentRss - stageBase;
        if (d > (stagePeak[stage] ?? 0)) stagePeak[stage] = d;
      });
      final ((times), ms, rss) = await _measured(() => _restoreNewDevice(cfg, stage: (s) {
            stage = '${s.split(' ').first}#${(cfg['branches'] as List).indexOf(s.split(' ').last)}';
            stageBase = ProcessInfo.currentRss;
          }));
      sampler.cancel();
      final st = await check();
      expect(st.values, everyElement('identical'), reason: '$st');
      report.add('  restore on new device: ${(ms / 1000).toStringAsFixed(1)} s total, RSS peak +${_mb(rss)} MB; '
          '${times.entries.map((e) => '${e.key.split(' ').first}#${(cfg['branches'] as List).indexOf(e.key.split(' ').last)}=${(e.value / 1000).toStringAsFixed(1)}s').join(', ')}; '
          'RSS growth per stage: ${stagePeak.entries.map((e) => '${e.key} +${_mb(e.value)} MB').join(', ')}');

      // ---- 6. Money: balances and debts identical on both devices.
      final storeA = DirectoryPilotStore(root: () async => root1, keys: keys1);
      final storeB = DirectoryPilotStore(root: () async => Directory('${cfg['root2']}'),
          keys: FixtureDirectoryKeys(Directory('${cfg['keys2']}')));
      try {
        for (final a in branches) {
          final g = BusinessLedgerAccess(a, BusinessLedgerAction.values.toSet());
          final accA = await storeA.withLedger(g, () => a, (l) => l.accounts(g));
          final accB = await storeB.withLedger(g, () => a, (l) => l.accounts(g));
          expect(accB.toString(), accA.toString());
          // Debts, invoices and payments: compared row by row above (SHA-256).
        }
      } finally {
        await storeA.close();
        await storeB.close();
      }
      // ---- 7. Every attachment is on the new device, byte-exact.
      final media2 = MediaStore(Directory('${cfg['media2']}'));
      final refs = <String>{};
      final db2 = await openLedgerFile(path2, (await FixtureDirectoryKeys(Directory('${cfg['keys2']}')).read(workspace.storageId))!);
      for (final t in ['business_commerce_invoice_lines', 'business_commerce_products']) {
        for (final r in await db2.rawQuery("SELECT image FROM $t WHERE image LIKE 'media:%'")) {
          refs.add('${r['image']}');
        }
      }
      var mediaBytes = 0;
      for (final ref in refs) {
        final f = media2.fileOf(ref);
        expect(f, isNotNull, reason: ref);
        expect('media:${(await sha256.bind(f!.openRead()).first)}', ref);
        mediaBytes += f.lengthSync();
      }
      // ---- 8. No double application: a second restore is refused, nothing changes.
      final copyAgain = '${dir.path}/again.sqlite';
      expect((await runRestoreJob(setRoot: sets, backupId: '${state['id']}', backupKey: keyBytes, targetPath: copyAgain,
          dbKeyHex: dbKey, workRoot: '${dir.path}/again-work')).problems, isEmpty);
      final storeC = DirectoryPilotStore(root: () async => Directory('${cfg['root2']}'),
          keys: FixtureDirectoryKeys(Directory('${cfg['keys2']}')));
      await expectLater(BackupBridges.applyBusiness(copyPath: copyAgain, dbKeyHex: dbKey, access: branches.first,
          live: storeC, allowed: () => true), throwsA(anything));
      await storeC.close();
      await db2.close();
      expect((await check()).values, everyElement('identical'));
      final rows = source.values.fold<int>(0, (s, v) => s + v.$1);
      report.add('  verified: ${tables.length} tables x 2 branches, $rows rows identical (SHA-256 per table), '
          'account balances identical through the app API (debts, invoices, payments, stock: row by row), ${refs.length} attachments (${_mb(mediaBytes)} MB) byte-exact, '
          'second restore refused, no duplicate rows');
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(hours: 3)));
  }
}
