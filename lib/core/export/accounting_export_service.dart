import 'dart:io';

import '../../features/core_business/data/local_directory/directory_database.dart';
import '../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../features/core_business/data/local_directory/directory_scope.dart';
import '../media/media_store.dart';
import 'accounting_export_writer.dart';

/// Result of an accounting export: the ZIP and what it proved.
typedef AccountingExportFile = ({File zip, BusinessExportResult result});

/// Exports one Business branch's accounting at a cut-off day into a ZIP
/// (Excel + CSV + photos + manifest). Read-only; owner only (the export
/// holds every balance of the branch).
Future<AccountingExportFile> exportBusinessAccounting({
  required DirectoryPilotStore store,
  required DirectoryAccess access,
  required DateTime cutoff,
  required bool arabic,
  required Directory work,
  required File into,
  MediaStore? media,
  bool images = true,
  String appVersion = '',
}) async {
  if (access.member || !access.financialCutover) throw const DirectoryAccessDenied();
  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);
  final grant = BusinessLedgerAccess(access, {BusinessLedgerAction.readBank, BusinessLedgerAction.readDebt});
  final writer = AccountingExportWriter(
      work: work, sheets: businessExportSheets, numeric: businessExportNumeric, arabic: arabic);
  String name(String ref, String productId) {
    final f = images ? media?.fileOf(ref) : null;
    return f == null ? '' : 'images/$productId.${_ext(f)}';
  }

  try {
    final result = await store.withLedger(grant, () => access,
        (l) => l.exportAccounting(grant, cutoff: cutoff, emit: writer.add, imageName: name));
    final files = <String, File>{};
    var missing = 0;
    for (final e in result.images.entries) {
      final f = media?.fileOf(e.key);
      if (e.value.isEmpty || f == null) {
        if (images) missing++;
        continue;
      }
      files[e.value] = f;
    }
    if (missing > 0) result.warnings.add('images_not_on_device: $missing');
    await into.parent.create(recursive: true);
    if (await into.exists()) await into.delete();
    final zip = await writer.finish(into, {
      'format': 'fyona.accounting-export.v1',
      'app_version': appVersion,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'scope': {'organization': access.workspace.organizationId, 'branch': access.branchId},
      'language': arabic ? 'ar' : 'en',
      ...result.toJson(),
      'definitions': {
        'balance_cutoff': 'today\'s balance with every later movement taken back (end of the cut-off day, device time)',
        'remaining_cutoff': 'document total minus payments and returns dated on or before the cut-off',
        'quantity_cutoff': 'today\'s stock minus stock movements after the cut-off',
        'money': 'decimal, 2 places, in the row currency',
        'warnings': 'documents edited, deleted or cancelled after the cut-off (today\'s figures kept)',
      },
    }, files: files);
    return (zip: zip, result: result);
  } finally {
    if (await work.exists()) await work.delete(recursive: true);
  }
}

String _ext(File f) {
  try {
    final raf = f.openSync();
    final h = raf.readSync(12);
    raf.closeSync();
    if (h.length >= 3 && h[0] == 0xFF && h[1] == 0xD8) return 'jpg';
    if (h.length >= 4 && h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47) return 'png';
    if (h.length >= 12 && h[0] == 0x52 && h[1] == 0x49 && h[8] == 0x57 && h[9] == 0x45) return 'webp';
    if (h.length >= 3 && h[0] == 0x47 && h[1] == 0x49 && h[2] == 0x46) return 'gif';
  } catch (_) {}
  return 'bin';
}
