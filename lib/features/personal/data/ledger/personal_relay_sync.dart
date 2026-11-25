import 'dart:convert';

import 'package:cryptography/cryptography.dart'
    show SecretBoxAuthenticationError;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'personal_relay_crypto.dart';
import 'personal_relay_store.dart';

/// The relay endpoints (`/api/v1/personal-relay`). [post] returns the
/// response's `data` object and throws on any failure.
abstract interface class PersonalRelayTransport {
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body, {
    Duration? receive,
  });
}

/// The relay no longer knows this replica (retired / other user): register
/// again (and rejoin with a snapshot).
final class PersonalRelayForbidden implements Exception {
  const PersonalRelayForbidden();
}

/// One device's conversation with the Personal relay: register, send this
/// device's operations, receive the other devices' operations and apply them
/// in sequence order, acknowledge (the relay then deletes them), and hand
/// snapshots to new devices. Payloads are sealed end to end
/// ([PersonalRelayCrypto]); only the user's devices can read them.
///
/// Everything received is first stored here (parked), then acknowledged,
/// then applied in order — so nothing is lost if the app stops halfway, and
/// operations wait (in order) while a key or a snapshot is missing.
final class PersonalRelaySync {
  PersonalRelaySync({
    required this.store,
    required this.transport,
    required this.namespace,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PersonalRelayStore store;
  final PersonalRelayTransport transport;

  /// Local namespace (`user_id` column) new rows are written under.
  final int namespace;
  final DateTime Function() _clock;

  /// How long a new device waits for a snapshot / the key before it goes on
  /// alone with what it has (the user can still restore a local backup).
  static Duration snapshotWait = const Duration(minutes: 30);
  static Duration keyWait = const Duration(minutes: 30);
  static Duration keyRequestEvery = const Duration(minutes: 10);

  String? _replica;
  bool _serverResync = false;

  /// Set when a snapshot from another device was taken (the caller may then
  /// heal duplicates the two copies had, e.g. cash rows made on both).
  bool snapshotApplied = false;

  int get _nowUs => _clock().toUtc().microsecondsSinceEpoch;

  void forget() => _replica = null;

  Future<String>? _registering;

  /// Registers this replica once (concurrent callers share the call).
  Future<String> ready() {
    final known = _replica;
    if (known != null) return Future.value(known);
    return _registering ??= _register().whenComplete(() => _registering = null);
  }

  Future<String> _register() async {
    final id = await store.replicaId();
    final reg = await transport.post('/register', {'replica_id': id});
    _replica = id;
    var resync = reg['resync_required'] == true;
    // A snapshot stored here before the app stopped: confirm it first.
    if (await _confirmSnapshot()) resync = false;
    _serverResync = resync;
    if ((await store.keyring()).isEmpty) {
      if (!resync) {
        // The user's first device on the relay: it makes the key.
        await store.createDataKey();
      } else {
        await _requestKey(force: true);
      }
    }
    if (resync && await store.resync() == '') await _startResync();
    return id;
  }

  Future<bool> _confirmSnapshot() async {
    if (await store.read('snap_applied') != '1') return false;
    await transport.post('/snapshot/applied', {'replica_id': _replica});
    await store.write('snap_applied', null);
    _serverResync = false;
    return true;
  }

  Future<void> _startResync() async {
    final id = _replica!;
    final r = await transport.post('/snapshot/request', {'replica_id': id});
    if (r['requested'] == true) {
      await store.setResync('waiting', sinceUs: _nowUs);
    } else {
      // No other live device: this one is the only copy.
      _serverResync = false;
      await store.setResync('');
      if ((await store.keyring()).isEmpty) await store.createDataKey();
    }
  }

  Future<void> _requestKey({bool force = false}) async {
    final id = _replica!;
    final last = int.tryParse(await store.read('key_req_us') ?? '') ?? 0;
    if (!force && _nowUs - last < keyRequestEvery.inMicroseconds) return;
    final dev = await store.deviceKeys();
    await transport.post('/push', {
      'replica_id': id,
      'items': [
        {
          'id': const Uuid().v4(),
          'kind': 'ops',
          'payload': PersonalRelayCrypto.keyRequest(replica: id, pub: dev.pub),
        },
      ],
    });
    await store.write('key_req_us', '$_nowUs');
    if (await store.read('key_wait_us') == null) {
      await store.write('key_wait_us', '$_nowUs');
    }
  }

  /// Sends every operation made here. Returns how many were sent. Without
  /// the user's key (new device, not granted yet) they wait here.
  Future<int> push() async {
    final id = await ready();
    final kid = await store.currentKid();
    if (kid == null) return 0;
    final key = (await store.keyring())[kid];
    if (key == null) return 0;
    var sent = 0;
    while (true) {
      final out = await store.unsent(limit: 100);
      if (out.isEmpty) break;
      final items = <Map<String, Object?>>[];
      for (final op in out) {
        final sealed = await PersonalRelayCrypto.seal(
          kid: kid,
          key: key,
          plain: utf8.encode(op.payload),
          context: 'op:${op.id}',
        );
        items.add({
          'id': op.id,
          'kind': 'ops',
          'payload': base64Encode(sealed),
        });
      }
      final reply = await transport.post('/push', {
        'replica_id': id,
        'items': items,
      });
      await store.pushed({
        for (final item in reply['items'] as List? ?? const [])
          if (item is Map && item['seq'] is num)
            '${item['id']}': (item['seq'] as num).toInt(),
      });
      sent += out.length;
      if (out.length < 100) break;
    }
    return sent;
  }

  /// One receive round. [quiet]: nothing more waits on the relay.
  /// [changed]: rows of this device changed (screens should re-read).
  Future<({bool quiet, bool changed})> receive({int wait = 0}) async {
    final id = await ready();
    final batch = await transport.post('/pull', {
      'replica_id': id,
      'wait': wait,
    }, receive: Duration(seconds: wait + 20));
    final items = [
      for (final raw in batch['items'] as List? ?? const [])
        if (raw is Map) Map<String, Object?>.from(raw),
    ];
    _serverResync =
        batch['resync_required'] == true &&
        await store.read('snap_applied') != '1';
    if (_serverResync && await store.resync() == '') await _startResync();
    final ack = <String>[];
    final park = <PersonalRelayParked>[];
    final requests = <(String, String)>[];
    var keysChanged = false;
    for (final item in items) {
      final itemId = '${item['id']}';
      final Uint8List bytes;
      try {
        bytes = base64Decode('${item['payload']}');
      } catch (_) {
        ack.add(itemId);
        continue;
      }
      final author = item['replica_id']?.toString();
      switch (item['kind']) {
        case 'snapshot_request':
          final target = _json(bytes)?['replica_id']?.toString();
          if (target == null || target == id) {
            ack.add(itemId);
          } else {
            requests.add((itemId, target));
          }
        case 'snapshot':
          park.add((
            id: itemId,
            seq: null,
            kind: 'snapshot',
            author: author,
            payload: bytes,
          ));
          ack.add(itemId);
        default:
          if (PersonalRelayCrypto.isEnvelope(bytes)) {
            park.add((
              id: itemId,
              seq: (item['seq'] as num?)?.toInt(),
              kind: 'ops',
              author: author,
              payload: bytes,
            ));
          } else {
            final msg = _json(bytes);
            try {
              if (msg?['fpr'] == 'key_request') await _grant(msg!, author);
              if (msg?['fpr'] == 'key_grant' && await _takeGrant(msg!)) {
                keysChanged = true;
              }
            } catch (e) {
              debugPrint('PersonalRelay: key message skipped: $e');
            }
          }
          ack.add(itemId);
      }
    }
    // Stored here before the relay may forget it.
    if (park.isNotEmpty) await store.park(park);
    var changed = await drain();
    final drained = batch['drained'] == true;
    for (final (itemId, target) in requests) {
      // A copy is complete only with nothing unsent and nothing waiting.
      if (!drained || await store.hasParked()) continue;
      await push();
      if (await _serve(id, target)) ack.add(itemId);
    }
    for (var i = 0; i < ack.length; i += 200) {
      await transport.post('/ack', {
        'replica_id': id,
        'ids': ack.sublist(i, i + 200 > ack.length ? ack.length : i + 200),
      });
    }
    changed = await _maintain() || changed;
    return (quiet: drained && items.isEmpty && !keysChanged, changed: changed);
  }

  Future<bool> _serve(String id, String target) async {
    final kid = await store.currentKid();
    final key = kid == null ? null : (await store.keyring())[kid];
    if (key == null) return false;
    final snap = await store.snapshot();
    if (snap == null) return false;
    final sealed = await PersonalRelayCrypto.seal(
      kid: kid!,
      key: key,
      plain: utf8.encode(jsonEncode(snap)),
      context: 'snapshot:$target',
    );
    await transport.post('/snapshot/serve', {
      'replica_id': id,
      'target': target,
      'payload': base64Encode(sealed),
    });
    return true;
  }

  Future<void> _grant(Map msg, String? author) async {
    final requester = msg['replica']?.toString();
    // Only for the replica that really sent it, never for this one.
    if (requester == null || requester != author || requester == _replica) {
      return;
    }
    final ring = await store.keyring();
    if (ring.isEmpty) return;
    final dev = await store.deviceKeys();
    final grant = await PersonalRelayCrypto.keyGrant(
      to: requester,
      toPub: base64Decode('${msg['pub']}'),
      myPriv: dev.priv,
      myPub: dev.pub,
      keyring: ring,
    );
    await transport.post('/push', {
      'replica_id': _replica,
      'items': [
        {'id': const Uuid().v4(), 'kind': 'ops', 'payload': grant},
      ],
    });
  }

  Future<bool> _takeGrant(Map msg) async {
    final dev = await store.deviceKeys();
    final ring = await PersonalRelayCrypto.openGrant(
      grant: msg,
      me: _replica!,
      myPriv: dev.priv,
      myPub: dev.pub,
    );
    if (ring == null || ring.isEmpty) return false;
    final have = await store.keyring();
    if (ring.keys.every(have.containsKey)) return false;
    await store.addKeys(ring);
    return true;
  }

  /// null: the key is not here yet. Throws [_Unreadable] when the bytes
  /// were changed / are not ours.
  Future<Uint8List?> _open(Uint8List bytes, String context) async {
    try {
      return await PersonalRelayCrypto.open(
        bytes: bytes,
        keyring: await store.keyring(),
        context: context,
      );
    } on SecretBoxAuthenticationError {
      throw const _Unreadable();
    } on FormatException {
      throw const _Unreadable();
    }
  }

  /// Applies what waits here, in order, as far as keys and snapshots allow.
  Future<bool> drain() async {
    var changed = false;
    final id = _replica ?? await store.replicaId();
    for (final p in await store.parked()) {
      Uint8List? plain;
      try {
        plain = await _open(
          p.payload,
          p.kind == 'snapshot' ? 'snapshot:$id' : 'op:${p.id}',
        );
      } on _Unreadable {
        debugPrint('PersonalRelay: dropped unreadable ${p.kind} ${p.id}');
        await store.unpark(p.id);
        continue;
      }
      if (p.kind == 'snapshot') {
        if (plain == null) {
          if (_replica != null) await _requestKey();
          return changed;
        }
        final snap = _json(plain);
        final fill = await store.resync() != 'waiting';
        await store.unpark(p.id);
        if (snap != null) {
          await store.applySnapshot(snap, namespace: namespace, fill: fill);
          await store.write('snap_applied', '1');
          snapshotApplied = true;
          changed = true;
        }
        continue;
      }
      // Operations wait (in order) for the snapshot a new device asked for.
      if (await store.resync() == 'waiting') return changed;
      if (await store.isApplied(p.id, p.seq)) {
        await store.unpark(p.id);
        continue;
      }
      if (plain == null) {
        if (_replica != null) await _requestKey();
        return changed;
      }
      final payload = _json(plain);
      if (payload != null &&
          await store.applyOp(
            opId: p.id,
            seq: p.seq,
            payload: payload,
            namespace: namespace,
          )) {
        changed = true;
      }
      await store.unpark(p.id);
    }
    return changed;
  }

  /// Timeouts and deferred confirmations. Returns whether rows changed.
  Future<bool> _maintain() async {
    final id = _replica;
    if (id == null) return false;
    await _confirmSnapshot();
    final state = await store.resync();
    final since = await store.resyncSinceUs();
    var changed = false;
    if (state == 'waiting' && _nowUs - since > snapshotWait.inMicroseconds) {
      // No device answered: go on with what is here (local data is kept;
      // the user can restore a local backup).
      await store.setResync('gave_up', sinceUs: _nowUs);
      changed = await drain();
    } else if (state == 'gave_up' &&
        _serverResync &&
        _nowUs - since > snapshotWait.inMicroseconds) {
      // Ask again now and then, without waiting: a late snapshot only fills
      // in what is missing here.
      await store.setResync('gave_up', sinceUs: _nowUs);
      await transport.post('/snapshot/request', {'replica_id': id});
    }
    if ((await store.keyring()).isEmpty) {
      final waitSince =
          int.tryParse(await store.read('key_wait_us') ?? '') ?? _nowUs;
      if (_nowUs - waitSince > keyWait.inMicroseconds) {
        // Nobody holds the key (other devices gone): make one. Devices that
        // come back exchange keys when they meet each other's operations.
        await store.createDataKey();
      } else {
        await _requestKey();
      }
    }
    return changed;
  }

  static Map<String, dynamic>? _json(List<int> bytes) {
    try {
      final v = jsonDecode(utf8.decode(bytes));
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }
}

final class _Unreadable implements Exception {
  const _Unreadable();
}
