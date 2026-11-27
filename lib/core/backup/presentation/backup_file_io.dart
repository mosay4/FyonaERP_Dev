import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../backup_coordinator.dart';
import '../backup_pack.dart';

final backupFileIoProvider = Provider<BackupFileIo>((ref) => BackupFileIo());

/// Platform side of "save as a file" / "restore from a file" for backup
/// sets. Large files are streamed: never read whole into memory.
class BackupFileIo {
  static const _channel = MethodChannel('com.fyona.erp/storage_space');

  /// The picked file as a stream, with its size and name; null = cancelled.
  Future<({Stream<List<int>> data, int size})?> pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.any, withData: false, withReadStream: true);
    final f = picked?.files.single;
    if (f == null) return null;
    // Android shows every file (no MIME type for this extension).
    if (!f.name.toLowerCase().endsWith('.$backupPackExtension')) {
      throw const BackupRestoreFailure('not_a_backup');
    }
    final s = f.readStream;
    if (s == null) throw const BackupRestoreFailure('not_a_backup');
    return (data: s, size: f.size);
  }

  /// Keeps [file] on the device under [name]. Android: Downloads/FYONA ERP
  /// (copied natively in blocks). iOS: the share sheet ("Save to Files").
  /// Desktop: a save dialog. Returns false when the user cancelled.
  Future<bool> save(File file, String name) async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('saveFileToDownloads', {
            'path': file.path,
            'fileName': name,
            'mimeType': 'application/octet-stream',
          }) ==
          true;
    }
    if (Platform.isIOS) {
      final r = await Share.shareXFiles([XFile(file.path, name: name, mimeType: 'application/octet-stream')],
          fileNameOverrides: [name]);
      return r.status == ShareResultStatus.success;
    }
    final path = await FilePicker.saveFile(fileName: name, type: FileType.any);
    if (path == null) return false;
    final tmp = File('$path.part');
    await file.copy(tmp.path);
    await tmp.rename(path);
    return true;
  }
}
