import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/api_client.dart';
import 'backup_crypto.dart';

/// The account's backup key (owner's decision 27-11-2026): every backup —
/// device file or cloud — is encrypted on this device with a key that
/// belongs to the signed-in account (Personal user, or the business for its
/// owner). The FYONA server derives it from a master secret kept apart from
/// the backups; a new device gets it after signing in, so restoring needs
/// no recovery code. It is cached in the platform keystore so backups also
/// work offline once the key was fetched.
class AccountBackupKeys {
  AccountBackupKeys(this._api, {FlutterSecureStorage? vault})
      : _vault = vault ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(storageNamespace: 'fyona_backup_v2', resetOnError: false));

  final ApiClient? _api;
  final FlutterSecureStorage _vault;

  /// Tests replace the network fetch.
  static Future<String?> Function(String path)? fetchOverride;

  static const personalPath = '/backups/account-key';
  static const businessPath = '/business-storage/account-key';

  Future<SecretKey?> personal(String userId, {bool online = true}) =>
      _get('acct-u-$userId', personalPath, online: online);

  Future<SecretKey?> business(String organizationId, {bool online = true}) =>
      _get('acct-o-$organizationId', businessPath, online: online);

  Future<SecretKey?> _get(String slot, String path, {required bool online}) async {
    String? b64;
    try {
      b64 = await _vault.read(key: slot);
    } catch (_) {}
    if (b64 == null && online) {
      final o = fetchOverride;
      if (o != null) {
        b64 = await o(path);
      } else {
        final api = _api;
        if (api == null) return null;
        final r = await api.get<Map<String, dynamic>>(path);
        b64 = ((r.data?['data'] as Map?)?['key'])?.toString();
      }
      if (b64 != null && b64.isNotEmpty) {
        try {
          await _vault.write(key: slot, value: b64);
        } catch (_) {}
      }
    }
    if (b64 == null || b64.isEmpty) return null;
    final raw = base64Decode(b64);
    if (raw.length != 32) return null;
    return BackupKeys.keyFrom(raw);
  }

  /// Forget the cached keys (sign-out).
  Future<void> clear() async {
    try {
      final all = await _vault.readAll();
      for (final k in all.keys.where((k) => k.startsWith('acct-'))) {
        await _vault.delete(key: k);
      }
    } catch (_) {}
  }
}

/// Encrypted wrapping of a backup that used to be plain JSON text (device
/// files, server versions). Older plain files are still read.
abstract final class BackupEnvelope {
  static const _marker = 'fyona_encrypted';

  /// Written by [sealText] (fixed key order): a plain backup never starts
  /// like this, so no full parse is needed to tell them apart.
  static bool isSealedText(String s) => s.trimLeft().startsWith('{"$_marker":1');

  static bool isSealedBytes(List<int> b) =>
      b.length >= 4 && b[0] == BackupContainer.magic[0] && b[1] == BackupContainer.magic[1] &&
      b[2] == BackupContainer.magic[2] && b[3] == BackupContainer.magic[3];

  static Future<Uint8List> sealBytes(List<int> plain, SecretKey key) =>
      BackupContainer.seal(Uint8List.fromList(plain), key);

  static Future<Uint8List> openBytes(List<int> sealed, SecretKey key) =>
      BackupContainer.open(Uint8List.fromList(sealed), key);

  /// A text file holding the encrypted backup (device folder files are
  /// written and read as text by the platform code).
  static Future<String> sealText(String plain, SecretKey key, {String scope = 'u'}) async =>
      jsonEncode({_marker: 1, 'v': 1, 'scope': scope, 'data': base64Encode(await sealBytes(utf8.encode(plain), key))});

  /// The plain JSON of [text]: opened when sealed, returned as is when an
  /// older plain file. Throws when the key does not open it.
  static Future<String> openText(String text, SecretKey key) async {
    final m = jsonDecode(text) as Map;
    return utf8.decode(await openBytes(base64Decode('${m['data']}'), key));
  }
}
