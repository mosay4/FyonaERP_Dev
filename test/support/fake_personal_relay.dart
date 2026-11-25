import 'dart:convert';

import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_sync.dart';

/// In-memory stand-in for `/api/v1/personal-relay` with the same contract
/// as backend/app/domain/services/personal_relay.py (per-user sequence,
/// inbox per other replica, delete on last ack keeping an id/seq tombstone,
/// control items first, snapshot request/serve/applied).
final class FakePersonalRelay {
  final _replicas = <String, ({bool resync, bool retired})>{};
  final _ops = <String, _Op>{};
  final _inbox = <String, Set<String>>{};
  final _delivered = <String, int>{};
  var _seq = 0;

  /// Every payload byte the server ever stored (privacy assertions).
  final stored = <List<int>>[];

  int get head => _seq;

  PersonalRelayTransport client(String name) => _Client(this, name);

  void retire(String replica) =>
      _replicas[replica] = (resync: _replicas[replica]!.resync, retired: true);

  void expire(String replica) {
    // Retention ran out for this replica: what waited for it is gone.
    _inbox[replica]?.clear();
    _replicas[replica] = (resync: true, retired: false);
  }

  List<String> _destinations(String exclude) => [
    for (final e in _replicas.entries)
      if (!e.value.retired && e.key != exclude) e.key,
  ];

  List<int> _payload(Object? value) {
    if (value is String) return base64Decode(value);
    return utf8.encode(jsonEncode(value));
  }

  void _forgetIfDone(String id) {
    if (_inbox.values.any((s) => s.contains(id))) return;
    final op = _ops.remove(id);
    if (op?.seq != null) _delivered[id] = op!.seq!;
  }

  Map<String, dynamic> handle(String path, Map<String, Object?> body) {
    final me = '${body['replica_id']}';
    if (path == '/register') {
      final known = _replicas[me];
      final resync = known == null
          ? _destinations(me).isNotEmpty
          : known.resync || known.retired;
      _replicas[me] = (resync: resync, retired: false);
      _inbox.putIfAbsent(me, () => <String>{});
      return {'replica_id': me, 'resync_required': resync, 'head': _seq};
    }
    final self = _replicas[me];
    if (self == null || self.retired) throw const PersonalRelayForbidden();
    switch (path) {
      case '/push':
        final out = <Map<String, Object?>>[];
        for (final raw in body['items'] as List) {
          final item = raw as Map;
          final id = '${item['id']}';
          final seen = _ops[id]?.seq ?? _delivered[id];
          if (seen != null) {
            out.add({'id': id, 'seq': seen});
            continue;
          }
          final bytes = _payload(item['payload']);
          stored.add(bytes);
          final seq = ++_seq;
          final audience = _destinations(me);
          if (audience.isEmpty) {
            _delivered[id] = seq;
          } else {
            _ops[id] = _Op(id, seq, 'ops', me, bytes);
            for (final r in audience) {
              _inbox[r]!.add(id);
            }
          }
          out.add({'id': id, 'seq': seq});
        }
        return {'items': out};
      case '/pull':
        final waiting = [
          for (final id in _inbox[me]!)
            if (_ops[id] != null) _ops[id]!,
        ]..sort((a, b) {
            if ((a.seq == null) != (b.seq == null)) return a.seq == null ? -1 : 1;
            return (a.seq ?? 0).compareTo(b.seq ?? 0);
          });
        final limit = (body['limit'] as int?) ?? 200;
        final rows = waiting.take(limit).toList();
        return {
          'items': [
            for (final o in rows)
              {
                'id': o.id,
                'seq': o.seq,
                'kind': o.kind,
                'replica_id': o.author,
                'payload': base64Encode(o.payload),
              },
          ],
          'drained': waiting.length <= rows.length,
          'head': _seq,
          'resync_required': self.resync,
        };
      case '/ack':
        var purged = 0;
        for (final id in (body['ids'] as List).map((e) => '$e')) {
          _inbox[me]!.remove(id);
          final had = _ops.containsKey(id);
          _forgetIfDone(id);
          if (had && !_ops.containsKey(id)) purged++;
        }
        return {'purged': purged};
      case '/snapshot/request':
        final audience = _destinations(me);
        if (audience.isEmpty) {
          _replicas[me] = (resync: false, retired: false);
          return {'requested': false, 'resync_required': false};
        }
        _dropRequests(me);
        final id = 'req-$me-$_seq-${_ops.length}';
        _ops[id] = _Op(id, null, 'snapshot_request', me,
            utf8.encode(jsonEncode({'replica_id': me})));
        for (final r in audience) {
          _inbox[r]!.add(id);
        }
        _replicas[me] = (resync: true, retired: false);
        return {'requested': true, 'resync_required': true};
      case '/snapshot/serve':
        final target = '${body['target']}';
        final waiting = _replicas[target];
        if (target == me || waiting == null || waiting.retired || !waiting.resync) {
          return {'sent': false};
        }
        if (_inbox[target]!.any((id) => _ops[id]?.kind == 'snapshot')) {
          return {'sent': false};
        }
        _dropRequests(target);
        final bytes = _payload(body['payload']);
        stored.add(bytes);
        final id = 'snap-$target-${_ops.length}-$_seq';
        _ops[id] = _Op(id, null, 'snapshot', me, bytes);
        _inbox[target]!.add(id);
        return {'sent': true};
      case '/snapshot/applied':
        for (final id in [..._inbox[me]!]) {
          if (_ops[id]?.kind == 'snapshot') {
            _inbox[me]!.remove(id);
            _ops.remove(id);
          }
        }
        _dropRequests(me);
        _replicas[me] = (resync: false, retired: false);
        return {};
    }
    throw StateError('unknown path $path');
  }

  void _dropRequests(String requester) {
    for (final o in [..._ops.values]) {
      if (o.kind == 'snapshot_request' && o.author == requester) {
        _ops.remove(o.id);
        for (final s in _inbox.values) {
          s.remove(o.id);
        }
      }
    }
  }
}

final class _Op {
  _Op(this.id, this.seq, this.kind, this.author, this.payload);
  final String id;
  final int? seq;
  final String kind;
  final String author;
  final List<int> payload;
}

final class _Client implements PersonalRelayTransport {
  _Client(this.relay, this.name);
  final FakePersonalRelay relay;
  final String name;

  /// Off: every call fails like a dropped connection.
  bool online = true;
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body, {
    Duration? receive,
  }) async {
    if (!online) throw StateError('offline');
    calls.add(path);
    // JSON round trip: exactly what crosses the wire.
    final wire = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    return jsonDecode(jsonEncode(relay.handle(path, wire))) as Map<String, dynamic>;
  }
}

/// Test access to the fake client's switches.
extension FakePersonalRelayClient on PersonalRelayTransport {
  set online(bool value) => (this as _Client).online = value;
  List<String> get calls => (this as _Client).calls;
}
