import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../features/core_business/data/local_directory/directory_database.dart';
import '../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../features/core_business/data/local_directory/directory_party.dart';
import '../../features/core_business/data/local_directory/directory_scope.dart';
import '../backup/backup_worker.dart' show openLedgerFile;
import 'import_plan.dart';

/// Smart import, step 3: the approved preview becomes ONE import batch.
///
/// Every row goes through the app's own operations (opening balance of a
/// new customer/supplier, new product with its stock) — no new accounting
/// rule. Each row's command id is derived from the file's SHA-256, the
/// branch and the row number, so the same file can never be imported twice:
/// the batch registry refuses it, and even without the registry the
/// ledger's own command idempotency returns the first result instead of a
/// second customer or debt. An interrupted batch resumes the same way.
///
/// Undo by batch: allowed only while nothing has happened to what it
/// created (no payment, invoice, stock move or edit); it removes the cards
/// and opening documents through the app's own delete operations.
///
/// Only data that has a place in FYONA is written: nothing else from the
/// file is stored or archived. The batch registry (which file, which rows,
/// what was created — for undo and the double-import check) is kept in its
/// own encrypted file next to the ledger (same key).
class ImportRegistry {
  ImportRegistry._(this._db);
  final Database _db;

  static Future<ImportRegistry> open(String path, String keyHex) async {
    await Directory(File(path).parent.path).create(recursive: true);
    final db = await openLedgerFile(path, keyHex, create: true);
    await db.execute('''CREATE TABLE IF NOT EXISTS import_batches (
      id TEXT PRIMARY KEY, branch_id TEXT NOT NULL, target TEXT NOT NULL, file_name TEXT NOT NULL,
      file_sha TEXT NOT NULL, mapping TEXT NOT NULL, status TEXT NOT NULL, rows_total INTEGER NOT NULL,
      rows_ready INTEGER NOT NULL, rows_done INTEGER NOT NULL DEFAULT 0, issues INTEGER NOT NULL,
      created_us INTEGER NOT NULL, finished_us INTEGER, undone_us INTEGER, summary TEXT)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS import_items (
      batch_id TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL, party_kind TEXT,
      opening_id TEXT, row_no INTEGER NOT NULL, PRIMARY KEY (batch_id, kind, entity_id))''');
    return ImportRegistry._(db);
  }

  Future<void> close() => _db.close();

  Future<List<Map<String, Object?>>> batches(String branch) =>
      _db.query('import_batches', where: 'branch_id = ?', whereArgs: [branch], orderBy: 'created_us DESC');

  Future<Map<String, Object?>?> batch(String id) async =>
      (await _db.query('import_batches', where: 'id = ?', whereArgs: [id])).firstOrNull;

}

class ImportRefused implements Exception {
  const ImportRefused(this.code, [this.count = 0]);

  /// already_imported | busy_after_import | not_found | already_undone
  final String code;
  final int count;
}

typedef ImportProgress = void Function(int done, int total);

class BusinessImporter {
  BusinessImporter({
    required this.store,
    required this.access,
    required this.registry,
    required this.createProduct,
    required this.deleteProduct,
    this.categories,
    this.createCategory,
    this.picture,
    this.createUnit,
    this.addBarcode,
  });

  /// The app's own unit / extra barcode operations (LocalInventoryApi).
  final Future<Map<String, dynamic>> Function(String productId, Map<String, dynamic> body)? createUnit;
  final Future<Map<String, dynamic>> Function(String productId, Map<String, dynamic> body)? addBarcode;

  final DirectoryPilotStore store;
  final DirectoryAccess access;
  final ImportRegistry registry;

  /// The app's own inventory operations (LocalInventoryApi), so a product
  /// is created and removed exactly like from the products screen.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body) createProduct;
  final Future<void> Function(String id) deleteProduct;

  /// The branch's categories and how to add one (a product's category is
  /// found by name, or created once).
  final Future<List<Map<String, dynamic>>> Function()? categories;
  final Future<Map<String, dynamic>> Function(String name)? createCategory;

  /// A picture named in the file → its `media:` reference (null: none).
  final Future<String?> Function(String name)? picture;

  static const _ns = '6a4d3f1e-9b2c-4f7a-8e5d-1c0b9a8f7e6d';
  static const _uuid = Uuid();

  BusinessLedgerAccess get _grant => BusinessLedgerAccess(access, {
        BusinessLedgerAction.createDebt,
        BusinessLedgerAction.readDebt,
        BusinessLedgerAction.deleteParty,
        BusinessLedgerAction.manageProducts,
        BusinessLedgerAction.createBank,
        BusinessLedgerAction.manageBank,
      });

  /// One batch per (file, branch, target): the same file twice is refused.
  String batchIdFor(String fileSha, ImportTarget target) =>
      _uuid.v5(_ns, 'batch|$fileSha|${access.workspace.storageId}|${access.branchId}|${target.name}');

  String _rowCommand(String batch, int row, String what) => _uuid.v5(_ns, 'row|$batch|$row|$what');

  /// Names (and product barcodes) already in the branch, for the
  /// preview's "exists" check.
  Future<Set<String>> existingNames() {
    final g = _grant;
    return store.withLedger(g, () => access, (l) => l.importExistingKeys(g, importFold));
  }

  Future<String> apply(
    ImportPreview preview, {
    required String fileSha,
    required String fileName,
    ImportProgress? onProgress,
  }) async {
    final id = batchIdFor(fileSha, preview.target);
    final prior = await registry.batch(id);
    if (prior != null && prior['status'] != 'applying') {
      throw ImportRefused(prior['status'] == 'undone' ? 'already_undone' : 'already_imported');
    }
    final db = registry._db;
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    if (prior == null) {
      await db.insert('import_batches', {
        'id': id, 'branch_id': access.branchId, 'target': preview.target.name, 'file_name': fileName,
        'file_sha': fileSha, 'mapping': jsonEncode(preview.mapping), 'status': 'applying',
        'rows_total': preview.rows, 'rows_ready': preview.ready, 'issues': preview.issueCount, 'created_us': now,
        'summary': jsonEncode({
          'totals': preview.totals,
          'customers': preview.parties.where((p) => p.kind == 'customer').length,
          'suppliers': preview.parties.where((p) => p.kind == 'supplier').length,
          'products': preview.products.length,
          'accounts': preview.accounts.length,
        }),
      });
    }
    final total = preview.ready;
    var done = 0;
    final g = _grant;
    if (preview.target == ImportTarget.parties) {
      for (final r in preview.parties) {
        final cmd = _rowCommand(id, r.row, 'party');
        final res = await store.withLedger(g, () => access, (l) => l.addPartyWithOpeningDebt(
              g,
              r.kind == 'supplier' ? DirectoryPartyKind.supplier : DirectoryPartyKind.customer,
              commandId: cmd,
              name: r.name,
              phone: r.phone,
              amountMinor: r.amountMinor,
              currency: r.currency,
            ));
        await db.insert('import_items', {
          'batch_id': id, 'kind': 'party', 'entity_id': '${res['party_id']}', 'party_kind': r.kind,
          'opening_id': res['invoice_id'], 'row_no': r.row,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (++done % 200 == 0 || done == total) {
          await db.update('import_batches', {'rows_done': done}, where: 'id = ?', whereArgs: [id]);
          onProgress?.call(done, total);
        }
      }
    } else if (preview.target == ImportTarget.accounts) {
      for (final r in preview.accounts) {
        final cmd = _rowCommand(id, r.row, 'account');
        final res = await store.withLedger(g, () => access, (l) => l.createAccount(
              g,
              commandId: cmd,
              bankName: r.bank,
              accountName: r.name,
              accountNumber: r.number,
              iban: r.iban,
              currency: r.currency,
              openingMinor: r.amountMinor,
            ));
        await db.insert('import_items', {
          'batch_id': id, 'kind': 'account', 'entity_id': '${res['id']}', 'opening_id': cmd, 'row_no': r.row,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (++done % 200 == 0 || done == total) {
          await db.update('import_batches', {'rows_done': done}, where: 'id = ?', whereArgs: [id]);
          onProgress?.call(done, total);
        }
      }
    } else {
      final catIds = <String, String>{};
      if (categories != null && preview.products.any((p) => p.category != null)) {
        for (final c in await categories!()) {
          catIds[importFold('${c['name']}')] = '${c['id']}';
        }
      }
      for (final r in preview.products) {
        final cmd = _rowCommand(id, r.row, 'product');
        String? category;
        if (r.category != null && createCategory != null) {
          final k = importFold(r.category!);
          category = catIds[k] ??= '${(await createCategory!(r.category!))['id']}';
        }
        final image = r.image == null || picture == null ? null : await picture!(r.image!);
        final created = await createProduct({
          'command_id': cmd,
          'name': r.name,
          if (r.unit != null) 'unit': r.unit,
          'price': r.sale ?? '0',
          if (r.cost != null) 'cost_price': r.cost,
          if (r.stock != null) 'stock': r.stock,
          if (r.barcode != null) 'barcode': r.barcode,
          if (r.sku != null) 'sku': r.sku,
          if (category != null) 'category_id': category,
          if (image != null) 'image': image,
          if (r.minStock != null) 'min_stock': r.minStock,
          if (r.description != null) 'description': r.description,
        });
        final pid = '${created['id']}';
        // Its other units (factor, own prices and barcode) and extra codes.
        for (var u = 0; u < r.units.length && createUnit != null; u++) {
          final unit = r.units[u];
          await createUnit!(pid, {
            'command_id': _uuid.v5(_ns, '$cmd|unit|$u'),
            'name': unit.name,
            'factor': unit.factor,
            if (unit.barcode != null) 'barcode': unit.barcode,
            if (unit.sale != null) 'sale_price': unit.sale,
            if (unit.cost != null) 'purchase_price': unit.cost,
          });
        }
        for (var b = 0; b < r.barcodes.length && addBarcode != null; b++) {
          if (r.barcodes[b] == r.barcode) continue;
          await addBarcode!(pid, {'command_id': _uuid.v5(_ns, '$cmd|barcode|$b'), 'barcode': r.barcodes[b]});
        }
        await db.insert('import_items', {
          'batch_id': id, 'kind': 'product', 'entity_id': '${created['id']}', 'row_no': r.row,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (++done % 200 == 0 || done == total) {
          await db.update('import_batches', {'rows_done': done}, where: 'id = ?', whereArgs: [id]);
          onProgress?.call(done, total);
        }
      }
    }
    // The header row of an archive batch, for showing it later.
    await db.update('import_batches', {
      'status': 'done',
      'rows_done': done,
      'finished_us': DateTime.now().toUtc().microsecondsSinceEpoch,
    }, where: 'id = ?', whereArgs: [id]);
    onProgress?.call(total, total);
    return id;
  }

  /// Undoes batch [id] when nothing happened since to what it created.
  /// Throws [ImportRefused] `busy_after_import` (with how many) otherwise.
  Future<int> undo(String id, {ImportProgress? onProgress}) async {
    final b = await registry.batch(id);
    if (b == null || b['branch_id'] != access.branchId) throw const ImportRefused('not_found');
    if (b['status'] == 'undone') throw const ImportRefused('already_undone');
    final db = registry._db;
    final items = await db.query('import_items', where: 'batch_id = ?', whereArgs: [id]);
    final g = _grant;
    final parties = {for (final i in items.where((i) => i['kind'] == 'party')) '${i['entity_id']}': '${i['party_kind']}'};
    final openings = {
      for (final i in items)
        if (i['kind'] == 'party' && i['opening_id'] != null) '${i['entity_id']}': '${i['opening_id']}',
    };
    final products = [for (final i in items.where((i) => i['kind'] == 'product')) '${i['entity_id']}'];
    final accounts = {for (final i in items.where((i) => i['kind'] == 'account')) '${i['entity_id']}': '${i['opening_id']}'};
    final busy = await store.withLedger(g, () => access,
        (l) => l.importLaterActivity(g, parties: parties, openings: openings, products: products, accounts: accounts));
    if (busy.isNotEmpty) throw ImportRefused('busy_after_import', busy.length);
    var done = 0;
    for (final e in parties.entries) {
      await store.withLedger(g, () => access, (l) => l.deleteUnlinkedParty(
            g,
            DirectoryPartyReference(
                scope: access,
                kind: e.value == 'supplier' ? DirectoryPartyKind.supplier : DirectoryPartyKind.customer,
                id: e.key),
            commandId: _uuid.v5(_ns, 'undo|$id|${e.key}'),
          ));
      if (++done % 200 == 0) onProgress?.call(done, items.length);
    }
    if (accounts.isNotEmpty) {
      final ids = accounts.keys.toList();
      for (var i = 0; i < ids.length; i += 400) {
        final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
        await store.withLedger(g, () => access, (l) => l.closeBankAccounts(g,
            commandId: _uuid.v5(_ns, 'undo|$id|accounts|$i'), accountIds: chunk));
      }
      done += accounts.length;
    }
    for (final p in products) {
      await deleteProduct(p);
      if (++done % 200 == 0) onProgress?.call(done, items.length);
    }
    await db.update('import_batches', {'status': 'undone', 'undone_us': DateTime.now().toUtc().microsecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
    onProgress?.call(items.length, items.length);
    return items.length;
  }
}
