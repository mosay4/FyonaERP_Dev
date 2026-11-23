import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';

class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key});
  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage> {
  final _files = <Map<String, dynamic>>[];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).translate('settingsMyFiles')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.primary),
            onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsFilesHaveBeenUpdated')),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(AppLocalizations.of(context).translate('settingsFiles'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
                  onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheFileHasBeen')),
                  icon: const TwoToneIcon(data: TwoToneIcons.folder, size: 40, outlineColor: AppColors.textDisabled),
                  label: Text(AppLocalizations.of(context).translate('settingsUploadAFile')),
                ),
              ],
            ),
          ),
          Expanded(
            child: _files.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const TwoToneIcon(data: TwoToneIcons.folder, size: 40, outlineColor: AppColors.textDisabled),
                        SizedBox(height: R.spacing(context, AppSpacing.sm)),
                        Text(AppLocalizations.of(context).translate('settingsThereAreNoFiles'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textDisabled)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: R.spacing(context, AppSpacing.md)),
                    itemCount: _files.length,
                    itemBuilder: (context, index) {
                      final f = _files[index];
                      return Container(
                        margin: EdgeInsets.only(bottom: R.spacing(context, AppSpacing.sm)),
                        padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppRadius.mdBorder,
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(color: AppColors.info, borderRadius: AppRadius.smBorder),
                              child: TwoToneIcon(data: TwoToneIcons.file, size: 18, outlineColor: Colors.white),
                            ),
                            SizedBox(width: R.gap(context)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(f['name'] ?? '', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                                  Text('${f['size'] ?? ''} • ${f['date'] ?? ''}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: TwoToneIcon(data: TwoToneIcons.delete, size: 18, outlineColor: AppColors.danger),
                              onPressed: () async {
                                final ok = await showConfirmDialog(context, title: AppLocalizations.of(context).translate('settingsDeleteTheFile'), message: AppLocalizations.of(context).translate('areYouSure'));
                                if (ok == true && mounted) {
                                  setState(() => _files.removeAt(index));
                                  showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheFileHasBeen2'));
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
