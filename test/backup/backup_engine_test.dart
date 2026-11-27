import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_crypto.dart';
import 'package:fyona_flutter/core/backup/backup_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Synthetic merchant database: products with units / barcodes / prices,
/// customers, suppliers, invoices + lines, debts, bank balances in several
/// currencies, a WITHOUT ROWID table and a BLOB column.
Future<void> seed(Database db, {required int products, int seed = 1}) async {
  final r = Random(seed);
  await db.execute('CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, barcode TEXT, '
      'unit TEXT, factor REAL, cost_minor INTEGER, price_minor INTEGER, qty REAL, image TEXT)');
  await db.execute('CREATE TABLE parties (id TEXT PRIMARY KEY, kind TEXT, name TEXT, balance_minor INTEGER, currency TEXT)');
  await db.execute('CREATE TABLE invoices (id INTEGER PRIMARY KEY AUTOINCREMENT, party TEXT, currency TEXT, total_minor INTEGER, paid_minor INTEGER)');
  await db.execute('CREATE TABLE lines (invoice INTEGER, product INTEGER, qty REAL, price_minor INTEGER, PRIMARY KEY (invoice, product)) WITHOUT ROWID');
  await db.execute('CREATE TABLE banks (code TEXT PRIMARY KEY, currency TEXT, balance_minor INTEGER, logo BLOB)');
  await db.execute('CREATE INDEX products_barcode ON products(barcode)');
  // An app trigger: restoring must not fire it again (stock would double).
  await db.execute('CREATE TABLE stock_log (id INTEGER PRIMARY KEY, product INTEGER, delta REAL)');
  await db.execute('CREATE TRIGGER app_stock AFTER INSERT ON lines BEGIN '
      'INSERT INTO stock_log(product, delta) VALUES (NEW.product, -NEW.qty); END');
  final batch = db.batch();
  for (var i = 1; i <= products; i++) {
    batch.insert('products', {
      'id': i, 'name': i.isEven ? 'منتج رقم $i' : 'Product $i', 'barcode': '62${i.toString().padLeft(10, '0')}',
      'unit': ['قطعة', 'كرتون', 'درزن'][i % 3], 'factor': [1, 24, 12][i % 3].toDouble(),
      'cost_minor': 100 + r.nextInt(100000), 'price_minor': 200 + r.nextInt(200000), 'qty': r.nextInt(500) + 0.5,
      'image': i % 10 == 0 ? 'media:${c.sha256.convert(utf8.encode('img$i'))}' : null,
    });
  }
  const cur = ['SAR', 'USD', 'YER', 'AED'];
  final parties = max(10, products ~/ 20);
  for (var i = 0; i < parties; i++) {
    batch.insert('parties', {'id': 'p$i', 'kind': i.isEven ? 'customer' : 'supplier', 'name': 'طرف $i',
      'balance_minor': r.nextInt(1000000) - 500000, 'currency': cur[i % 4]});
  }
  final invoices = max(5, products ~/ 10);
  for (var i = 1; i <= invoices; i++) {
    batch.insert('invoices', {'party': 'p${i % parties}', 'currency': cur[i % 4],
      'total_minor': r.nextInt(900000), 'paid_minor': r.nextInt(500000)});
    batch.insert('lines', {'invoice': i, 'product': 1 + r.nextInt(products), 'qty': 1 + r.nextInt(9).toDouble(),
      'price_minor': r.nextInt(50000)}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  for (var i = 0; i < 4; i++) {
    batch.insert('banks', {'code': 'B$i', 'currency': cur[i], 'balance_minor': r.nextInt(99999999),
      'logo': Uint8List.fromList(List.generate(64, (_) => r.nextInt(256)))});
  }
  await batch.commit(noResult: true);
}

Future<String> fingerprint(Database db) async {
  final out = StringBuffer();
  for (final t in ['products', 'parties', 'invoices', 'lines', 'banks', 'stock_log']) {
    final rows = await db.rawQuery(t == 'lines' ? 'SELECT * FROM lines ORDER BY invoice, product' : 'SELECT rowid AS rid, * FROM $t ORDER BY rowid');
    for (final r in rows) {
      out.writeln(jsonEncode({for (final e in r.entries) e.key: e.value is List<int> ? base64Encode(e.value as List<int>) : e.value}));
    }
  }
  return c.sha256.convert(utf8.encode(out.toString())).toString();
}

void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  late Directory dir;
  final opened = <Database>[];
  setUp(() async => dir = await Directory.systemTemp.createTemp('fyona-bk-'));
  // Every database is closed before its folder is removed (Windows keeps
  // open files locked).
  tearDown(() async {
    for (final d in opened) {
      if (d.isOpen) await d.close();
    }
    opened.clear();
    await dir.delete(recursive: true);
  });

  Future<Database> open(String name) async {
    final d = await factory.openDatabase('${dir.path}/$name');
    opened.add(d);
    return d;
  }

  /// Full cycle: snapshot (+ live writes during it), deltas, seal, open, restore.
  Future<({List<String> problems, String live, String restored, int bytes, int ms})> cycle(
      int products, {bool writeDuringSnapshot = false}) async {
    final engine = BackupEngine();
    final db = await open('live-$products.db');
    await seed(db, products: products);
    await engine.install(db);
    final key = await BackupKeys.newKey();
    final sw = Stopwatch()..start();
    final snap = <String>[];
    var page = 0;
    final s0 = await engine.snapshot(db, (l) {
      snap.add(l);
      if (writeDuringSnapshot && ++page % 500 == 0) {
        // The user keeps working while the copy is taken.
        db.rawUpdate('UPDATE parties SET balance_minor = balance_minor + 7 WHERE id = ?', ['p${page % 10}']);
        db.rawInsert("INSERT INTO invoices(party, currency, total_minor, paid_minor) VALUES ('p1','SAR',100,0)");
        db.rawDelete('DELETE FROM products WHERE id = ?', [page]);
      }
    });
    // More work after the snapshot.
    await db.rawUpdate('UPDATE products SET qty = qty - 1 WHERE id % 7 = 0');
    await db.rawInsert("INSERT INTO lines(invoice, product, qty, price_minor) VALUES (1, ${products + 999}, 3, 500)");
    await db.rawUpdate("UPDATE banks SET balance_minor = balance_minor - 250 WHERE code = 'B1'");
    await db.rawDelete("DELETE FROM parties WHERE id = 'p3'");
    final d = await engine.delta(db, s0);
    final snapFile = await BackupContainer.seal(BackupEngine.pack(snap), key);
    final deltaFile = await BackupContainer.seal(BackupEngine.pack(d.lines), key);
    final target = await open('restored-$products.db');
    final problems = await engine.restore(
      target,
      BackupEngine.unpack(await BackupContainer.open(snapFile, key)),
      BackupEngine.unpack(await BackupContainer.open(deltaFile, key)),
      BackupCheckpoint.fromJson(jsonDecode(jsonEncode(d.checkpoint.toJson())) as Map),
    );
    sw.stop();
    final res = (problems: problems, live: await fingerprint(db), restored: await fingerprint(target),
      bytes: snapFile.length + deltaFile.length, ms: sw.elapsedMilliseconds);
    await db.close();
    await target.close();
    return res;
  }

  group('restore is exact (rows, ids, balances, quantities, blobs)', () {
    for (final n in [100, 10000]) {
      test('$n products', () async {
        final r = await cycle(n);
        // ignore: avoid_print
        print('BACKUP_BENCH products=$n ms=${r.ms} encrypted=${(r.bytes / 1024).toStringAsFixed(0)}KB');
        expect(r.problems, isEmpty);
        expect(r.restored, r.live);
      });
    }

    test('100000 products (large merchant)', () async {
      final r = await cycle(100000);
      // ignore: avoid_print
      print('BACKUP_BENCH products=100000 ms=${r.ms} encrypted=${(r.bytes / 1048576).toStringAsFixed(1)}MB');
      expect(r.problems, isEmpty);
      expect(r.restored, r.live);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('the user keeps writing while the copy is taken — still exact', () async {
      final r = await cycle(5000, writeDuringSnapshot: true);
      expect(r.problems, isEmpty);
      expect(r.restored, r.live);
    });
  });

  test('app triggers are not fired again by a restore (no doubled stock)', () async {
    final r = await cycle(300);
    expect(r.restored, r.live); // stock_log identical, not doubled
  });

  test('every saved operation is captured in the same transaction (crash-safe)', () async {
    final engine = BackupEngine();
    final path = '${dir.path}/crash.db';
    var db = await open(path.split('/').last);
    await seed(db, products: 10);
    await engine.install(db);
    final before = await engine.lastSeq(db);
    await db.transaction((tx) async {
      await tx.insert('products', {'id': 500, 'name': 'new', 'qty': 3});
      await tx.rawUpdate('UPDATE banks SET balance_minor = 1 WHERE code = ?', ['B0']);
    });
    // A transaction that fails leaves nothing in the log either.
    try {
      await db.transaction((tx) async {
        await tx.insert('products', {'id': 501, 'name': 'never', 'qty': 1});
        throw StateError('power cut');
      });
    } catch (_) {}
    await db.close(); // "kill" — reopen as after a restart
    db = await open(path.split('/').last);
    await engine.install(db);
    final d = await engine.delta(db, before);
    final ops = d.lines.map((l) => jsonDecode(l) as Map).toList();
    expect(ops.where((o) => o['t'] == 'products').length, 1);
    expect(ops.any((o) => '${o['row']}'.contains('never')), isFalse);
    expect(ops.where((o) => o['t'] == 'banks').length, 1);
    await db.close();
  });

  test('odd values never break the user write and come back exactly', () async {
    final engine = BackupEngine();
    final db = await open('odd.db');
    final cols = List.generate(100, (i) => 'c$i');
    await db.execute('CREATE TABLE wide (id INTEGER PRIMARY KEY, ${cols.map((c) => '$c TEXT').join(', ')})');
    await db.execute('CREATE TABLE loose (id INTEGER PRIMARY KEY, note TEXT, amount INTEGER)');
    await engine.install(db);
    final s0 = await engine.lastSeq(db);
    // Text produced by a JSON function, a blob in a TEXT column, text in an
    // INTEGER column, unicode, huge integers: all accepted, as before.
    await db.rawInsert("INSERT INTO loose VALUES (1, json_array('a', 'b'), 9007199254740993)");
    await db.rawInsert('INSERT INTO loose VALUES (2, ?, ?)', [Uint8List.fromList([0, 1, 2, 255]), 'نص']);
    await db.rawInsert("INSERT INTO loose VALUES (3, '{\"k\":1}', 2.5)");
    await db.insert('wide', {'id': 1, 'c0': 'x', 'c55': 'y', 'c99': 'z'}); // the rest NULL
    await db.rawUpdate("UPDATE wide SET c56 = 'late' WHERE id = 1");
    final d = await engine.delta(db, s0);
    final target = await open('odd-restored.db');
    // A snapshot of the same schema before the writes:
    final fresh = <String>[];
    final db2 = await open('odd2.db');
    await db2.execute('CREATE TABLE wide (id INTEGER PRIMARY KEY, ${cols.map((c) => '$c TEXT').join(', ')})');
    await db2.execute('CREATE TABLE loose (id INTEGER PRIMARY KEY, note TEXT, amount INTEGER)');
    await engine.snapshot(db2, fresh.add);
    final problems = await engine.restore(target, fresh, d.lines, d.checkpoint);
    expect(problems, isEmpty);
    Future<List<Map>> rows(Database x, String t) => x.rawQuery('SELECT *, typeof(note) AS tn, typeof(amount) AS ta FROM $t ORDER BY id');
    expect(await rows(target, 'loose'), await rows(db, 'loose'));
    expect(await target.rawQuery('SELECT * FROM wide'), await db.rawQuery('SELECT * FROM wide'));
    await db.close();
    await db2.close();
    await target.close();
  });

  test('cost of live capture on the user writes (measured)', () async {
    Future<int> run(bool capture) async {
      final db = await open('cost-$capture.db');
      await seed(db, products: 2000);
      if (capture) await BackupEngine().install(db);
      final sw = Stopwatch()..start();
      for (var i = 1; i <= 1000; i++) {
        // One sale: invoice + line + stock + customer balance, one transaction.
        await db.transaction((tx) async {
          final inv = await tx.insert('invoices', {'party': 'p1', 'currency': 'SAR', 'total_minor': 500, 'paid_minor': 0});
          await tx.insert('lines', {'invoice': inv, 'product': i, 'qty': 1.0, 'price_minor': 500});
          await tx.rawUpdate('UPDATE products SET qty = qty - 1 WHERE id = ?', [i]);
          await tx.rawUpdate("UPDATE parties SET balance_minor = balance_minor + 500 WHERE id = 'p1'");
        });
      }
      sw.stop();
      await db.close();
      return sw.elapsedMicroseconds;
    }

    final off = await run(false), on = await run(true);
    // ignore: avoid_print
    print('CAPTURE_COST per_sale_off=${(off / 1000).round()}us per_sale_on=${(on / 1000).round()}us '
        'overhead=${((on - off) / off * 100).toStringAsFixed(0)}%');
    expect(on / 1000, lessThan(20000), reason: 'a sale must stay well under 20 ms');
  }, timeout: const Timeout(Duration(minutes: 5))); // 2000 durable commits (slow CI disks)

  test('media references are found for the backup', () async {
    final lines = ['{"row":{"image":"media:${'a' * 64}"}}', '{"x":"media:${'b' * 64} and media:${'a' * 64}"}'];
    expect(BackupEngine.mediaRefs(lines), {'media:${'a' * 64}', 'media:${'b' * 64}'});
  });

  group('container: any tampering is refused', () {
    late SecretKey key;
    late Uint8List sealed;
    final plain = Uint8List.fromList(List.generate(2 * BackupContainer.frameSize + 1234, (i) => i % 251));
    setUp(() async {
      key = await BackupKeys.newKey();
      sealed = await BackupContainer.seal(plain, key);
    });

    test('round trip', () async => expect(await BackupContainer.open(sealed, key), plain));
    test('one flipped byte', () async {
      final bad = Uint8List.fromList(sealed)..[sealed.length ~/ 2] ^= 1;
      expect(() => BackupContainer.open(bad, key), throwsA(isA<BackupTampered>()));
    });
    test('truncated (last frame removed)', () async {
      final firstTwo = 21 + 2 * (4 + 12 + BackupContainer.frameSize + 16);
      expect(() => BackupContainer.open(Uint8List.sublistView(sealed, 0, firstTwo), key),
          throwsA(isA<BackupTampered>()));
    });
    test('frames swapped', () async {
      const f = 4 + 12 + BackupContainer.frameSize + 16;
      final a = Uint8List.sublistView(sealed, 21, 21 + f), b = Uint8List.sublistView(sealed, 21 + f, 21 + 2 * f);
      final swapped = Uint8List.fromList([...sealed.sublist(0, 21), ...b, ...a, ...sealed.sublist(21 + 2 * f)]);
      expect(() => BackupContainer.open(swapped, key), throwsA(isA<BackupTampered>()));
    });
    test('wrong key', () async {
      expect(() => BackupContainer.open(sealed, BackupKeys.keyFrom(List.filled(32, 7))), throwsA(isA<BackupTampered>()));
    });
  });

  test('recovery code: right code restores the key, wrong code gets nothing', () async {
    final key = await BackupKeys.newKey();
    final code = BackupKeys.newRecoveryCode();
    expect(code, matches(RegExp(r'^[0-9A-Z]{4}(-[0-9A-Z]{4}){5}$')));
    final sw = Stopwatch()..start();
    final wrapped = await BackupKeys.wrap(key, code, memory: 4096, iterations: 1);
    sw.stop();
    // ignore: avoid_print
    print('KDF_BENCH argon2id ms=${sw.elapsedMilliseconds}');
    expect(jsonEncode(wrapped).contains(code), isFalse);
    final back = await BackupKeys.unwrap(wrapped, code.toLowerCase().replaceAll('-', ' '));
    expect(await back!.extractBytes(), await key.extractBytes());
    expect(await BackupKeys.unwrap(wrapped, BackupKeys.newRecoveryCode()), isNull);
  });
}
