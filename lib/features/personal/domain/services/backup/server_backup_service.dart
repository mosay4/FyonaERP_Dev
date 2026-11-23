import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../../core/network/api_client.dart';
import '../../../../../core/network/api_endpoints.dart';
import '../../../../../core/offline/offline_guard.dart';

/// Server backup blob client (per-user versions on FYONA server).
///
/// Thin transport only: all integrity rules live in [BackupIntegrity] and
/// on the backend. Upload sends the sealed snapshot bytes; the server
/// re-verifies checksum + HMAC with the user's server-side key and rejects
/// anything invalid. Ownership is enforced backend-side (JWT user).
/// Works strictly online — offline callers get an explicit failure, and no
/// previous server version is ever touched by a failed call.
class ServerBackupService {
  final ApiClient? _apiClient;
  final FlutterSecureStorage _secureStorage;

  static const String _hmacKeyStorageKey = 'backup_hmac_key_b64';

  ServerBackupService({ApiClient? apiClient, FlutterSecureStorage? secureStorage})
      : _apiClient = apiClient,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  ApiClient get _api {
    final client = _apiClient;
    if (client == null) {
      throw StateError('ServerBackupService: apiClient is not configured');
    }
    return client;
  }

  /// Cached per-user HMAC key (survives app updates; re-fetched from the
  /// server after reinstall — never device-keystore-bound).
  Future<String> getCachedHmacKey() async {
    try {
      return await _secureStorage.read(key: _hmacKeyStorageKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveCachedHmacKey(String keyB64) async {
    try {
      if (keyB64.isEmpty) {
        await _secureStorage.delete(key: _hmacKeyStorageKey);
      } else {
        await _secureStorage.write(key: _hmacKeyStorageKey, value: keyB64);
      }
    } catch (_) {}
  }

  /// Fetches (creating on first use) the user's server-side HMAC key and
  /// caches it on device. Throws offline / on server errors.
  Future<String> fetchHmacKey() async {
    final resp = await _api.get<Map<String, dynamic>>(ApiEndpoints.userBackupKey);
    final body = resp.data;
    String key = '';
    if (body != null) {
      final inner = body['data'];
      if (inner is Map) {
        key = inner['key_b64']?.toString() ?? '';
      } else {
        key = body['key_b64']?.toString() ?? '';
      }
    }
    if (key.isEmpty) throw const ServerBackupException('key_empty');
    await saveCachedHmacKey(key);
    return key;
  }

  /// Uploads sealed snapshot bytes as a NEW server version. Returns the
  /// created version metadata. Never deletes or alters previous versions
  /// itself (retention runs server-side only after verified storage).
  Future<Map<String, dynamic>> uploadBackup(
    Uint8List bytes,
    String filename,
  ) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final resp = await _api.post<Map<String, dynamic>>(
      ApiEndpoints.userBackups,
      data: form,
      options: Options(contentType: 'multipart/form-data'),
    );
    return _unwrapData(resp.data);
  }

  Future<Map<String, dynamic>> listBackups() async {
    final resp = await _api.get<Map<String, dynamic>>(ApiEndpoints.userBackups);
    final data = _unwrapData(resp.data);
    final rawList = data['backups'];
    final backups = <Map<String, dynamic>>[];
    if (rawList is List) {
      for (final e in rawList) {
        if (e is Map) backups.add(Map<String, dynamic>.from(e));
      }
    }
    final rawLatest = data['latest'];
    return {
      'backups': backups,
      'latest': rawLatest is Map ? Map<String, dynamic>.from(rawLatest) : null,
    };
  }

  Future<Map<String, dynamic>> getBackup(String id) async {
    final resp = await _api.get<Map<String, dynamic>>(ApiEndpoints.userBackup(id));
    return _unwrapData(resp.data);
  }

  /// Downloads raw snapshot bytes. Integrity is verified by the caller
  /// (full snapshot validation), not trusted blindly.
  Future<Uint8List> downloadBackup(String id) async {
    final resp = await _api.get<List<int>>(
      ApiEndpoints.userBackupDownload(id),
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (data == null) throw const ServerBackupException('download_empty');
    return Uint8List.fromList(data);
  }

  Future<void> deleteBackup(String id) async {
    await _api.delete<dynamic>(ApiEndpoints.userBackup(id));
  }

  Future<Map<String, dynamic>> updateBackup(
    String id,
    Uint8List bytes,
    String filename,
  ) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final resp = await _api.put<Map<String, dynamic>>(
      ApiEndpoints.userBackup(id),
      data: form,
      options: Options(contentType: 'multipart/form-data'),
    );
    return _unwrapData(resp.data);
  }

  Map<String, dynamic> _unwrapData(dynamic body) {
    if (body is Map) {
      final data = body['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      return Map<String, dynamic>.from(body);
    }
    throw const ServerBackupException('bad_response');
  }
}

/// Maps a transport failure to an explicit offline/server failure code so
/// the UI can show "no connection" instead of a generic error — and, most
/// importantly, never claim a server backup succeeded while offline.
String serverFailureCode(Object error) {
  if (error is ServerBackupException) return error.code;
  if (isConnectivityError(error)) return 'server_offline';
  if (error is DioException) {
    final code = error.response?.statusCode ?? 0;
    if (code == 401 || code == 403) return 'server_forbidden';
    if (code == 404) return 'server_not_found';
    if (code == 409) return 'server_integrity';
    if (code == 413) return 'server_too_large';
    if (code == 422) return 'server_rejected';
    if (code >= 500) return 'server_error';
  }
  return 'server_failed';
}

class ServerBackupException implements Exception {
  final String code;
  const ServerBackupException(this.code);
  @override
  String toString() => 'ServerBackupException($code)';
}

/// JSON-safe decode helper for Dio map bodies.
Map<String, dynamic> decodeJsonBytes(Uint8List bytes) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
