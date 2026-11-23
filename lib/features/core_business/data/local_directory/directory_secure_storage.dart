import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'directory_database.dart';

Future<Directory> businessDirectoryRoot() async => Directory(
  p.join(
    (await getApplicationSupportDirectory()).path,
    'business_directory_v1',
  ),
);

/// This vault is not the session/Personal vault, and must never reset on error.
final class SecureDirectoryKeys implements DirectoryKeyStore {
  const SecureDirectoryKeys();

  static const vault = FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'fyona_business_directory_v1',
      resetOnError: false,
    ),
  );

  @override
  Future<String?> read(String workspaceId) =>
      vault.read(key: 'directory-key-$workspaceId');

  @override
  Future<void> write(String workspaceId, String key) =>
      vault.write(key: 'directory-key-$workspaceId', value: key);
}
