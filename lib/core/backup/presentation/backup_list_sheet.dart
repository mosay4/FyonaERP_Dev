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

/// The backups of one place, numbered from the oldest (1) to the newest
/// (highest number, on top), with date, time and size.
class BackupListSheet extends StatelessWidget {
  const BackupListSheet({super.key, required this.title, required this.icon, required this.items, required this.empty});
  final String title;
  final IconData icon;
  final List<BackupListItem> items;
  final String empty;

  static Future<BackupListItem?> show(BuildContext context,
      {required String title, required IconData icon, required List<BackupListItem> items, required String empty}) {
    for (var i = 0; i < items.length; i++) {
      items[i].serial = i + 1;
    }
    return showModalBottomSheet<BackupListItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => BackupListSheet(title: title, icon: icon, items: items.reversed.toList(), empty: empty),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .75),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 10),
            Container(width: 42, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Row(children: [
                Icon(icon, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800)),
              ]),
            ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(28),
                child: Text(empty, textAlign: TextAlign.center, style: TextStyle(fontFamily: _font, color: AppColors.textSecondary)),
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
                    final newest = i == 0;
                    return Material(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        key: Key('bkh-item-${it.serial}'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => Navigator.pop(context, it),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: newest ? AppColors.primary : AppColors.border, width: newest ? 1.5 : 1),
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
                            Icon(Icons.settings_backup_restore_rounded, color: AppColors.primary),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ]),
        ),
      );
}

