import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../auth/presentation/widgets/app_pin_sheet.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_ledger/business_local_backups.dart';

typedef VerifyBusinessBackup =
    Future<bool> Function(
      BuildContext context,
      WidgetRef ref,
      String reason,
      bool local,
    );

final businessBackupVerifierProvider = Provider<VerifyBusinessBackup>(
  (ref) =>
      (context, widgetRef, reason, local) => verifySensitiveAction(
        context,
        widgetRef,
        reason: reason,
        existingCredentialsOnly: local,
      ),
);

final businessBackupFilesProvider = Provider<BusinessBackupFiles>(
  (ref) => BusinessBackupFiles(),
);

/// Platform boundary for the original backup page. Only ciphertext is sent
/// to the OS save/share sheet; the one-time recovery code is never included.
class BusinessBackupFiles {
  static const _storage = MethodChannel('com.fyona.erp/storage_space');

  /// Size of the file the last [pick] returned (for the free-space check
  /// and the percentage); null when unknown.
  int? pickedSize;

  /// A file of any size: the restore reads at most 64 MB of it unless its
  /// first page opens with the recovery code (a genuine FYONA backup).
  Future<Stream<List<int>>?> pick() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [businessBackupExtension],
      withData: false,
      withReadStream: true,
    );
    final entry = picked?.files.single;
    if (entry == null) return null;
    // Android may show more than this extension when no MIME mapping exists.
    if (entry.extension?.toLowerCase() != businessBackupExtension) {
      throw const BusinessBackupRejected(BusinessBackupProblem.invalidArchive);
    }
    if (entry.size > businessBackupRebuildMaxBytes) {
      throw const BusinessBackupRejected(BusinessBackupProblem.tooLarge);
    }
    pickedSize = entry.size > 0 ? entry.size : null;
    return entry.readStream ??
        (throw const BusinessBackupRejected(
          BusinessBackupProblem.invalidArchive,
        ));
  }

  /// Never reads the file into memory: Android copies it natively into
  /// Downloads/FYONA ERP in blocks; iOS hands it to the share sheet
  /// ("Save to Files"); desktop copies it to the chosen path.
  Future<void> save(LocalBusinessBackupFile backup) async {
    if (Platform.isAndroid) {
      final ok = await _storage.invokeMethod<bool>('saveFileToDownloads', {
        'path': backup.file.path,
        'fileName': backup.name,
        'mimeType': 'application/octet-stream',
      });
      if (ok != true) throw const BusinessBackupRejected(BusinessBackupProblem.invalidArchive);
      return;
    }
    if (Platform.isIOS) return share(backup);
    final path = await FilePicker.saveFile(
      fileName: backup.name,
      type: FileType.custom,
      allowedExtensions: [businessBackupExtension],
    );
    if (path == null) return;
    final tmp = File('$path.part');
    await backup.file.copy(tmp.path);
    await tmp.rename(path);
  }

  Future<void> share(LocalBusinessBackupFile backup) async {
    await Share.shareXFiles(
      [
        XFile(
          backup.file.path,
          name: backup.name,
          mimeType: 'application/octet-stream',
        ),
      ],
      fileNameOverrides: [backup.name],
    );
  }
}
