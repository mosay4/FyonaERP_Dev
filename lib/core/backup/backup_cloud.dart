import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../media/media_store.dart';
import '../media/media_sync.dart';
import '../network/api_client.dart';
import 'backup_service.dart';

/// The FYONA server side of cloud backups: it only issues short-lived signed
/// URLs for this user's / organisation's private area (derived from the
/// session on the server, never from the request). Parts go straight
/// between the device and Cloudflare R2; they are already encrypted with a
/// key the server never sees.
abstract class BackupRemote {
  Future<String> uploadUrl(String backupId, String part, int size);
  Future<String> downloadUrl(String backupId, String part);
  Future<List<Map<String, dynamic>>> list();
  Future<void> delete(String backupId);
}

class ApiBackupRemote implements BackupRemote {
  ApiBackupRemote(this._api, this.section);
  final ApiClient _api;
  final MediaSection section; // personal or business

  String get _base => section == MediaSection.business ? '/business-storage' : '/storage';
  Map<String, dynamic> get _scope => section == MediaSection.business ? const {} : const {'section': 'personal'};

  Map<String, dynamic> _data(Response r) {
    final m = r.data is Map ? r.data as Map : const {};
    return m['data'] is Map ? Map<String, dynamic>.from(m['data'] as Map) : const {};
  }

  @override
  Future<String> uploadUrl(String backupId, String part, int size) async => '${_data(await _api.post<Map<String, dynamic>>(
          '$_base/upload-url',
          data: {..._scope, 'area': 'b', 'backup_id': backupId, 'part': part, 'size': size,
            'content_type': 'application/octet-stream'}))['url']}';

  @override
  Future<String> downloadUrl(String backupId, String part) async => '${_data(await _api.post<Map<String, dynamic>>(
          '$_base/download-url', data: {..._scope, 'area': 'b', 'backup_id': backupId, 'part': part}))['url']}';

  @override
  Future<List<Map<String, dynamic>>> list() async {
    final r = await _api.get<Map<String, dynamic>>('$_base/backups',
        queryParameters: section == MediaSection.business ? null : {'section': 'personal'});
    return [for (final b in (_data(r)['backups'] as List? ?? const [])) Map<String, dynamic>.from(b as Map)];
  }

  @override
  Future<void> delete(String backupId) => _api.delete<Map<String, dynamic>>('$_base/backups/$backupId',
      queryParameters: section == MediaSection.business ? null : {'section': 'personal'});
}

/// Cloudflare R2 as a backup destination (through [BackupRemote]).
class CloudBackupDestination implements BackupDestination {
  CloudBackupDestination(this.remote, {MediaTransfer? transfer, required this.temp})
      : transfer = transfer ?? HttpMediaTransfer();
  final BackupRemote remote;
  final MediaTransfer transfer;
  final Directory temp;

  @override
  String get id => 'r2';

  @override
  Future<void> put(String backupId, String part, Uint8List data) async {
    final url = await remote.uploadUrl(backupId, part, data.length);
    await temp.create(recursive: true);
    final f = File('${temp.path}/up-${DateTime.now().microsecondsSinceEpoch}');
    await f.writeAsBytes(data, flush: true);
    try {
      final code = await transfer.put(
          url, {'content-type': 'application/octet-stream', 'content-length': '${data.length}'}, f);
      if (code != 200) throw HttpException('upload $part: $code');
    } finally {
      if (f.existsSync()) f.deleteSync();
    }
  }

  @override
  Future<Uint8List?> get(String backupId, String part) async {
    try {
      return await transfer.get(await remote.downloadUrl(backupId, part));
    } on HttpException catch (e) {
      if (e.message.contains('404')) return null;
      rethrow;
    }
  }

  @override
  Future<List<String>> sets() async =>
      [for (final b in await remote.list()) if (b['complete'] == true) '${b['backup_id']}']..sort();

  @override
  Future<void> deleteSet(String backupId) => remote.delete(backupId);
}

/// Uploads a local set folder to the cloud: only files not sent yet (by
/// name + size + time), `manifest.enc` always last, so the cloud copy is
/// either the previous complete state or the new complete state.
class BackupMirror {
  BackupMirror(this.cloud);
  final CloudBackupDestination cloud;

  /// [sent] = `{part: "size:mtime"}` for this set (persisted by the caller).
  Future<int> push(Directory setDir, String backupId, Map<String, String> sent) async {
    if (!await setDir.exists()) return 0;
    final files = [
      await for (final e in setDir.list())
        if (e is File && !e.path.endsWith('.tmp')) e,
    ];
    files.sort((a, b) => _name(a) == 'manifest.enc' ? 1 : (_name(b) == 'manifest.enc' ? -1 : 0));
    var n = 0;
    for (final f in files) {
      final st = await f.stat();
      final tag = '${st.size}:${st.modified.microsecondsSinceEpoch}';
      if (sent[_name(f)] == tag) continue;
      await cloud.put(backupId, _name(f), await f.readAsBytes());
      sent[_name(f)] = tag;
      n++;
    }
    return n;
  }

  /// Copies a complete cloud set into a local folder (for restore).
  Future<void> pull(String backupId, Directory into, Iterable<String> parts) async {
    await into.create(recursive: true);
    for (final p in parts) {
      final b = await cloud.get(backupId, p);
      if (b == null) continue; // the restorer reports what is missing
      await File('${into.path}/$p').writeAsBytes(b, flush: true);
    }
  }

  static String _name(File f) => f.uri.pathSegments.last;
}
