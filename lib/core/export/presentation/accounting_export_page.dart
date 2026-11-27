import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../config/app_config.dart';
import '../../localization/app_localizations.dart';
import '../../media/media_store.dart';
import '../../theme/app_colors.dart';
import '../accounting_export_service.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';

/// Entry card on the Business backup screen (owner of a device ledger).
class AccountingExportEntry extends ConsumerWidget {
  const AccountingExportEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    if (scope == null || scope.member) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AppColors.border)),
      child: ListTile(
        key: const Key('ax-entry'),
        leading: const Icon(Icons.table_view_outlined, color: AppColors.primary),
        title: Text(_t('axTitle'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
        subtitle: Text(_t('axEntrySubtitle'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountingExportPage())),
      ),
    );
  }
}

class AccountingExportPage extends ConsumerStatefulWidget {
  const AccountingExportPage({super.key});
  @override
  ConsumerState<AccountingExportPage> createState() => _AccountingExportPageState();
}

class _AccountingExportPageState extends ConsumerState<AccountingExportPage> {
  DateTime _cutoff = DateTime.now();
  bool _images = true;
  bool _busy = false;
  String? _done;
  int _warnings = 0;

  String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: _cutoff, firstDate: DateTime(2000), lastDate: now);
    if (d != null) setState(() => _cutoff = d);
  }

  Future<void> _export() async {
    final scope = ref.read(businessLocalLedgerScopeProvider);
    if (scope == null || scope.member) return;
    setState(() {
      _busy = true;
      _done = null;
    });
    try {
      final base = await getTemporaryDirectory();
      final name = 'FYONA-accounting-${_day(_cutoff)}.zip';
      final r = await exportBusinessAccounting(
        store: ref.read(directoryPilotStoreProvider),
        access: scope,
        cutoff: _cutoff,
        arabic: AppLocalizations.currentLanguage == 'ar',
        work: Directory('${base.path}/accounting-export-work'),
        into: File('${base.path}/accounting-export/$name'),
        media: MediaStore.ready,
        images: _images,
        appVersion: AppConfig.appVersion,
      );
      if (!mounted) return;
      setState(() {
        _done = r.zip.path;
        _warnings = r.result.warnings.length;
      });
      await Share.shareXFiles([XFile(r.zip.path, mimeType: 'application/zip')], text: name);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_t('axFailed'), style: const TextStyle(fontFamily: _font)),
          backgroundColor: AppColors.danger,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_t('axTitle'), style: const TextStyle(fontFamily: _font))),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(_t('axIntro'), style: const TextStyle(fontFamily: _font, fontSize: 13, height: 1.6)),
            const SizedBox(height: 16),
            ListTile(
              key: const Key('ax-cutoff'),
              leading: const Icon(Icons.event_outlined),
              title: Text(_t('axCutoff'), style: const TextStyle(fontFamily: _font)),
              subtitle: Text(_day(_cutoff), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
              onTap: _busy ? null : _pick,
            ),
            SwitchListTile(
              key: const Key('ax-images'),
              value: _images,
              onChanged: _busy ? null : (v) => setState(() => _images = v),
              title: Text(_t('axImages'), style: const TextStyle(fontFamily: _font)),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('ax-run'),
              onPressed: _busy ? null : _export,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.file_download_outlined),
              label: Text(_busy ? _t('axWorking') : _t('axRun'), style: const TextStyle(fontFamily: _font)),
            ),
            if (_done != null) ...[
              const SizedBox(height: 16),
              Text(_t('axDone'), style: const TextStyle(fontFamily: _font, color: AppColors.success)),
              if (_warnings > 0)
                Text(_t('axWarnings', {'n': _warnings}), style: const TextStyle(fontFamily: _font, fontSize: 12)),
              TextButton.icon(
                onPressed: () => Share.shareXFiles([XFile(_done!, mimeType: 'application/zip')]),
                icon: const Icon(Icons.share_outlined),
                label: Text(_t('share'), style: const TextStyle(fontFamily: _font)),
              ),
            ],
          ],
        ),
      );
}
