import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:collection/collection.dart';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/di/providers.dart'
    show apiClientProvider, secureStorageProvider;
import '../../../../core/network/api_client.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../core_business/data/local_directory/directory_pilot.dart';
import '../../core_business/data/local_ledger/business_relay_identity.dart';
import '../../core_business/presentation/providers/business_ledger_session.dart';
import '../../employees/presentation/providers/employee_providers.dart';
import 'branch_local_transfers.dart';
import 'branch_scope.dart';

const _branchListCacheKey = 'branch_manage_cache_v1';

/// True when the request never reached the server. Such a failure is never a
/// reason to empty a screen or to show the transport library's own text.
bool isConnectionError(Object error) {
  if (error is DioException) {
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.error is SocketException;
  }
  return error is SocketException;
}

Future<void> _cacheJson(String key, Object value) async {
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(key, jsonEncode(value));
  } catch (_) {
    // A cache write failure never breaks the screen.
  }
}

Future<List<Map<String, dynamic>>?> _cachedJson(String key) async {
  try {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(key);
    if (raw == null) return null;
    final rows = jsonDecode(raw) as List;
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  } catch (_) {
    return null;
  }
}

const _branchPendingKey = 'branch_pending_ops_v1';

/// Edits made while offline. They are applied to the screen at once and
/// pushed to the server when the connection is back; nothing is lost and no
/// screen ever waits for the network.
Future<Map<String, dynamic>> _pendingBranchOps() async {
  try {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_branchPendingKey);
    if (raw == null) return {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return {};
  }
}

Future<void> _putPending(String id, Map<String, Object?> op) async {
  final ops = await _pendingBranchOps();
  final row = Map<String, dynamic>.from(ops[id] as Map? ?? {});
  row.addAll(op);
  ops[id] = row;
  final sp = await SharedPreferences.getInstance();
  await sp.setString(_branchPendingKey, jsonEncode(ops));
}

Future<void> _clearPending(String id, List<String> keys) async {
  final ops = await _pendingBranchOps();
  final row = Map<String, dynamic>.from(ops[id] as Map? ?? {});
  for (final key in keys) {
    row.remove(key);
  }
  if (row.isEmpty) {
    ops.remove(id);
  } else {
    ops[id] = row;
  }
  final sp = await SharedPreferences.getInstance();
  await sp.setString(_branchPendingKey, jsonEncode(ops));
}

const _branchSentKey = 'branch_transit_sent_v1';

Future<Map<String, dynamic>> _sentRevs() async {
  try {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_branchSentKey);
    if (raw == null) return {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return {};
  }
}

Future<void> _saveSentRevs(Map<String, dynamic> sent) async {
  final sp = await SharedPreferences.getInstance();
  await sp.setString(_branchSentKey, jsonEncode(sent));
}

/// The rows exactly as the user last left them: their own offline edits and
/// the branches they created here, before any other copy is reached.
Future<List<Map<String, dynamic>>> _withPending(
  List<Map<String, dynamic>> rows,
) async {
  final ops = await _pendingBranchOps();
  final byId = {for (final row in rows) '${row['id']}': row};
  for (final entry in ops.entries) {
    final change = Map<String, dynamic>.from(entry.value as Map? ?? {});
    change.remove('rev');
    final base = byId[entry.key] ?? {'id': entry.key, 'is_default': false};
    byId[entry.key] = {...base, ...change};
  }
  return [
    for (final row in byId.values)
      if (row['deleted'] != true) row,
  ];
}

final Provider<BranchApi> branchApiProvider = Provider<BranchApi>((ref) {
  (String, String?)? identity() {
    final user = ref.read(currentUserProvider);
    return user == null ? null : (user.id, user.organizationId);
  }

  final account = ref.watch(
    currentUserProvider.select(
      (user) => user == null ? null : (user.id, user.organizationId),
    ),
  );
  final server = ref.watch(serverBaseUrlProvider);
  final storage = ref.read(secureStorageProvider);
  return BranchApi(
    ref.watch(apiClientProvider),
    account: account?.$1,
    homeOrganization: account?.$2,
    isCurrent: () =>
        identity() == account && ref.read(serverBaseUrlProvider) == server,
    sessionId: () => account == null
        ? Future.value(null)
        : readBusinessCashSession(storage, account.$1),
    transfersOnDevice: () => ref.read(businessLocalLedgerScopeProvider) != null,
    local: () {
      final scope = ref.read(businessLocalLedgerScopeProvider);
      if (scope == null) return null;
      return BranchLocalTransfers(
        scope: () => ref.read(businessLocalLedgerScopeProvider),
        store: () => ref.read(directoryPilotStoreProvider),
        allowed: () => !BranchScope.readOnly,
        can: (permission) => ref.read(employeeCanProvider(permission)),
        changed: () {
          ref.read(businessBankRevisionProvider.notifier).state++;
          ref.read(businessOperationsRevisionProvider.notifier).state++;
        },
      );
    },
  );
});

final class BranchTransferDeviceScope implements Exception {
  const BranchTransferDeviceScope();

  static bool matches(Object? error) {
    if (error is BranchTransferDeviceScope) return true;
    final body = error is DioException ? error.response?.data : null;
    final detail = body is Map ? body['detail'] : null;
    return detail is Map && detail['code'] == 'transfer_device_scope';
  }
}

class BranchApi {
  final ApiClient _client;
  final bool Function()? _transfersOnDevice;
  final BranchLocalTransfers? Function()? _local;
  final String? _account;
  final String? _homeOrganization;
  final bool Function()? _isCurrent;
  final Future<String?> Function()? _sessionId;

  BranchApi(
    this._client, {
    String? account,
    String? homeOrganization,
    bool Function()? isCurrent,
    Future<String?> Function()? sessionId,
    bool Function()? transfersOnDevice,
    BranchLocalTransfers? Function()? local,
  }) : _account = account,
       _homeOrganization = homeOrganization,
       _isCurrent = isCurrent,
       _sessionId = sessionId,
       _transfersOnDevice = transfersOnDevice,
       _local = local;

  bool get _current => _isCurrent?.call() ?? true;

  late final String? _owner = _account == null || _account.isEmpty
      ? null
      : jsonEncode([_client.dio.options.baseUrl, _account, _homeOrganization]);

  bool get ownsSavedSelection {
    if (_owner == null || !_current || BranchScope.organizationId == null) {
      return false;
    }
    final owner = BranchScope.selectionOwner;
    if (owner != null) return owner == _owner;
    // An upgraded installation can resume the exact old signed selection.
    return _matchingToken(
      BranchScope.token,
      BranchScope.organizationId!,
      BranchScope.branchId,
      BranchScope.allMode,
    );
  }

  bool get transfersOnDevice => _transfersOnDevice?.call() == true;

  void _requireConnectedTransfer() {
    if (transfersOnDevice) throw const BranchTransferDeviceScope();
  }

  dynamic _data(response) {
    final d = response.data;
    if (d is Map && d['data'] != null) return d['data'];
    return d;
  }

  Future<List<Map<String, dynamic>>> list({bool archived = false}) async {
    try {
      await _flushPending();
      final r = await _client.get(
        '/branches/manage',
        queryParameters: {'include_archived': archived},
      );
      final d = _data(r);
      final rows = (d is Map ? d['branches'] : null) as List? ?? const [];
      final local = await _cachedJson(_branchListCacheKey) ?? [];
      final byId = {
        for (final row in rows)
          '${row['id']}': Map<String, dynamic>.from(row as Map),
      };
      // The device's own store is the truth: branches born here and the rows
      // it already holds are never dropped by another copy.
      for (final row in local) {
        byId.putIfAbsent('${row['id']}', () => Map<String, dynamic>.from(row));
      }
      final out = await _withPending(byId.values.toList());
      if (!archived) await _cacheJson(_branchListCacheKey, out);
      return out;
    } catch (e) {
      // A cold start without internet shows the very same branches the user
      // already has, instead of an empty page or a raw library error.
      if (!archived && isConnectionError(e)) {
        final cached = await _cachedJson(_branchListCacheKey);
        if (cached != null) return _withPending(cached);
      }
      rethrow;
    }
  }

  Future<String> _localImagePath(String id) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/branch_$id.img';
  }

  /// Carry this device's own changes to the other devices of the branch and
  /// store what they sent. The server keeps nothing: every payload is dropped
  /// there once all destinations acknowledged it.
  Future<void> _flushPending() async {
    for (final entry in (await _pendingBranchOps()).entries) {
      final row = Map<String, dynamic>.from(entry.value as Map? ?? {});
      if (row['registered'] != false) continue;
      try {
        await _client.post(
          '/branches',
          data: {'id': entry.key, 'name': row['name']},
        );
        await _putPending(entry.key, {'registered': true});
      } on DioException catch (e) {
        if (e.response?.statusCode == 400) {
          // Another device registered a branch with this name first: the
          // first one stays (same rule as every other duplicate).
          await _clearPending(entry.key, row.keys.toList());
        }
      } catch (_) {
        // Offline: it is registered when the connection is back.
      }
    }
    final ops = await _pendingBranchOps();
    final sent = await _sentRevs();
    for (final entry in ops.entries.toList()) {
      final id = entry.key;
      final row = Map<String, dynamic>.from(entry.value as Map? ?? {});
      final rev = '${row['rev'] ?? ''}';
      if (rev.isEmpty || rev == sent[id]) continue;
      String? image;
      final local = row['image'];
      if (local is String && local.startsWith('local://')) {
        final file = File(local.substring('local://'.length));
        if (file.existsSync()) {
          image = base64Encode(await file.readAsBytes());
        }
      }
      try {
        await _client.post(
          '/business/media-transit',
          data: {
            'branch_id': id,
            'kind': 'branch_update',
            'target_id': id,
            'payload': base64Encode(
              utf8.encode(
                jsonEncode({
                  if (row['name'] is String) 'name': row['name'],
                  if (image != null) 'image': image,
                  if (row['is_archived'] is bool)
                    'is_archived': row['is_archived'],
                  if (row['deleted'] == true) 'deleted': true,
                }),
              ),
            ),
          },
        );
        sent[id] = rev;
        await _saveSentRevs(sent);
      } catch (_) {
        // The payload stays with this device until the road is open again.
      }
    }
    try {
      final r = await _client.get('/business/media-transit');
      final data = _data(r);
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      for (final item in items.whereType<Map>()) {
        final body =
            jsonDecode(utf8.decode(base64Decode('${item['payload']}'))) as Map;
        final id = '${item['target_id']}';
        final image = body['image'];
        final row = <String, Object?>{
          if (body['name'] is String) 'name': body['name'],
          if (body['is_archived'] is bool) 'is_archived': body['is_archived'],
          if (body['deleted'] == true) 'deleted': true,
          'rev': 'remote-${item['id']}',
        };
        if (image is String && image.isNotEmpty) {
          final path = await _localImagePath(id);
          await File(path).writeAsBytes(base64Decode(image), flush: true);
          row['image'] = 'local://$path';
        }
        await _putPending(id, row);
        final sentNow = await _sentRevs();
        sentNow[id] = 'remote-${item['id']}';
        await _saveSentRevs(sentNow);
        await _client.post(
          '/business/media-transit/ack',
          data: {'id': item['id']},
        );
      }
    } catch (_) {
      // Nothing to carry right now.
    }
  }

  Future<Map<String, dynamic>> create(String name) async {
    // A new branch is born on this device. The server only carries it to the
    // other devices of the account and keeps nothing.
    final id = const Uuid().v4();
    await _putPending(id, {
      'id': id,
      'name': name,
      'is_archived': false,
      'is_default': false,
      'image': null,
      // The server must learn the id and name (nothing else) before the
      // branch can be selected and its work carried to other devices.
      'registered': false,
      'rev': '${DateTime.now().microsecondsSinceEpoch}',
    });
    unawaited(_flushPending());
    return {'id': id, 'name': name};
  }

  Future<Map<String, dynamic>> rename(String id, String name) async {
    // The name lives on the device. The server only carries it to the other
    // devices of this branch and drops it once they all stored it.
    await _putPending(id, {
      'name': name,
      'rev': '${DateTime.now().microsecondsSinceEpoch}',
    });
    return {'id': id, 'name': name};
  }

  Future<Map<String, dynamic>> uploadImage(String id, Uint8List bytes) async {
    final path = await _localImagePath(id);
    await File(path).writeAsBytes(bytes, flush: true);
    await _putPending(id, {
      'image': 'local://$path',
      'rev': '${DateTime.now().microsecondsSinceEpoch}',
    });
    return {'id': id, 'image': 'local://$path'};
  }

  Future<void> resetData(String id) => _client.post('/branches/$id/reset');

  Future<List<String>> currencies() async {
    final r = await _client.get('/branches/currencies');
    final d = _data(r);
    final rows = (d is Map ? d['currencies'] : null) as List? ?? const [];
    return rows.whereType<String>().toList();
  }

  Future<void> saveCurrencies(List<String> currencies) async {
    await _client.dio.put(
      '/business/project-settings',
      data: {'enabled_currencies': currencies},
    );
  }

  Future<Map<String, dynamic>> resetAllBusiness() async {
    final r = await _client.post('/branches/reset-all');
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<void> deletePermanently(String id) =>
      _localChange(id, {'deleted': true});

  Future<void> archive(String id) => _localChange(id, {'is_archived': true});

  Future<void> reactivate(String id) =>
      _localChange(id, {'is_archived': false});

  /// Every management action is a local change first; the other devices pick
  /// it up through the transit and the server drops it once they all have it.
  Future<void> _localChange(String id, Map<String, Object?> change) async {
    await _putPending(id, {
      ...change,
      'id': id,
      'rev': '${DateTime.now().microsecondsSinceEpoch}',
    });
  }

  Future<Map<String, dynamic>> select({
    String? branchId,
    bool all = false,
    String? organizationId,
  }) => _select(branchId: branchId, all: all, organizationId: organizationId);

  Future<Map<String, dynamic>> _select({
    String? branchId,
    required bool all,
    String? organizationId,
    bool bounded = false,
    bool Function()? stillSelected,
  }) async {
    final previous = BranchScope.selection;
    bool canApply() =>
        _current &&
        previous == BranchScope.selection &&
        stillSelected?.call() != false;
    final cancel = bounded ? CancelToken() : null;
    final request = _client.post(
      '/branches/select',
      data: {
        'branch_id': branchId,
        'all': all,
        if (organizationId != null) 'organization_id': organizationId,
      },
      cancelToken: cancel,
    );
    final r = !bounded
        ? await request
        : await request.timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              cancel!.cancel();
              throw TimeoutException('Branch selection');
            },
          );
    final d = Map<String, dynamic>.from(_data(r) as Map? ?? {});
    final org = d['organization_id']?.toString();
    final id = d['branch_id']?.toString();
    final token = d['token']?.toString();
    if (!canApply() ||
        (organizationId != null && org != organizationId) ||
        (branchId != null && id != branchId) ||
        (_owner != null &&
            (org == null || !_matchingToken(token, org, id, all)))) {
      throw StateError('Branch selection is no longer valid');
    }
    await BranchScope.save(
      token: token,
      branchId: id,
      branchName: (d['branch'] as Map?)?['name']?.toString(),
      allMode: all,
      organizationId: org,
      selectionOwner: _owner,
      stillSelected: canApply,
    );
    if (_owner != null && org != null && token != null) {
      await _rememberToken(org, id, all, token);
    }
    return d;
  }

  static bool companyIsOpen(Map company) {
    final end = DateTime.tryParse(
      '${company['owner_subscription_end_date'] ?? ''}',
    );
    return company['owner_expired'] != true &&
        (end == null || end.isAfter(DateTime.now()));
  }

  static Iterable<Map> selectableBranches(Map company) =>
      (company['branches'] as List? ?? const []).whereType<Map>().where(
        (branch) =>
            branch['id'] is String &&
            branch['is_active'] != false &&
            branch['is_archived'] != true,
      );

  Future<void> selectFromDrawer({
    required String organizationId,
    required String? branchId,
    required bool all,
    required bool connected,
  }) async {
    final previous = BranchScope.selection;
    if (connected) {
      try {
        await _select(
          organizationId: organizationId,
          branchId: branchId,
          all: all,
          bounded: true,
        );
        return;
      } catch (error) {
        if (!isConnectionError(error) && error is! TimeoutException) {
          await _forgetOnDenial(
            error,
            org: organizationId,
            branchId: branchId,
            all: all,
          );
          rethrow;
        }
      }
    }
    final companies = await cachedAccess();
    final company = companies?.firstWhereOrNull(
      (row) => row['organization_id'] == organizationId,
    );
    final rows = company == null ? const <Map>[] : selectableBranches(company);
    final branch = rows.firstWhereOrNull((row) => row['id'] == branchId);
    if (!_current ||
        company == null ||
        !companyIsOpen(company) ||
        (all
            ? rows.length < 2 || company['offline_all_denied'] == true
            : branch == null)) {
      throw StateError('Branch has no saved access');
    }
    final previousOrg = BranchScope.organizationId;
    final previousToken = BranchScope.token;
    if (previousOrg != null && previousToken != null && ownsSavedSelection) {
      await _rememberToken(
        previousOrg,
        BranchScope.branchId,
        BranchScope.allMode,
        previousToken,
      );
    }
    final savedToken = await _savedToken(organizationId, branchId, all);
    final Object? permitted = BranchScope.tokenClaims(
      savedToken,
    )?['branch_ids'];
    final token =
        all &&
            (permitted is! List ||
                !const SetEquality().equals(
                  permitted.toSet(),
                  rows.map((row) => row['id']).toSet(),
                ))
        ? null
        : savedToken;
    await BranchScope.save(
      token: token,
      branchId: branchId,
      branchName: branch?['name']?.toString(),
      allMode: all,
      organizationId: organizationId,
      selectionOwner: _owner,
      stillSelected: () => _current && previous == BranchScope.selection,
    );
    await BranchScope.setHasMembership(company['role'] == 'member');
  }

  /// Only reconnect the exact locally selected branch, never a default.
  /// A response that arrives after the user moved is ignored.
  Future<bool> resumeDrawerSelection({
    required bool Function() stillSelected,
  }) async {
    if (!ownsSavedSelection || !BranchScope.awaitingServerSelection) {
      return false;
    }
    final selected = BranchScope.selection;
    final (org, id, all, _) = selected;
    final companies = await cachedAccess();
    if (!stillSelected() ||
        selected != BranchScope.selection ||
        companies?.any(
              (c) =>
                  c['organization_id'] == org &&
                  (all
                      ? selectableBranches(c).length > 1 &&
                            c['offline_all_denied'] != true
                      : selectableBranches(c).any((b) => b['id'] == id)),
            ) !=
            true) {
      return false;
    }
    try {
      await _select(
        organizationId: org,
        branchId: id,
        all: all,
        bounded: true,
        stillSelected: () =>
            stillSelected() &&
            selected == BranchScope.selection &&
            BranchScope.awaitingServerSelection,
      );
      return true;
    } catch (error) {
      if (selected == BranchScope.selection && stillSelected()) {
        await _forgetOnDenial(error, org: org, branchId: id, all: all);
      }
      return false;
    }
  }

  String _tokenKey(String org, String? id, bool all) =>
      '${BranchScope.tokenCachePrefix(_owner!)}${jsonEncode([org, id, all])}';

  bool _matchingToken(String? token, String org, String? id, bool all) {
    final claims = BranchScope.tokenClaims(token);
    return claims != null &&
        claims['typ'] == 'branch_scope' &&
        claims['sub'] == _account &&
        claims['org'] == org &&
        claims['branch'] == id &&
        claims['mode'] == (all ? 'all' : 'branch');
  }

  Future<void> _rememberToken(
    String org,
    String? id,
    bool all,
    String token,
  ) async {
    try {
      final sid = await _sessionId?.call();
      final writer = BranchScope.tokenClaims(token)?['qa_writer_session'];
      if (sid == null ||
          (writer != null && writer != sid) ||
          !_current ||
          !_matchingToken(token, org, id, all))
        return;
      final prefs = await SharedPreferences.getInstance();
      if (!_current) return;
      await prefs.setString(_tokenKey(org, id, all), jsonEncode([sid, token]));
    } catch (_) {
      // A missing local copy must not turn a verified selection into a failure.
    }
  }

  Future<String?> _savedToken(String org, String? id, bool all) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tokenKey(org, id, all));
      if (raw == null) return null;
      final encoded = jsonDecode(raw) as List;
      final sid = await _sessionId?.call();
      final token = encoded[1] as String;
      final exp = BranchScope.tokenClaims(token)?['exp'];
      return sid != null &&
              sid == encoded[0] &&
              _current &&
              _matchingToken(token, org, id, all) &&
              exp is int &&
              exp > DateTime.now().millisecondsSinceEpoch ~/ 1000
          ? token
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _forgetOnDenial(
    Object error, {
    String? org,
    String? branchId,
    bool all = false,
  }) async {
    final owner = _owner;
    final code = error is DioException ? error.response?.statusCode : null;
    if (owner == null || !_current || !const {401, 403, 404}.contains(code)) {
      return;
    }
    if (code == 401 || org == null) {
      await BranchScope.forgetNavigationCache(owner);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey(org, branchId, all));
    final companies = await cachedAccess();
    if (companies != null) {
      await _cacheJson(BranchScope.accessCacheKey(owner), [
        for (final company in companies)
          if (company['organization_id'] != org)
            company
          else if (all)
            {...company, 'offline_all_denied': true}
          else
            {
              ...company,
              'branches': [
                for (final row in selectableBranches(company))
                  if (row['id'] != branchId) row,
              ],
            },
      ]);
    }
  }

  Future<List<Map<String, dynamic>>?> cachedAccess() async {
    final owner = _owner;
    if (owner == null || !_current) return null;
    final rows = await _cachedJson(BranchScope.accessCacheKey(owner));
    return _current ? rows : null;
  }

  Future<List<Map<String, dynamic>>> access() async {
    try {
      final r = await _client.get('/branches/access');
      final d = _data(r);
      final rows = (d is Map ? d['companies'] : null) as List? ?? const [];
      final out = rows
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!_current) return [];
      if (_owner != null) {
        await _cacheJson(BranchScope.accessCacheKey(_owner), out);
      }
      return out;
    } catch (e) {
      if (isConnectionError(e)) {
        final cached = await cachedAccess();
        if (cached != null) return cached;
      }
      await _forgetOnDenial(e);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> invitations() async {
    final r = await _client.get('/branches/invitations');
    final d = _data(r);
    final rows = (d is Map ? d['invitations'] : null) as List? ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<List<Map<String, dynamic>>> sentInvitations() async {
    final r = await _client.get('/branches/invitations/manage');
    final d = _data(r);
    final rows = (d is Map ? d['invitations'] : null) as List? ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> invite({
    required String branchId,
    String? phone,
    String? code,
    bool canTransfer = false,
  }) async {
    final r = await _client.post(
      '/branches/invitations',
      data: {
        'branch_id': branchId,
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
        'can_transfer': canTransfer,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<void> respondInvitation(String id, bool accept) => _client.post(
    '/branches/invitations/$id/respond',
    data: {'accept': accept},
  );

  Future<void> revokeInvitation(String id) =>
      _client.dio.delete('/branches/invitations/$id');

  Future<List<Map<String, dynamic>>> members() async {
    final r = await _client.get('/branches/members');
    final d = _data(r);
    final rows = (d is Map ? d['members'] : null) as List? ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> updateMember(
    String id, {
    List<String>? branchIds,
    bool? allBranches,
    bool? canTransfer,
    Map<String, dynamic>? permissions,
    String? status,
  }) async {
    final data = <String, dynamic>{
      'branch_ids': ?branchIds,
      'all_branches': ?allBranches,
      'can_transfer': ?canTransfer,
      'permissions': ?permissions,
      'status': ?status,
    };

    await _client.dio.patch('/branches/members/$id', data: data);
  }

  Future<Map<String, dynamic>> financialTransfer({
    required String fromBranchId,
    required String toBranchId,
    required String fromAccountId,
    required String toAccountId,
    required num amount,
    num? exchangeRate,
    bool allowNegative = false,
    String? notes,
    String? commandId,
  }) async {
    final local = _local?.call();
    if (local != null) {
      return Map<String, dynamic>.from(
        await local.financialTransfer(
          fromBranchId: fromBranchId,
          toBranchId: toBranchId,
          fromAccountId: fromAccountId,
          toAccountId: toAccountId,
          amount: amount,
          exchangeRate: exchangeRate,
          allowNegative: allowNegative,
          notes: notes,
          commandId: commandId,
        ),
      );
    }
    _requireConnectedTransfer();
    final r = await _client.post(
      '/branches/transfers/financial',
      data: {
        'from_branch_id': fromBranchId,
        'to_branch_id': toBranchId,
        'from_account_id': fromAccountId,
        'to_account_id': toAccountId,
        'amount': amount,
        if (exchangeRate != null) 'exchange_rate': exchangeRate,
        'allow_negative': allowNegative,
        if (notes != null) 'notes': notes,
        'idempotency_key': commandId ?? _key('f'),
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> inventoryTransfer({
    required String fromBranchId,
    required String toBranchId,
    required List<Map<String, dynamic>> items,
    String? notes,
    String? commandId,
  }) async {
    final local = _local?.call();
    if (local != null) {
      return Map<String, dynamic>.from(
        await local.inventoryTransfer(
          fromBranchId: fromBranchId,
          toBranchId: toBranchId,
          items: items,
          notes: notes,
          commandId: commandId,
        ),
      );
    }
    _requireConnectedTransfer();
    final r = await _client.post(
      '/branches/transfers/inventory',
      data: {
        'from_branch_id': fromBranchId,
        'to_branch_id': toBranchId,
        'items': items,
        'notes': notes,
        'idempotency_key': commandId ?? _key('i'),
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> unitConversion({
    required String fromProductId,
    required String toProductId,
    String? fromUnitId,
    String? toBranchId,
    String? fromBranchId,
  }) async {
    final local = _local?.call();
    if (local != null) {
      return Map<String, dynamic>.from(
        await local.unitConversion(
          fromProductId: fromProductId,
          toProductId: toProductId,
          fromUnitId: fromUnitId,
          toBranchId: toBranchId,
          fromBranchId: fromBranchId,
        ),
      );
    }
    _requireConnectedTransfer();
    final r = await _client.get(
      '/branches/transfers/unit-conversion',
      queryParameters: {
        'from_product_id': fromProductId,
        'to_product_id': toProductId,
        if (fromUnitId != null) 'from_unit_id': fromUnitId,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> transferOptions(
    String branchId, {
    String? search,
    bool includeZero = false,
  }) async {
    final local = _local?.call();
    if (local != null) {
      return Map<String, dynamic>.from(
        await local.transferOptions(
          branchId,
          search: search,
          includeZero: includeZero,
        ),
      );
    }
    _requireConnectedTransfer();
    final r = await _client.get(
      '/branches/transfers/options',
      queryParameters: {
        'branch_id': branchId,
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        if (includeZero) 'include_zero': 'true',
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> productMatch({
    required String fromProductId,
    required String toBranchId,
    String? fromBranchId,
  }) async {
    final local = _local?.call();
    if (local != null) {
      return Map<String, dynamic>.from(
        await local.productMatch(
          fromProductId: fromProductId,
          toBranchId: toBranchId,
          fromBranchId: fromBranchId,
        ),
      );
    }
    _requireConnectedTransfer();
    final r = await _client.get(
      '/branches/transfers/product-match',
      queryParameters: {
        'from_product_id': fromProductId,
        'to_branch_id': toBranchId,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<List<Map<String, dynamic>>> transfers({
    String? branchId,
    String? kind,
    int page = 1,
    int perPage = 30,
  }) async {
    final local = _local?.call();
    if (local != null) {
      return [
        for (final row in await local.transfers(kind: kind, branchId: branchId))
          Map<String, dynamic>.from(row),
      ];
    }
    _requireConnectedTransfer();
    final r = await _client.get(
      '/branches/transfers',
      queryParameters: {
        if (branchId != null) 'branch_id': branchId,
        if (kind != null) 'kind': kind,
        'page': page,
        'per_page': perPage,
      },
    );
    final d = _data(r);
    final rows = (d is Map ? d['items'] : null) as List? ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> transfer(String id) async {
    final local = _local?.call();
    if (local != null) {
      return Map<String, dynamic>.from(await local.transfer(id));
    }
    _requireConnectedTransfer();
    final r = await _client.get('/branches/transfers/$id');
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> reverseTransfer(
    String id, {
    bool allowNegative = false,
    List<Map<String, dynamic>>? items,
    String? notes,
    String? commandId,
  }) async {
    final local = _local?.call();
    if (local != null) {
      await local.reverseTransfer(id, commandId: commandId);
      return {'id': id, 'status': 'reversed'};
    }
    _requireConnectedTransfer();
    final r = await _client.post(
      '/branches/transfers/$id/reverse',
      data: {
        'allow_negative': allowNegative,
        if (items != null) 'items': items,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  String _key(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  Future<List<Map<String, dynamic>>> transferBranches() async {
    final local = _local?.call();
    if (local != null) {
      return [
        for (final row in await local.transferBranches())
          Map<String, dynamic>.from(row),
      ];
    }
    _requireConnectedTransfer();
    return access();
  }
}

final branchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) async {
    await BranchScope.load();
    return ref.watch(branchApiProvider).list(archived: true);
  },
);

/// Global branch generation: bumping it recreates every provider inside the
/// Business shell (nested ProviderScope key), so switching branches disposes
/// ALL cached state at once (no page-by-page invalidation, no stale data).
final branchAccessProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(branchApiProvider);
      final companies = ref.watch(connectivityServiceProvider).isOnline
          ? await api.access()
          : await api.cachedAccess() ?? const <Map<String, dynamic>>[];
      final member = companies.any(
        (c) =>
            '${c['role']}' == 'member' &&
            ((c['branches'] as List?)?.isNotEmpty ?? false),
      );
      BranchScope.setHasMembership(member);
      return companies;
    });

/// The drawer can show this account's saved choices while Wi-Fi has no route
/// to the server. A completed server response (including a denial) comes first.
final branchMenuAccessProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final live = ref.watch(branchAccessProvider);
      if (live.hasError && !isConnectionError(live.error!)) return [];
      final rows = live.asData?.value;
      if (rows != null) return rows;
      return await ref.watch(branchApiProvider).cachedAccess() ?? [];
    });

/// True while the branch switch is in flight (shell shows a branded loader).
final branchSwitchingProvider = StateProvider<bool>((ref) => false);

bool workspaceDataEqual(Object? a, Object? b) =>
    const DeepCollectionEquality().equals(a, b);

/// Poll without putting the identity/permission providers into loading state.
Future<void> refreshBranchAccessIfChanged(WidgetRef ref) async {
  final org = BranchScope.organizationId;
  final companies = await ref.read(branchApiProvider).access();
  if (!ref.context.mounted || org != BranchScope.organizationId) return;
  final old = ref.read(branchAccessProvider).valueOrNull;
  if (old != null && !workspaceDataEqual(old, companies)) {
    ref.invalidate(branchAccessProvider);
  }
}
