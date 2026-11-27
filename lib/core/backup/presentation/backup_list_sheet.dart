import 'package:flutter/material.dart';

import '../../localization/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../backup_coordinator.dart';
import '../device_backup_folder.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';

String backupWhen(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}/${two(d.month)}/${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}

String backupSize(int b) => b <= 0
    ? ''
    : b < 1024 * 1024
        ? '${(b / 1024).ceil()} KB'
        : b < 1024 * 1024 * 1024
            ? '${(b / 1048576).toStringAsFixed(1)} MB'
            : '${(b / 1073741824).toStringAsFixed(2)} GB';

class BackupListItem {
  BackupListItem(this.name, this.when, this.size, {this.device, this.cloud, this.legacy = false, this.payload});
  final String name;
  final DateTime when;
  final int size;
  final DeviceBackupFile? device;
  final BackupSetInfo? cloud;
  final bool legacy;

  /// Anything the caller needs back (e.g. a server version map).
  final Object? payload;
  int serial = 0;
}

/// Deletes [items]; returns the ones actually deleted.
typedef BackupDelete = Future<List<BackupListItem>> Function(List<BackupListItem> items);

/// The backups of one place, numbered from the oldest (1) to the newest
/// (highest number, on top), with date, time and size. With [onDelete] a
/// trash button switches to selection: pick any backups and delete them.
class BackupListSheet extends StatefulWidget {
  const BackupListSheet(
      {super.key, required this.title, required this.icon, required this.items, required this.empty, this.onDelete});
  final String title;
  final IconData icon;
  final List<BackupListItem> items;
  final String empty;
  final BackupDelete? onDelete;

  static Future<BackupListItem?> show(BuildContext context,
      {required String title,
      required IconData icon,
      required List<BackupListItem> items,
      required String empty,
      BackupDelete? onDelete}) {
    for (var i = 0; i < items.length; i++) {
      items[i].serial = i + 1;
    }
    return showModalBottomSheet<BackupListItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) =>
          BackupListSheet(title: title, icon: icon, items: items.reversed.toList(), empty: empty, onDelete: onDelete),
    );
  }

  @override
  State<BackupListSheet> createState() => _BackupListSheetState();
}

class _BackupListSheetState extends State<BackupListSheet> {
  late final List<BackupListItem> _items = List.of(widget.items);
  final Set<BackupListItem> _picked = {};
  bool _selecting = false;
  bool _deleting = false;

  Future<void> _delete() async {
    final del = widget.onDelete;
    if (del == null || _picked.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_forever_rounded, color: AppColors.danger, size: 34),
        title: Text(_t('bklDeleteTitle', {'n': '${_picked.length}'}),
            textAlign: TextAlign.center, style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
        content: Text(_t('bklDeleteBody'), textAlign: TextAlign.center, style: const TextStyle(fontFamily: _font, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('cancel'))),
          FilledButton(
            key: const Key('bkl-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_t('bklDelete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    List<BackupListItem> gone = const [];
    try {
      gone = await del(_picked.toList());
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _items.removeWhere(gone.contains);
      final failed = _picked.length - gone.length;
      _picked.clear();
      _selecting = false;
      if (failed > 0) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(_t('bklDeleteFailed', {'n': '$failed'}), style: const TextStyle(fontFamily: _font))));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final canDelete = widget.onDelete != null && items.isNotEmpty;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .78),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 42, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 10, 6),
            child: Row(children: [
              Icon(widget.icon, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_selecting ? _t('bklPickToDelete') : widget.title,
                    style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              if (canDelete)
                _selecting
                    ? TextButton(
                        key: const Key('bkl-cancel-select'),
                        onPressed: _deleting ? null : () => setState(() {
                          _selecting = false;
                          _picked.clear();
                        }),
                        child: Text(_t('cancel'), style: const TextStyle(fontFamily: _font)),
                      )
                    : IconButton(
                        key: const Key('bkl-select'),
                        tooltip: _t('bklDelete'),
                        onPressed: () => setState(() => _selecting = true),
                        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                      ),
            ]),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Text(widget.empty, textAlign: TextAlign.center, style: TextStyle(fontFamily: _font, color: AppColors.textSecondary)),
            )
          else
            Flexible(
              child: ListView.separated(
                key: const Key('bkh-list'),
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final it = items[i];
                  final newest = i == 0 && it.serial == widget.items.first.serial;
                  final picked = _picked.contains(it);
                  return Material(
                    color: picked ? AppColors.danger.withValues(alpha: .06) : AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      key: Key('bkh-item-${it.serial}'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: _deleting
                          ? null
                          : _selecting
                              ? () => setState(() => picked ? _picked.remove(it) : _picked.add(it))
                              : () => Navigator.pop(context, it),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: picked ? AppColors.danger : newest ? AppColors.primary : AppColors.border,
                              width: picked || newest ? 1.5 : 1),
                        ),
                        child: Row(children: [
                          Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: newest ? AppColors.primary : AppColors.primary.withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('${it.serial}',
                                style: TextStyle(
                                    fontFamily: _font,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: newest ? Colors.white : AppColors.primary)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_t('bkhItemName', {'n': '${it.serial}'}) + (newest ? ' · ${_t('bkhNewest')}' : ''),
                                  style: const TextStyle(fontFamily: _font, fontSize: 14, fontWeight: FontWeight.w800)),
                              Text([backupWhen(it.when), backupSize(it.size)].where((e) => e.isNotEmpty).join('  ·  '),
                                  style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary)),
                            ]),
                          ),
                          if (_selecting)
                            Icon(picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                key: Key('bkl-check-${it.serial}'), color: picked ? AppColors.danger : AppColors.border)
                          else
                            Icon(Icons.settings_backup_restore_rounded, color: AppColors.primary),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
          if (_selecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  key: const Key('bkl-delete'),
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: _picked.isEmpty || _deleting ? null : _delete,
                  icon: _deleting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.delete_rounded),
                  label: Text(_t('bklDeleteN', {'n': '${_picked.length}'}),
                      style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
