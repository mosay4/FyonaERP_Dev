import 'dart:convert';

import 'ledger/personal_ledger.dart';

/// Personal bank account types (جاري checking / توفير savings) — kept ONLY on
/// the device. The user's other devices receive changes through the peer
/// relay (`/peer-relay/self-push`), which deletes them once delivered; the
/// server never stores them. Each entry carries the time it was chosen so
/// devices agree on the latest choice (last writer wins).
///
/// Stored in the signed-in user's encrypted Personal ledger under the same
/// keys the SharedPreferences entries used (moved over once).
class PersonalAccountTypeStore {
  static const typesKey = 'bank_account_types_v3';
  static const _atKey = 'bank_account_types_v3_at';
  static const _pendingKey = 'bank_account_types_relay_pending';
  static const _requestedKey = 'bank_account_types_relay_requested';

  static int Function() now = () => DateTime.now().millisecondsSinceEpoch;

  static Future<Map<String, String>> load() async {
    return _decode(await PersonalLedgerKv.getString(typesKey));
  }

  static Map<String, String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  static Map<String, int> _decodeAt(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, String> types, Map<String, int> at) async {
    await PersonalLedgerKv.setString(typesKey, jsonEncode(types));
    await PersonalLedgerKv.setString(_atKey, jsonEncode(at));
  }

  /// The user chose [type] for [accountId] on this device.
  static Future<void> save(String accountId, String type) async {
    final types = _decode(await PersonalLedgerKv.getString(typesKey));
    final at = _decodeAt(await PersonalLedgerKv.getString(_atKey));
    types[accountId] = type;
    at[accountId] = now();
    await _write(types, at);
    await PersonalLedgerKv.setBool(_pendingKey, true);
  }

  static Future<void> remove(String accountId) async {
    final types = _decode(await PersonalLedgerKv.getString(typesKey));
    final at = _decodeAt(await PersonalLedgerKv.getString(_atKey));
    types.remove(accountId);
    at.remove(accountId);
    await _write(types, at);
  }

  /// What this device sends to the user's other devices.
  static Future<Map<String, dynamic>> snapshot() async {
    final types = _decode(await PersonalLedgerKv.getString(typesKey));
    final at = _decodeAt(await PersonalLedgerKv.getString(_atKey));
    return {
      'types': {
        for (final e in types.entries)
          if (e.value == 'checking' || e.value == 'savings')
            e.key: {'t': e.value, 'at': at[e.key] ?? 0},
      },
    };
  }

  /// Applies a snapshot from another device; newer choices win. Returns
  /// whether anything changed here.
  static Future<bool> merge(Map<String, dynamic> payload) async {
    final incoming = payload['types'];
    if (incoming is! Map) return false;
    final types = _decode(await PersonalLedgerKv.getString(typesKey));
    final at = _decodeAt(await PersonalLedgerKv.getString(_atKey));
    var changed = false;
    incoming.forEach((key, value) {
      if (value is! Map) return;
      final t = value['t']?.toString();
      if (t != 'checking' && t != 'savings') return;
      final when = value['at'] is num ? (value['at'] as num).toInt() : 0;
      final id = key.toString();
      final mine = at[id];
      // Unknown here, or chosen later on the other device.
      if (!types.containsKey(id) || (mine ?? 0) < when) {
        if (types[id] != t) changed = true;
        types[id] = t!;
        at[id] = when;
      }
    });
    if (changed) await _write(types, at);
    return changed;
  }

  static Future<bool> takePending() async {
    final pending = await PersonalLedgerKv.getBool(_pendingKey) ?? false;
    if (pending) await PersonalLedgerKv.setBool(_pendingKey, false);
    return pending;
  }

  static Future<void> markPending() async {
    await PersonalLedgerKv.setBool(_pendingKey, true);
  }

  /// True once per install: ask the user's other devices for their types
  /// (a fresh install / new phone starts empty).
  static Future<bool> takeFirstRequest() async {
    if (await PersonalLedgerKv.getBool(_requestedKey) ?? false) return false;
    await PersonalLedgerKv.setBool(_requestedKey, true);
    return true;
  }

  static Future<void> clearRequested() async {
    await PersonalLedgerKv.setBool(_requestedKey, false);
  }
}
