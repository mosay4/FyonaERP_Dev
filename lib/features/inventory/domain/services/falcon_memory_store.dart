import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';

/// Falcon chat session — IN-MEMORY, process-lifetime storage.
///
/// The conversation is keyed by userId + scope + refId and kept in a
/// process-wide singleton: navigation between pages, app backgrounding and
/// phone lock all keep it intact as long as the app process is alive. When
/// the app is killed / relaunched, memory is empty → a brand-new Falcon
/// session starts. Nothing is ever written to disk for conversations.
class FalconSession {
  final List<Map<String, dynamic>> chat;
  final Map<String, dynamic>? report;
  final String? reportCurrency;
  final DateTime lastActivity;
  const FalconSession({
    required this.chat,
    this.report,
    this.reportCurrency,
    required this.lastActivity,
  });
}

class FalconMemoryStore {
  FalconMemoryStore._();
  static final FalconMemoryStore instance = FalconMemoryStore._();

  final Map<String, FalconSession> _sessions = {};

  String _key(String userId, String scope, String? refId, String? workspace) =>
      jsonEncode([userId.isEmpty ? 'anon' : userId, scope, refId, workspace]);

  FalconSession? get(String userId, String scope, String? refId, {String? workspace}) =>
      _sessions[_key(userId, scope, refId, workspace)];

  void put(String userId, String scope, String? refId, FalconSession s, {String? workspace}) {
    final key = _key(userId, scope, refId, workspace);
    _sessions.remove(key);
    _sessions[key] = s;
    if (_sessions.length > 128) _sessions.remove(_sessions.keys.first);
  }

  /// Housekeeping helper (e.g. a real logout). Not used for TTL expiry —
  /// the store deliberately lives for the whole process lifetime.
  void clear(String userId, String scope, String? refId, {String? workspace}) =>
      _sessions.remove(_key(userId, scope, refId, workspace));

  /// Drops EVERYTHING (app-level logout / account switch).
  void clearAll() => _sessions.clear();
}

/// Provider surface for other features if they ever need the store.
final falconMemoryStoreProvider =
    Provider<FalconMemoryStore>((ref) => FalconMemoryStore.instance);
