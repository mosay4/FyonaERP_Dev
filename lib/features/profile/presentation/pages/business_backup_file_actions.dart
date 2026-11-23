import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
    if (entry.size > businessBackupMaxBytes) {
      throw const BusinessBackupRejected(BusinessBackupProblem.tooLarge);
    }
    return entry.readStream ??
        (throw const BusinessBackupRejected(
          BusinessBackupProblem.invalidArchive,
        ));
  }

  Future<void> save(LocalBusinessBackupFile backup) async {
    await FilePicker.saveFile(
      fileName: backup.name,
      bytes: await backup.file.readAsBytes(),
      type: FileType.custom,
      allowedExtensions: [businessBackupExtension],
    );
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
