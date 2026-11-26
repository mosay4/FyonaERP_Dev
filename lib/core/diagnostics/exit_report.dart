import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../localization/app_localizations.dart';

/// After the app froze (ANR) or crashed, the next launch offers the system
/// report (stack traces only, no user data) so the real cause is known.
/// The file stays on the device; the user decides whether to share it.
abstract final class ExitReport {
  static const _channel = MethodChannel('com.fyona.erp/diagnostics');

  static Future<void> checkAndOffer(BuildContext? Function() context) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final report = await _channel.invokeMethod<String>('lastExit');
      if (report == null || report.isEmpty) return;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/fyona_exit_report.txt');
      await file.writeAsString(report);
      final ctx = context();
      if (ctx == null || !ctx.mounted) return;
      final l10n = AppLocalizations.of(ctx);
      final share = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: Text(l10n.translate('exitReportTitle')),
          content: Text(l10n.translate('exitReportBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(l10n.translate('exitReportLater')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(l10n.translate('exitReportShare')),
            ),
          ],
        ),
      );
      if (share == true) {
        await Share.shareXFiles([XFile(file.path)], text: 'FYONA exit report');
      }
    } catch (_) {}
  }
}
