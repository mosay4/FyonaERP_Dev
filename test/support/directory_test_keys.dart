import 'dart:io';

import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';

/// Test-only stand-in for the platform vault. Never used in the app. Allows
/// the *same* real cipher DB to be reopened by a different test process.
final class FixtureDirectoryKeys implements DirectoryKeyStore {
  FixtureDirectoryKeys([this.root]);

  final Directory? root;
  final memory = <String, String>{};
  void Function(String)? onRead;

  File _file(String id) => File('${root!.path}/test-key-$id');

  @override
  Future<String?> read(String workspaceId) async {
    onRead?.call(workspaceId);
    if (root == null) return memory[workspaceId];
    final file = _file(workspaceId);
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String workspaceId, String key) async {
    if (root == null) {
      memory[workspaceId] = key;
    } else {
      await _file(workspaceId).writeAsString(key, flush: true);
    }
  }
}
