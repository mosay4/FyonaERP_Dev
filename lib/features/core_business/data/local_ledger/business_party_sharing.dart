import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/config/directory_pilot_build.dart';
import '../local_directory/directory_database.dart';
import '../local_directory/directory_party.dart';
import '../local_directory/directory_pilot.dart';
import '../local_directory/directory_scope.dart';
import 'business_relay_identity.dart';

/// Only this transport can publish a device party. The opaque party key and
/// operation IDs below are disjoint from the local and legacy identities.
final class BusinessPartySharing {
  BusinessPartySharing(
    this._http,
    this._store,
    this.scope,
    this._selected,
    this._token,
    this._can,
    this._online,
    this._changed,
    this._identity,
  );

  final Dio _http;
  final DirectoryPilotStore _store;
  final DirectoryAccess scope;
  final DirectoryAccess? Function() _selected;
  final String? Function() _token;
  final bool Function(String) _can;
  final bool Function() _online;
  final void Function() _changed;
  final Future<BusinessRelayIdentity?> Function() _identity;
  final _cancel = CancelToken();
  final _sync = Lock();

  void dispose() => _cancel.cancel();

  bool get _current =>
      !_cancel.isCancelled &&
      _selected()?.financialCutover == true &&
      sameDirectoryScope(scope, _selected());

  bool allows(DirectoryPartyReference party, String action) =>
      _current &&
      sameDirectoryScope(scope, party.scope) &&
      _can('${party.kind.name}s.$action');

  Future<T> _db<T>(
    Set<BusinessLedgerAction> actions,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess) f, {
    bool Function()? stillAllowed,
  }) async {
    final access = BusinessLedgerAccess(scope, actions);
    bool allowed() => _current && (stillAllowed?.call() ?? true);
    final result = await _store.withLedger(
      access,
      () => allowed() ? _selected() : null,
      (db) => f(db, access),
    );
    if (!allowed()) throw const DirectoryAccessDenied();
    return result;
  }

  static const _base = '/business/party-sharing';
  static const _access = {BusinessLedgerAction.sharePartyDebt};

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    required bool Function() allowed,
  }) async {
    if (!_current ||
        !allowed() ||
        !_online() ||
        scope.workspace.server != DirectoryPilotBuild.baseUrl) {
      throw const DirectoryAccessDenied();
    }
    final auth = await _identity();
    final token = _token();
    if (!_current ||
        !allowed() ||
        !_online() ||
        token == null ||
        auth == null) {
      throw const DirectoryAccessDenied();
    }
    // Immutable credentials for this attempt; no global refresh or branch
    // fallback can replay the request under a different session.
    final response = await _http.request<Map<String, dynamic>>(
      '${scope.workspace.server}$_base$path',
      data: body,
      cancelToken: _cancel,
      options: Options(
        method: method,
        followRedirects: false,
        headers: {
          'Authorization': 'Bearer ${auth.accessToken}',
          'X-Branch-Token': token,
        },
      ),
    );
    if ((await _identity())?.sessionId != auth.sessionId) {
      throw const DirectoryAccessDenied();
    }
    if (!_current || !allowed()) throw const DirectoryAccessDenied();
    final data = response.data?['data'];
    if (data is! Map)
      throw const FormatException('Invalid party share response');
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> lookup(
    DirectoryPartyReference party,
    Map<String, dynamic> contact,
  ) => _send(
    'POST',
    '/lookup',
    body: {...contact, 'kind': party.kind.name},
    allowed: () => allows(party, 'edit'),
  );

  Future<void> invite(
    DirectoryPartyReference party,
    Map<String, dynamic> contact,
  ) => _sync.synchronized(() async {
    bool allowed() => allows(party, 'edit') && _can('debts.details');
    final key = await _db(
      _access,
      (db, grant) => db.trackShare(grant, party),
      stillAllowed: allowed,
    );
    final status = await _send(
      'POST',
      '/${party.kind.name}/$key/invite',
      body: contact,
      allowed: allowed,
    );
    await _cache(key, status, null, allowed);
  });

  Future<Map<String, dynamic>> cachedStatus(
    DirectoryPartyReference party,
  ) async {
    if (!allows(party, 'details')) return const {};
    final rows = await _db(
      _access,
      (db, grant) => db.trackedShares(grant, party: party),
      stillAllowed: () => allows(party, 'details'),
    );
    return _cached(rows.singleOrNull?['status_json']);
  }

  static Map<String, dynamic> _cached(Object? json) =>
      json is String ? Map<String, dynamic>.from(jsonDecode(json) as Map) : {};

  Future<void> _cache(
    String key,
    Map<String, dynamic> status,
    String? hash,
    bool Function() allowed,
  ) async {
    if (await _db(
      _access,
      (db, grant) => db.saveShareStatus(grant, key, status, hash),
      stillAllowed: allowed,
    )) {
      if (_current) _changed();
    }
  }

  /// Best effort, outside every local save. Pending invitations never publish
  /// finances. An offline deletion is durable as a tombstone and revokes the
  /// sharing grant as soon as this Business scope reconnects.
  Future<void> refresh() async {
    if (!_current || !_online() || _sync.locked) return;
    await _sync.synchronized(() async {
      if (!_current || !_online()) return;
      final targets = await _db(
        _access,
        (db, grant) => db.trackedShares(grant, forTransport: true),
      );
      for (final target in targets) {
        if (!_current || !_online()) return;
        try {
          await _refreshTarget(target);
        } on DioException {
          // Retain the tracked key; an acknowledgement can be lost after
          // commit. A later run reads status and the latest local projection.
        } on DirectoryAccessDenied {
          continue;
        } on DirectoryPartyNotFound {
          continue;
        }
      }
    });
  }

  Future<void> _refreshTarget(Map<String, Object?> target) async {
    final kind = DirectoryPartyKind.values.byName(target['kind'] as String);
    final party = DirectoryPartyReference(
      scope: scope,
      kind: kind,
      id: target['party_id'] as String,
    );
    final key = target['party_key'] as String;
    final path = '/${kind.name}/$key';
    final cached = _cached(target['status_json']);
    if (target['deleted_us'] != null) {
      if (cached['status'] == 'revoked') return;
      bool mayRevoke() => allows(party, 'delete');
      final status = await _send('DELETE', path, allowed: mayRevoke);
      await _cache(key, status, null, mayRevoke);
      return;
    }
    bool canRead() => allows(party, 'details');
    bool canPublish() =>
        canRead() && allows(party, 'edit') && _can('debts.details');
    final status = await _send('GET', path, allowed: canRead);
    if (status['status'] != 'accepted' || !canPublish()) {
      await _cache(key, status, null, canRead);
      return;
    }
    final rows = await _db(
      {BusinessLedgerAction.readDebt},
      (db, grant) => db.debts(grant, party),
      stillAllowed: canPublish,
    );
    final totals = <String, (int, int)>{};
    for (final r in rows) {
      final currency = r['currency'] as String;
      final old = totals[currency] ?? (0, 0);
      totals[currency] = (
        old.$1 + (r['remaining_minor'] as int),
        old.$2 + (r['paid_minor'] as int),
      );
    }
    final snapshot = {
      'debts': [
        for (final e in totals.entries)
          {
            'currency': e.key,
            'remaining_minor': e.value.$1,
            'paid_minor': e.value.$2,
          },
      ],
      'operations': [
        for (final r in rows.take(200))
          {
            'id': const Uuid().v5(key, 'fyona.shared-operation.v1:${r['id']}'),
            'number': r['number'],
            'date': r['invoice_date'],
            for (final field in [
              'currency',
              'total_minor',
              'remaining_minor',
              'paid_minor',
            ])
              field: r[field],
          },
      ],
    };
    final hash = sha256.convert(utf8.encode(jsonEncode(snapshot))).toString();
    if (cached['generation'] == status['generation'] &&
        cached['revision'] == status['revision'] &&
        target['snapshot_hash'] == hash)
      return;
    final saved = await _send(
      'PUT',
      '$path/snapshot',
      body: {
        ...snapshot,
        'link_id': status['id'],
        'generation': status['generation'],
        'revision': status['revision'],
      },
      allowed: canPublish,
    );
    await _cache(key, saved, hash, canPublish);
  }
}
