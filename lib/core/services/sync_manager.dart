import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../di/repository_providers.dart';

class SyncManager {
  final Ref _ref;
  Timer? _timer;
  bool _isSyncing = false;

  SyncManager(this._ref);

  bool get isSyncing => _isSyncing;

  Future<void> startAutoSync({Duration interval = const Duration(seconds: 30)}) async {
    _timer?.cancel();
    await performSync();
    _timer = Timer.periodic(interval, (_) => performSync());
  }

  void stopAutoSync() {
    _timer?.cancel();
    _timer = null;
  }

  Future<SyncResult> performSync() async {
    if (_isSyncing) return SyncResult(success: false, error: 'Already syncing');
    _isSyncing = true;
    try {
      final repo = _ref.read(syncRepositoryProvider);
      final resp = await repo.status();
      return SyncResult(success: resp.success, serverTime: resp.data?['server_time'].toString());
    } catch (e) {
      return SyncResult(success: false, error: e.toString());
    } finally {
      _isSyncing = false;
    }
  }

  Future<SyncResult> pushChanges(List<Map<String, dynamic>> entities) async {
    try {
      final repo = _ref.read(syncRepositoryProvider);
      final resp = await repo.push({'batch_id': DateTime.now().millisecondsSinceEpoch.toString(), 'entities': entities});
      return SyncResult(success: resp.success, data: resp.data);
    } catch (e) {
      return SyncResult(success: false, error: e.toString());
    }
  }

  Future<SyncResult> pullChanges({DateTime? lastSync, List<String>? entityTypes}) async {
    try {
      final repo = _ref.read(syncRepositoryProvider);
      final resp = await repo.pull({'last_sync_at': lastSync?.toIso8601String(), 'entity_types': entityTypes});
      return SyncResult(success: resp.success, data: resp.data);
    } catch (e) {
      return SyncResult(success: false, error: e.toString());
    }
  }

  void dispose() { stopAutoSync(); }
}

class SyncResult {
  final bool success;
  final String? error;
  final dynamic data;
  final String? serverTime;
  SyncResult({required this.success, this.error, this.data, this.serverTime});
}

final syncManagerProvider = Provider<SyncManager>((ref) => SyncManager(ref));
