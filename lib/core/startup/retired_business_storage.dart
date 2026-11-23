import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One-time cleanup for devices that ran an experimental Business build.
/// The Personal database, credentials and pending Personal operations are
/// deliberately outside this directory and outside these key namespaces.
Future<void> removeRetiredBusinessStorage() async {
  if (kIsWeb ||
      !const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform)) {
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  const complete = 'retired_business_replica_cleanup_v1';
  if (prefs.getBool(complete) == true) return;

  final support = await getApplicationSupportDirectory();
  final directory = Directory(path.join(support.path, 'business-offline'));
  if (await FileSystemEntity.type(directory.path, followLinks: false) ==
      FileSystemEntityType.directory) {
    final replica = RegExp(
      r'^business_v1_[a-zA-Z0-9_-]+\.db(?:-(?:wal|shm|journal))?$',
    );
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && replica.hasMatch(path.basename(entry.path))) {
        await entry.delete();
      }
    }
  }

  const storage = FlutterSecureStorage();
  const prefixes = [
    'business_db_key_v1_',
    'business_device_v1_',
    'business_device_signing_v1_',
  ];
  final keys = (await storage.readAll()).keys
      .where((key) => prefixes.any(key.startsWith))
      .toList();
  for (final key in keys) {
    await storage.delete(key: key);
  }
  await prefs.setBool(complete, true);
}
