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

/// What to export.
enum ExportKind { balances, all, parts }

/// The parts a user can pick, each with the sheets it holds.
const exportParts = <String, List<String>>{
  'accounts': ['opening_accounts'],
  'parties': ['opening_parties'],
  'stock': ['opening_stock'],
  'documents': ['documents', 'document_lines'],
  'payments': ['payments', 'returns'],
  'movements': ['bank_movements'],
};

const _partIcons = <String, IconData>{
  'accounts': Icons.account_balance_rounded,
  'parties': Icons.people_alt_rounded,
  'stock': Icons.inventory_2_rounded,
  'documents': Icons.receipt_long_rounded,
  'payments': Icons.payments_rounded,
  'movements': Icons.swap_vert_rounded,
};

class AccountingExportPage extends ConsumerStatefulWidget {
  const AccountingExportPage({super.key});
  @override
  ConsumerState<AccountingExportPage> createState() => _AccountingExportPageState();
}

class _AccountingExportPageState extends ConsumerState<AccountingExportPage> {
  DateTime _cutoff = DateTime.now();
  ExportKind _kind = ExportKind.balances;
  final Set<String> _parts = {'parties', 'stock'};
  bool _images = true;
  bool _busy = false;
  String? _done;
  int _warnings = 0;

  String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Set<String>? get _sheets => switch (_kind) {
        ExportKind.all => null,
        ExportKind.balances => {'opening_accounts', 'opening_parties', 'opening_stock'},
        ExportKind.parts => {for (final p in _parts) ...exportParts[p]!},
      };

  bool get _hasStock => _sheets == null || _sheets!.contains('opening_stock');

  Future<void> _pick() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: _cutoff, firstDate: DateTime(2000), lastDate: now);
    if (d != null) setState(() => _cutoff = d);
  }

  Future<void> _export() async {
    final scope = ref.read(businessLocalLedgerScopeProvider);
    if (scope == null || scope.member) return;
    if (_kind == ExportKind.parts && _parts.isEmpty) return;
    setState(() {
      _busy = true;
      _done = null;
    });
    try {
      final base = await getTemporaryDirectory();
      final name = 'FYONA-${_t('axFile_${_kind.name}')}-${_day(_cutoff)}.zip';
      final r = await exportBusinessAccounting(
        store: ref.read(directoryPilotStoreProvider),
        access: scope,
        cutoff: _cutoff,
        arabic: AppLocalizations.currentLanguage == 'ar',
        work: Directory('${base.path}/accounting-export-work'),
        into: File('${base.path}/accounting-export/$name'),
        media: MediaStore.ready,
        images: _images && _hasStock,
        appVersion: AppConfig.appVersion,
        only: _sheets,
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

  Widget _kindCard(ExportKind k, IconData icon) {
    final on = _kind == k;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: on ? AppColors.primary.withValues(alpha: .07) : AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: Key('ax-kind-${k.name}'),
          borderRadius: BorderRadius.circular(18),
          onTap: _busy ? null : () => setState(() => _kind = k),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: on ? AppColors.primary : AppColors.border, width: on ? 1.6 : 1),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                    color: on ? AppColors.primary : AppColors.primary.withValues(alpha: .10), borderRadius: BorderRadius.circular(13)),
                child: Icon(icon, color: on ? Colors.white : AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_t('axKind_${k.name}'), style: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(_t('axKindHint_${k.name}'),
                      style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary, height: 1.4)),
                ]),
              ),
              Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: on ? AppColors.primary : AppColors.border),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: Text(_t('axTitle'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800))),
        body: Column(children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                Text(_t('axWhat'), style: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                _kindCard(ExportKind.balances, Icons.account_balance_wallet_rounded),
                _kindCard(ExportKind.all, Icons.all_inbox_rounded),
                _kindCard(ExportKind.parts, Icons.checklist_rounded),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  child: _kind != ExportKind.parts
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final p in exportParts.keys)
                              FilterChip(
                                key: Key('ax-part-$p'),
                                avatar: Icon(_partIcons[p], size: 18,
                                    color: _parts.contains(p) ? Colors.white : AppColors.primary),
                                label: Text(_t('axPart_$p'),
                                    style: TextStyle(
                                        fontFamily: _font,
                                        fontWeight: FontWeight.w700,
                                        color: _parts.contains(p) ? Colors.white : null)),
                                selected: _parts.contains(p),
                                selectedColor: AppColors.primary,
                                showCheckmark: false,
                                onSelected: _busy ? null : (v) => setState(() => v ? _parts.add(p) : _parts.remove(p)),
                              ),
                          ]),
                        ),
                ),
                const SizedBox(height: 6),
                Container(
                  decoration: BoxDecoration(
                      color: AppColors.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.border)),
                  child: Column(children: [
                    ListTile(
                      key: const Key('ax-cutoff'),
                      leading: const Icon(Icons.event_rounded, color: AppColors.primary),
                      title: Text(_t('axCutoff'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                      subtitle: Text(_day(_cutoff), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                      trailing: const Icon(Icons.edit_calendar_rounded),
                      onTap: _busy ? null : _pick,
                    ),
                    if (_hasStock) ...[
                      Divider(height: 1, color: AppColors.border),
                      SwitchListTile.adaptive(
                        key: const Key('ax-images'),
                        value: _images,
                        onChanged: _busy ? null : (v) => setState(() => _images = v),
                        secondary: const Icon(Icons.photo_library_rounded, color: AppColors.primary),
                        title: Text(_t('axImages'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ]),
                ),
                if (_done != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: AppColors.success.withValues(alpha: .08), borderRadius: BorderRadius.circular(16)),
                    child: Row(children: [
                      const Icon(Icons.check_circle_rounded, color: AppColors.success),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_t('axDone'), style: const TextStyle(fontFamily: _font, color: AppColors.success, fontWeight: FontWeight.w800)),
                          if (_warnings > 0)
                            Text(_t('axWarnings', {'n': _warnings}), style: const TextStyle(fontFamily: _font, fontSize: 12)),
                        ]),
                      ),
                      IconButton(
                        onPressed: () => Share.shareXFiles([XFile(_done!, mimeType: 'application/zip')]),
                        icon: const Icon(Icons.share_rounded, color: AppColors.success),
                      ),
                    ]),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  key: const Key('ax-run'),
                  style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                  onPressed: _busy || (_kind == ExportKind.parts && _parts.isEmpty) ? null : _export,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.file_download_rounded),
                  label: Text(_busy ? _t('axWorking') : _t('axRun'),
                      style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ),
        ]),
      );
}
