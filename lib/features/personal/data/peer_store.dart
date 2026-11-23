import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

/// What a linked merchant/party relationship keeps on this device: the
/// merchant's latest debt copy (customer side), the conversation history, and
/// chat messages written here that are still on their way. Everything works
/// offline; the peer relay only carries changes and deletes them on delivery.
class PeerStore {
  PeerStore._(this._userId);
  static final _instances = <String, PeerStore>{};
  factory PeerStore.of(String userId) =>
      _instances.putIfAbsent(userId, () => PeerStore._(userId));

  final String _userId;
  final _lock = Lock();

  /// One id per install, shared by Business and Personal.
  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('peer_device_id_v1');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('peer_device_id_v1', id);
    }
    return id;
  }

  Future<File> _file(String name) async {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/peer/$_userId',
    );
    await dir.create(recursive: true);
    return File('${dir.path}/$name.json');
  }

  Future<Object?> _readJson(String name) async {
    try {
      final file = await _file(name);
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(String name, Object? value) async {
    final file = await _file(name);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(file.path);
  }

  // ── debts (customer side) ────────────────────────────────────────────────

  Future<Map<String, dynamic>?> debtSnapshot(String linkId) async {
    final raw = await _readJson('debt_$linkId');
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  Future<void> saveDebtSnapshot(String linkId, Map<String, dynamic> snapshot) =>
      _lock.synchronized(() async {
        final previous = await debtSnapshot(linkId);
        // A late, older copy never replaces a newer one.
        final prevAt = previous?['published_us'] as int? ?? 0;
        final at = snapshot['published_us'] as int? ?? 0;
        if (previous != null && at < prevAt) return;
        await _writeJson('debt_$linkId', snapshot);
      });

  // ── chat history and outbox ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> chatHistory(String linkId) async {
    final raw = await _readJson('chat_$linkId');
    return [
      for (final m in raw is List ? raw : const [])
        if (m is Map) Map<String, dynamic>.from(m),
    ];
  }

  /// Merge messages (by server id, or client id for our own) into history.
  Future<List<Map<String, dynamic>>> mergeChat(
    String linkId,
    Iterable<Map<String, dynamic>> messages,
  ) => _lock.synchronized(() async {
    final history = await chatHistory(linkId);
    String key(Map m) => '${m['client_id'] ?? m['client_message_id'] ?? m['id']}';
    final byKey = {for (final m in history) key(m): m};
    for (final m in messages) {
      final k = key(m);
      byKey[k] = {...?byKey[k], ...m};
      // A server id for a message first known by its client id.
      if (m['id'] != null && m['client_id'] != null) byKey.remove('${m['id']}');
    }
    final merged = byKey.values.toList()
      ..sort((a, b) => '${a['created_at'] ?? ''}'.compareTo('${b['created_at'] ?? ''}'));
    // Keep the device copy bounded (newest 5,000 per conversation).
    final kept = merged.length > 5000 ? merged.sublist(merged.length - 5000) : merged;
    await _writeJson('chat_$linkId', kept);
    return kept;
  });

  Future<List<Map<String, dynamic>>> chatOutbox() async {
    final raw = await _readJson('chat_outbox');
    return [
      for (final m in raw is List ? raw : const [])
        if (m is Map) Map<String, dynamic>.from(m),
    ];
  }

  Future<void> queueChat(Map<String, dynamic> request) => _lock.synchronized(() async {
    final box = await chatOutbox();
    if (box.any((m) => m['client_id'] == request['client_id'])) return;
    await _writeJson('chat_outbox', [...box, request]);
  });

  Future<void> sentChat(String clientId) => _lock.synchronized(() async {
    final box = await chatOutbox();
    await _writeJson('chat_outbox', [
      for (final m in box)
        if (m['client_id'] != clientId) m,
    ]);
  });
}

/// The customer's view of a merchant's debts, computed on the device from the
/// merchant's latest copy — the same shapes the server used to return.
abstract final class PeerDebtViews {
  static String _money(Object? minor) {
    final v = (minor as num?)?.toInt() ?? 0;
    final sign = v < 0 ? '-' : '';
    final a = v.abs();
    return '$sign${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
  }

  static List<Map<String, dynamic>> debtRows(Map<String, dynamic> snapshot) => [
    for (final d in (snapshot['debts'] as List? ?? const []).whereType<Map>())
      if ((d['remaining_minor'] as num? ?? 0) != 0)
        {'currency': d['currency'], 'debt': _money(d['remaining_minor'])},
  ];

  static List<Map<String, dynamic>> operations(
    Map<String, dynamic> snapshot,
    String kind, {
    String? dateFrom,
    String? dateTo,
  }) => [
    for (final op in (snapshot['operations'] as List? ?? const []).whereType<Map>())
      if (!(dateFrom != null && '${op['date']}'.compareTo(dateFrom) < 0) &&
          !(dateTo != null && '${op['date']}'.compareTo(dateTo) > 0))
        {
          'id': op['id'],
          'number': op['number'],
          'date': op['date'],
          'currency': op['currency'],
          'type': kind == 'customer' ? 'sale' : 'purchase',
          'total': _money(op['total_minor']),
          'paid': _money(op['paid_minor']),
          'remaining': _money(op['remaining_minor']),
          'status': (op['remaining_minor'] as num? ?? 0) == 0
              ? 'paid'
              : (op['paid_minor'] as num? ?? 0) != 0
              ? 'partial'
              : 'open',
          'group_id': null,
        },
  ];

  static Map<String, dynamic> overview(
    Map<String, dynamic> snapshot,
    String linkId, {
    String? displayCurrency,
    String? dateFrom,
    String? dateTo,
    double? Function(String from, String to)? rate,
  }) {
    final kind = '${snapshot['kind'] ?? 'customer'}';
    final individual = operations(snapshot, kind, dateFrom: dateFrom, dateTo: dateTo);
    final remaining = <String, int>{}, paid = <String, int>{};
    int minor(Object? s) => ((double.tryParse('$s') ?? 0) * 100).round();
    if (dateFrom != null || dateTo != null) {
      for (final op in individual) {
        final c = '${op['currency']}';
        remaining[c] = (remaining[c] ?? 0) + minor(op['remaining']);
        paid[c] = (paid[c] ?? 0) + minor(op['paid']);
      }
    } else {
      for (final d in (snapshot['debts'] as List? ?? const []).whereType<Map>()) {
        final c = '${d['currency']}';
        remaining[c] = (remaining[c] ?? 0) + ((d['remaining_minor'] as num?)?.toInt() ?? 0);
        paid[c] = (paid[c] ?? 0) + ((d['paid_minor'] as num?)?.toInt() ?? 0);
      }
    }
    final display = (displayCurrency ?? (remaining.keys.isEmpty ? 'SAR' : remaining.keys.first))
        .toUpperCase();
    final keys = remaining.keys.toList()..sort();
    final original = Map<String, int>.from(remaining);
    // Other currencies are valued with the exchange rates saved on this
    // device; only a currency with no rate at all stays out of the total.
    final gaps = <String>[];
    var shownRemaining = remaining[display] ?? 0, shownPaid = paid[display] ?? 0;
    for (final c in ({...remaining.keys, ...paid.keys}.toList()..sort())) {
      if (c == display || ((remaining[c] ?? 0) == 0 && (paid[c] ?? 0) == 0)) continue;
      final r = rate?.call(c, display);
      if (r == null || !r.isFinite || r <= 0) {
        gaps.add(c);
        continue;
      }
      shownRemaining += ((remaining[c] ?? 0) * r).round();
      shownPaid += ((paid[c] ?? 0) * r).round();
    }
    remaining[display] = shownRemaining;
    paid[display] = shownPaid;
    final ready = gaps.isEmpty;
    return {
      'link_id': linkId,
      'kind': kind,
      'display_currency': display,
      'published_at': snapshot['published_at'],
      'display_total': ready ? _money(remaining[display] ?? 0) : null,
      'paid_total': ready ? _money(paid[display] ?? 0) : null,
      'remaining_total': ready ? _money(remaining[display] ?? 0) : null,
      'grand_total': ready ? _money((remaining[display] ?? 0) + (paid[display] ?? 0)) : null,
      'fx_missing': gaps,
      'rates': const [],
      'groups': const [],
      'per_currency': [
        for (final c in keys)
          if ((original[c] ?? 0) != 0) {'currency': c, 'total': _money(original[c])},
      ],
      'individual': individual,
      'operations': individual,
    };
  }
}
