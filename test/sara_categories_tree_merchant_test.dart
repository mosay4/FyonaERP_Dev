import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/ai/domain/agent/confirmation_handler.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_registry.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/data/repositories/financial_tree_storage.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/shared/widgets/sara_action_dispatcher.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

class _FakePath extends PathProviderPlatform {
  _FakePath(this.d);
  final Directory d;
  @override
  Future<String?> getApplicationDocumentsPath() async => d.path;
  @override
  Future<String?> getTemporaryPath() async => d.path;
  @override
  Future<String?> getApplicationSupportPath() async => d.path;
}

/// Server-side merchant links, in memory (same calls the screen makes).
class _FakeMerchants extends MerchantApi {
  _FakeMerchants() : super(ApiClient(dio: Dio()));
  final invites = <Map<String, dynamic>>[];
  final merchants = <Map<String, dynamic>>[];
  final calls = <String>[];
  @override
  Future<List<Map<String, dynamic>>> myInvites() async => [...invites];
  @override
  Future<List<Map<String, dynamic>>> myMerchants() async => [...merchants];
  @override
  Future<void> acceptInvite(String linkId) async {
    calls.add('accept:$linkId');
    final i = invites.firstWhere((x) => x['link_id'] == linkId);
    invites.remove(i);
    merchants.add(i);
  }
  @override
  Future<void> rejectInvite(String linkId) async {
    calls.add('reject:$linkId');
    invites.removeWhere((x) => x['link_id'] == linkId);
  }
  @override
  Future<void> unlinkMerchant(String linkId) async {
    calls.add('unlink:$linkId');
    merchants.removeWhere((x) => x['link_id'] == linkId);
  }
}

const _newTools = [
  'add_category', 'update_category', 'delete_category',
  'create_financial_tree', 'update_financial_tree', 'delete_financial_tree',
  'add_tree_node', 'update_tree_node', 'delete_tree_node',
  'accept_merchant_invite', 'reject_merchant_invite', 'unlink_merchant',
];

void main() {
  const uid = 1717;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = _FakePath(await Directory.systemTemp.createTemp('sara_cats'));
  });

  /// A fresh service each call = an app restart (nothing held in memory).
  PersonalFinanceService svc() {
    final s = PersonalFinanceService(
      apiClient: ApiClient(dio: Dio(BaseOptions(
        baseUrl: 'http://127.0.0.1:9',
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
      ))),
      cache: PersonalCacheRepository(),
    );
    s.setUserId(uid);
    return s;
  }

  Future<void> clean() async {
    await (await testLedger()).rawDelete('DELETE FROM personal_entity_cache WHERE user_id = ?', [uid.toString()]);
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
    SharedPreferences.setMockInitialValues({});
  }

  setUp(clean);
  tearDown(clean);

  Future<void> useCategory(String name) => PersonalCacheRepository().upsertItem(
      uid, 'personal_transaction', 'tx-$name', {'id': 'tx-$name', 'category': name, 'amount': 5});

  group('categories persist on the device', () {
    test('add / edit / delete survive a fresh service instance', () async {
      final added = await svc().addCategory(SpendingCategory(id: '', name: 'Food', nameAr: 'طعام'));
      expect(added.id, isNotEmpty);
      var list = await svc().getLocalCategories();
      expect(list.map((c) => c.nameAr), contains('طعام'));
      // Offline server (127.0.0.1:9): getCategories still lists it.
      expect((await svc().getCategories()).map((c) => c.id), contains(added.id));

      await svc().updateCategory(SpendingCategory(id: added.id, name: 'Groceries', nameAr: 'بقالة'));
      list = await svc().getLocalCategories();
      final edited = list.firstWhere((c) => c.id == added.id);
      expect([edited.name, edited.nameAr], ['Groceries', 'بقالة']);
      expect(list.where((c) => c.nameAr == 'طعام'), isEmpty);

      await svc().deleteCategory(added.id);
      expect((await svc().getLocalCategories()).where((c) => c.id == added.id), isEmpty);
      // Nothing was queued for the server (it has no category entity).
      expect(await (await testLedger()).rawQuery('SELECT * FROM sync_queue'), isEmpty);
    });

    test('stored in the backed-up Personal mirror', () async {
      final added = await svc().addCategory(SpendingCategory(id: '', name: 'Fuel', nameAr: 'وقود'));
      final rows = await (await testLedger()).rawQuery(
          'SELECT data_json FROM personal_entity_cache WHERE user_id = ? AND entity_type = ?',
          [uid, PersonalFinanceService.categoryEntityType]);
      expect(rows, hasLength(1));
      expect((jsonDecode(rows.first['data_json'] as String) as Map)['id'], added.id);
    });

    test('screen validation: both names, no duplicates', () async {
      await expectLater(svc().addCategory(SpendingCategory(id: '', name: '', nameAr: 'سفر')),
          throwsA(isA<CategoryException>().having((e) => e.code, 'code', 'NAME_REQUIRED')));
      await svc().addCategory(SpendingCategory(id: '', name: 'Travel', nameAr: 'سفر'));
      await expectLater(svc().addCategory(SpendingCategory(id: '', name: 'travel', nameAr: 'رحلات')),
          throwsA(isA<CategoryException>().having((e) => e.code, 'code', 'DUPLICATE')));
    });

    test('a category used by transactions is never deleted (nothing reassigned)', () async {
      final c = await svc().addCategory(SpendingCategory(id: '', name: 'Rent', nameAr: 'إيجار'));
      await useCategory('إيجار');
      await expectLater(svc().deleteCategory(c.id),
          throwsA(isA<CategoryException>().having((e) => e.code, 'code', 'CATEGORY_IN_USE')));
      expect((await svc().getLocalCategories()).where((x) => x.id == c.id), hasLength(1));
      // Renaming it must keep the name the transactions reference.
      await expectLater(svc().updateCategory(SpendingCategory(id: c.id, name: 'Home', nameAr: 'منزل')),
          throwsA(isA<CategoryException>().having((e) => e.code, 'code', 'CATEGORY_IN_USE')));
      await svc().updateCategory(SpendingCategory(id: c.id, name: 'Housing', nameAr: 'إيجار'));
      final list = await svc().getLocalCategories();
      expect(list.where((x) => x.nameAr == 'إيجار'), hasLength(1), reason: 'no derived duplicate');
    });
  });

  group('registry + contract', () {
    final contract = jsonDecode(File('backend/app/domain/services/sara_tool_contract.v1.json').readAsStringSync()) as Map;
    final ids = (contract['tools'] as List).map((t) => (t as Map)['tool_id']).toSet();

    test('every new tool is exposed and in the 1.7.0 contract', () {
      expect(contract['contract_version'], '1.7.0');
      for (final t in _newTools) {
        expect(AgentToolRegistry.findByName(t), isNotNull, reason: t);
        expect(ids, contains(t));
      }
    });

    test('deletes / unlink / accepting a link need the one-tap card; edits do not', () {
      for (final t in ['delete_category', 'delete_financial_tree', 'delete_tree_node', 'unlink_merchant', 'accept_merchant_invite']) {
        final def = AgentToolRegistry.findByName(t)!;
        expect(ConfirmationHandler.requiresConfirmation(def), isTrue, reason: t);
      }
      for (final t in ['add_category', 'update_category', 'create_financial_tree', 'add_tree_node', 'update_tree_node', 'reject_merchant_invite']) {
        expect(ConfirmationHandler.requiresConfirmation(AgentToolRegistry.findByName(t)!), isFalse, reason: t);
      }
      final card = ConfirmationHandler.buildConfirmationMessage(
          AgentToolRegistry.findByName('delete_category')!, {'category_name': 'سفر'});
      expect(card, contains('سفر'));
    });

    test('reply buttons open the right screens', () {
      expect(saraEntityRoute({'entity_type': 'category', 'id': 'x'}), RouteNames.personalCategories);
      expect(saraEntityRoute({'entity_type': 'financial_tree', 'id': 'x'}), RouteNames.financialTree);
      expect(saraEntityRoute({'entity_type': 'merchant', 'id': 'x'}), RouteNames.personalMerchantAccounts);
    });
  });

  group('Sara categories', () {
    test('add, rename, delete — confirmed, with a button to the screen', () async {
      final exec = ToolExecutor(svc());
      final a = await exec.execute('add_category', {'name_ar': 'هدايا', 'name_en': 'Gifts'});
      expect(a.success, isTrue, reason: a.messageAr);
      expect(a.verificationStatus, 'confirmed');
      expect(a.entityType, 'category');
      expect(a.entityId, isNotNull);
      expect(a.route, RouteNames.personalCategories);

      final u = await exec.execute('update_category', {'category_name': 'gifts', 'new_name_ar': 'هدايا وعطايا'});
      expect(u.success, isTrue, reason: u.messageAr);
      expect((await svc().getLocalCategories()).firstWhere((c) => c.id == a.entityId).nameAr, 'هدايا وعطايا');

      final d = await exec.execute('delete_category', {'category_name': 'هدايا وعطايا'});
      expect(d.success, isTrue, reason: d.messageAr);
      expect((await svc().getLocalCategories()).where((c) => c.id == a.entityId), isEmpty);
    });

    test('in use, unknown name, maintenance: refused, nothing changed', () async {
      final s = svc();
      await s.addCategory(SpendingCategory(id: '', name: 'Bills', nameAr: 'فواتير'));
      await useCategory('فواتير');
      final inUse = await ToolExecutor(s).execute('delete_category', {'category_name': 'فواتير'});
      expect(inUse.success, isFalse);
      expect(inUse.errorCode, 'CATEGORY_IN_USE');
      final unknown = await ToolExecutor(s).execute('delete_category', {'category_name': 'غير موجود'});
      expect(unknown.errorCode, 'NOT_FOUND');
      expect(unknown.messageAr, contains('فواتير'), reason: 'lists the choices');
      final m = await ToolExecutor(s, maintenanceBlocked: (r) => r == RouteNames.personalCategories)
          .execute('add_category', {'name_ar': 'صيانة', 'name_en': 'Upkeep'});
      expect(m.errorCode, 'MAINTENANCE');
      expect((await s.getLocalCategories()).where((c) => c.nameAr == 'صيانة'), isEmpty);
    });
  });

  group('Sara financial tree', () {
    test('create tree, add/edit/move/delete items, delete tree', () async {
      var reloads = 0;
      final exec = ToolExecutor(svc(), onTreesChanged: () async => reloads++);
      final storage = FinancialTreeStorage();

      final t = await exec.execute('create_financial_tree', {'name': 'خطة 2027', 'base_amount': 5000, 'currency': 'SAR'});
      expect(t.success, isTrue, reason: t.messageAr);
      expect(t.route, RouteNames.financialTree);
      final tree = (await storage.loadTrees()).single;
      expect([tree.name, tree.baseAmount], ['خطة 2027', 5000]);

      // One tree: tree_name may be omitted.
      final a = await exec.execute('add_tree_node', {'name': 'سكن', 'node_type': 'expense', 'amount': 1500});
      expect(a.success, isTrue, reason: a.messageAr);
      final b = await exec.execute('add_tree_node', {'name': 'كهرباء', 'node_type': 'expense', 'amount': 300, 'parent_name': 'سكن'});
      expect(b.success, isTrue, reason: b.messageAr);
      final c = await exec.execute('add_tree_node', {'name': 'راتب', 'node_type': 'income', 'amount': 9000, 'tree_name': 'خطة 2027'});
      expect(c.success, isTrue, reason: c.messageAr);

      final bad = await exec.execute('add_tree_node', {'name': 'x', 'node_type': 'root'});
      expect(bad.errorCode, 'INVALID_TYPE');
      final cycle = await exec.execute('update_tree_node', {'node_name': 'سكن', 'new_parent_name': 'كهرباء'});
      expect(cycle.errorCode, 'INVALID_PARENT');
      final root = await exec.execute('delete_tree_node', {'node_name': 'خطة 2027'});
      expect(root.errorCode, 'ROOT_NODE');

      final u = await exec.execute('update_tree_node', {'node_name': 'كهرباء', 'amount': 350, 'new_parent_name': 'راتب'});
      expect(u.success, isTrue, reason: u.messageAr);
      var nodes = await storage.loadNodes(tree.id);
      final elec = nodes.firstWhere((n) => n.name == 'كهرباء');
      expect(elec.amount, 350);
      expect(elec.parentId, nodes.firstWhere((n) => n.name == 'راتب').id);

      final meta = await exec.execute('update_financial_tree', {'new_name': 'خطة 2028', 'base_amount': 7000});
      expect(meta.success, isTrue, reason: meta.messageAr);
      nodes = await storage.loadNodes(tree.id);
      expect(nodes.firstWhere((n) => n.isRoot).name, 'خطة 2028', reason: 'root follows the tree');

      final d = await exec.execute('delete_tree_node', {'node_name': 'راتب'});
      expect(d.success, isTrue, reason: d.messageAr);
      nodes = await storage.loadNodes(tree.id);
      expect(nodes.map((n) => n.name), unorderedEquals(['خطة 2028', 'سكن']), reason: 'branch removed');

      final del = await exec.execute('delete_financial_tree', {'tree_name': 'خطة 2028'});
      expect(del.success, isTrue, reason: del.messageAr);
      expect(await storage.loadTrees(), isEmpty);
      expect(reloads, greaterThanOrEqualTo(8), reason: 'the open screen reloads after each write');
    });

    test('two trees: an unnamed item asks which tree; maintenance blocks', () async {
      final exec = ToolExecutor(svc());
      await exec.execute('create_financial_tree', {'name': 'أ'});
      await exec.execute('create_financial_tree', {'name': 'ب'});
      final ask = await exec.execute('add_tree_node', {'name': 'بند'});
      expect(ask.errorCode, 'NEEDS_TREE');
      expect(ask.messageAr, allOf(contains('أ'), contains('ب')));
      final m = await ToolExecutor(svc(), maintenanceBlocked: (r) => r == RouteNames.financialTree)
          .execute('delete_financial_tree', {'tree_name': 'أ'});
      expect(m.errorCode, 'MAINTENANCE');
      expect(await FinancialTreeStorage().loadTrees(), hasLength(2));
    });
  });

  group('Sara merchant links', () {
    test('accept, reject, unlink — the same API calls as the screen', () async {
      final api = _FakeMerchants()
        ..invites.addAll([
          {'link_id': 'L1', 'merchant_name': 'متجر النور'},
          {'link_id': 'L2', 'merchant_name': 'Bakery', 'shop_name': 'مخبز الحي'},
        ]);
      final exec = ToolExecutor(svc(), merchantApi: api);
      final acc = await exec.execute('accept_merchant_invite', {'merchant_name': 'النور'});
      expect(acc.success, isTrue, reason: acc.messageAr);
      expect(acc.route, RouteNames.personalMerchantAccounts);
      final rej = await exec.execute('reject_merchant_invite', {'merchant_name': 'مخبز الحي'});
      expect(rej.success, isTrue, reason: rej.messageAr);
      final un = await exec.execute('unlink_merchant', {'merchant_name': 'متجر النور'});
      expect(un.success, isTrue, reason: un.messageAr);
      expect(api.calls, ['accept:L1', 'reject:L2', 'unlink:L1']);
    });

    test('unknown merchant lists the choices; no API = honest offline refusal', () async {
      final api = _FakeMerchants()..merchants.add({'link_id': 'L9', 'merchant_name': 'صيدلية'});
      final r = await ToolExecutor(svc(), merchantApi: api).execute('unlink_merchant', {'merchant_name': 'مطعم'});
      expect(r.errorCode, 'NOT_FOUND');
      expect(r.messageAr, contains('صيدلية'));
      expect(api.calls, isEmpty);
      final off = await ToolExecutor(svc()).execute('unlink_merchant', {'merchant_name': 'صيدلية-x'});
      expect(off.errorCode, 'OFFLINE');
    });
  });
}
