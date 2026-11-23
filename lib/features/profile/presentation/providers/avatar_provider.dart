import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/network/dio_provider.dart' show apiClientProvider;

/// Avatar reconcile decision (pure, unit-tested).
///
/// - download: server has a picture we never synced → fetch it.
/// - clearLocal: a FRESH fetch proves the picture was removed elsewhere.
/// - retryDelete: our own offline delete never landed (tombstone) and the
///   server still holds that exact picture → retry the delete.
/// - none: in sync, offline-unknown, or a newer server picture that wins
///   over our tombstone (uploaded elsewhere after our delete).
enum AvatarSyncAction { none, download, clearLocal, retryDelete }

AvatarSyncAction avatarSyncDecision({
  required String? serverRel,
  required String? knownRel,
  required bool fresh,
}) {
  const tomb = 'DELETED:';
  final tombstoned = (knownRel ?? '').startsWith(tomb);
  if (serverRel == null || serverRel.isEmpty) {
    if (!fresh) return AvatarSyncAction.none;
    if (tombstoned) return AvatarSyncAction.retryDelete;
    if (knownRel != null && knownRel.isNotEmpty) {
      return AvatarSyncAction.clearLocal;
    }
    return AvatarSyncAction.none;
  }
  if (tombstoned) {
    final deletedUrl = knownRel!.substring(tomb.length);
    if (deletedUrl.isNotEmpty && serverRel == deletedUrl) {
      return AvatarSyncAction.retryDelete;
    }
    return AvatarSyncAction.download;
  }
  if (serverRel == knownRel) return AvatarSyncAction.none;
  return AvatarSyncAction.download;
}

String avatarServerKey(String userId) => 'profile_avatar_server_url_$userId';

/// Tombstone prefix marking a locally-deleted picture whose server delete
/// never landed yet: `DELETED:<server-url-at-delete-time>`.
const avatarDeletedMark = 'DELETED:';

/// Applies one server avatar URL (from a push event or a profile refresh):
/// downloads it when newer than what we hold, updates the local file +
/// last-synced marker. Returns true when the visible picture changed.
/// Never uploads, never deletes server state, never throws.
Future<bool> syncAvatarFromUrl(
  Ref ref, {
  required String userId,
  required String serverRel,
  required String absoluteUrl,
  Dio? dioOverride,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final knownRel = prefs.getString(avatarServerKey(userId));
    final action = avatarSyncDecision(
        serverRel: serverRel, knownRel: knownRel, fresh: true);
    if (action != AvatarSyncAction.download) return false;
    final dio = dioOverride ?? ref.read(apiClientProvider).dio;
    final resp = await dio.get<List<int>>(absoluteUrl,
        options: Options(responseType: ResponseType.bytes));
    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) return false;
    await ref
        .read(avatarProvider.notifier)
        .save(Uint8List.fromList(bytes));
    await prefs.setString(avatarServerKey(userId), serverRel);
    return true;
  } catch (_) {
    return false;
  }
}

class AvatarNotifier extends StateNotifier<Uint8List?> {
  String? _currentUserId;

  AvatarNotifier() : super(null);

  String _pathKey({String? userId}) =>
      userId != null ? 'profile_avatar_path_$userId' : 'profile_avatar_path';

  Future<String> _avatarDir() async {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/avatars');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  String _filePath(String dir) => '$dir/profile_${_currentUserId ?? 'unknown'}.jpg';

  Future<void> load({String? userId}) async {
    _currentUserId = userId;
    if (userId == null) { state = null; return; }
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(_pathKey(userId: userId));
      if (path != null && await File(path).exists()) {
        state = await File(path).readAsBytes();
        return;
      }
    } catch (_) {}
    state = null;
  }

  Future<void> save(Uint8List? bytes) async {
    final userId = _currentUserId;
    if (userId == null) { state = bytes; return; }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (bytes != null) {
        final dir = await _avatarDir();
        final filePath = _filePath(dir);
        await File(filePath).writeAsBytes(bytes);
        await prefs.setString(_pathKey(userId: userId), filePath);
      } else {
        final path = prefs.getString(_pathKey(userId: userId));
        if (path != null) {
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
        await prefs.remove(_pathKey(userId: userId));
      }
      state = bytes;
    } catch (_) {
      state = bytes;
    }
  }

  Future<void> clear() async {
    final userId = _currentUserId;
    if (userId == null) { state = null; return; }
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(_pathKey(userId: userId));
      if (path != null) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
      await prefs.remove(_pathKey(userId: userId));
    } catch (_) {}
    state = null;
  }
}

final avatarProvider = StateNotifierProvider<AvatarNotifier, Uint8List?>((ref) {
  return AvatarNotifier();
});
