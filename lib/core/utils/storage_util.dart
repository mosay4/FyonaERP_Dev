import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import '../theme/app_colors.dart';
import '../localization/app_localizations.dart';
export 'package:share_plus/share_plus.dart' show Share, XFile;

class StorageUtil {
  static Future<bool> saveFile({
    required BuildContext context,
    required File source,
    required String fileName,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/$fileName');
      await source.copy(dest.path);

      if (context.mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('coreFileSaved'), style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: l10n.translate('share'),
            textColor: Colors.white,
            onPressed: () => Share.shareXFiles([XFile(dest.path)], text: fileName),
          ),
        ));
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).translate('coreSaveFailed', params: {'error': e}), style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
      return false;
    }
  }

  static const MethodChannel _storageChannel =
      MethodChannel('com.fyona.erp/backup_storage');

  /// Saves DIRECTLY into the device's Downloads/FYONA folder through the
  /// native MediaStore channel (Android 10+: no permission at all). On old
  /// Android (9-) the runtime storage permission is requested IN-APP (the
  /// system dialog — the app never hops to Settings), then the save retries
  /// once. Grant once → never asked again unless the user revokes it.
  static Future<bool> saveToDownloads({
    required BuildContext context,
    required File source,
    required String fileName,
  }) async {
    Future<bool> attempt() async {
      final bytes = await source.readAsBytes();
      final res = await _storageChannel.invokeMethod('saveFileBytes', {
        'fileName': fileName,
        'bytes': bytes,
        'mimeType': 'application/pdf',
      });
      final map = Map<String, dynamic>.from(res as Map);
      return map['success'] == true;
    }

    try {
      var ok = await attempt();
      if (!ok) {
        // Old-Android only: request the system permission IN-APP.
        final status = await Permission.storage.request();
        if (status.isGranted) ok = await attempt();
      }
      if (context.mounted) {
        final l10n = AppLocalizations.of(context);
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.translate('coreReportSavedDownloads'),
                style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: l10n.translate('share'),
              textColor: Colors.white,
              onPressed: () =>
                  Share.shareXFiles([XFile(source.path)], text: fileName),
            ),
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.translate('coreStoragePermissionMsg'),
                style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: AppColors.danger,
            duration: const Duration(seconds: 5),
          ));
        }
      }
      return ok;
    } catch (e) {
      if (context.mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('coreSaveFailed', params: {'error': e}),
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
      return false;
    }
  }

  /// Show bottom sheet with 3 options: فتح, مشاركة, تنزيل
  static Future<void> showPdfOptions(BuildContext context, File file, String fileName) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 36, height: 4, decoration: BoxDecoration(color: AppColors.textDisabled, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context).translate('coreReportOptions'), style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 20),
            _optionTile(ctx, Icons.open_in_new, AppLocalizations.of(context).translate('coreOpen'), AppColors.primary, () async {
              Navigator.pop(ctx);
              try {
                final stamp = DateTime.now().millisecondsSinceEpoch;
                final docDir = await getApplicationDocumentsDirectory();
                final copy = await file.copy('${docDir.path}/fyona_report_$stamp.pdf');
                final result = await OpenFilex.open(copy.path, type: 'application/pdf');
                if (result.type != ResultType.done && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(AppLocalizations.of(context).translate('coreOpenFailed', params: {'message': result.message}), style: const TextStyle(fontFamily: 'Cairo')),
                    backgroundColor: AppColors.danger,
                    duration: const Duration(seconds: 5),
                  ));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(AppLocalizations.of(context).translate('coreErrorWithParam', params: {'error': e}), style: const TextStyle(fontFamily: 'Cairo')),
                    backgroundColor: AppColors.danger,
                    duration: const Duration(seconds: 5),
                  ));
                }
              }
            }),
            _optionTile(ctx, Icons.share, AppLocalizations.of(context).translate('share'), const Color(0xFF2E7D32), () {
              Navigator.pop(ctx);
              Share.shareXFiles([XFile(file.path)], text: fileName);
            }),
            _optionTile(ctx, Icons.download, AppLocalizations.of(context).translate('coreDownload'), AppColors.danger, () async {
              Navigator.pop(ctx);
              await saveToDownloads(context: context, source: file, fileName: fileName);
            }),
          ],
        ),
      ),
    );
  }

  static Widget _optionTile(BuildContext context, IconData icon, String label, Color color, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: color.withAlpha(30), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        trailing: Icon(Icons.chevron_left, color: AppColors.textDisabled, size: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onTap: onTap,
      ),
    );
  }
}
