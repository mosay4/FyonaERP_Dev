import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One backup file in the FYONA folder on this device.
class DeviceBackupFile {
  DeviceBackupFile(this.uri, this.name, this.size, this.modified);
  final String uri;
  final String name;
  final int size;
  final DateTime modified;
}

/// The "FYONA ERP" folder the app keeps backups in (Android: Download/FYONA
/// ERP — it survives reinstalling the app; iOS: the app's Documents, shown
/// in the Files app; desktop: Downloads/FYONA ERP). Backups are listed and
/// read inside the app — the user never has to open a file manager.
class DeviceBackupFolder {
  static const _channel = MethodChannel('com.fyona.erp/storage_space');
  static const folderName = 'FYONA ERP';

  /// Tests (and non-Android platforms) use a plain folder.
  static Future<Directory> Function()? folderOverride;

  static Future<Directory> _folder() async {
    final o = folderOverride;
    if (o != null) return o();
    final base = Platform.isIOS ? await getApplicationDocumentsDirectory() : (await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory());
    return Directory('${base.path}/$folderName');
  }

  static bool get _native => folderOverride == null && Platform.isAndroid;

  /// Files ending in one of [extensions], newest first.
  static Future<List<DeviceBackupFile>> list(List<String> extensions) async {
    final out = <DeviceBackupFile>[];
    if (_native) {
      String? tree;
      try {
        tree = (await SharedPreferences.getInstance()).getString('backup_saved_tree_uri');
      } catch (_) {}
      final raw = await _channel.invokeMethod<List<dynamic>>('listFyonaFiles', {'extensions': extensions, 'treeUri': tree});
      for (final e in raw ?? const []) {
        final m = Map<String, dynamic>.from(e as Map);
        out.add(DeviceBackupFile('${m['uri']}', '${m['name']}', (m['size'] as num?)?.toInt() ?? 0,
            DateTime.fromMillisecondsSinceEpoch(((m['modified'] as num?)?.toInt() ?? 0) * 1000)));
      }
    } else {
      final dir = await _folder();
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File) continue;
          final name = f.uri.pathSegments.last;
          if (!extensions.any((x) => name.toLowerCase().endsWith('.$x'))) continue;
          final st = await f.stat();
          out.add(DeviceBackupFile(f.path, name, st.size, st.modified));
        }
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// Copies the backup into [into] (streamed; any size).
  static Future<void> copyTo(DeviceBackupFile file, File into) async {
    if (_native) {
      final ok = await _channel.invokeMethod<bool>('copyUriToFile', {'uri': file.uri, 'path': into.path});
      if (ok != true) throw const FileSystemException('copy failed');
      return;
    }
    await into.parent.create(recursive: true);
    await File(file.uri).copy(into.path);
  }

  /// Keeps [source] in the folder as [name].
  static Future<void> save(File source, String name) async {
    if (_native) {
      final ok = await _channel.invokeMethod<bool>('saveFileToDownloads',
          {'path': source.path, 'fileName': name, 'mimeType': 'application/octet-stream'});
      if (ok != true) throw const FileSystemException('save failed');
      return;
    }
    final dir = await _folder();
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/$name.part');
    await source.copy(tmp.path);
    await tmp.rename('${dir.path}/$name');
  }

  static Future<void> delete(DeviceBackupFile file) async {
    if (_native) {
      await _channel.invokeMethod<bool>('deleteUri', {'uri': file.uri});
      return;
    }
    final f = File(file.uri);
    if (await f.exists()) await f.delete();
  }
}
