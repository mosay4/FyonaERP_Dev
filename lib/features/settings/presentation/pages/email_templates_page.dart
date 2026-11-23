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
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class EmailTemplatesPage extends ConsumerStatefulWidget {
  EmailTemplatesPage({super.key});
  @override
  ConsumerState<EmailTemplatesPage> createState() => _EmailTemplatesPageState();
}

class _EmailTemplatesPageState extends ConsumerState<EmailTemplatesPage> {
  bool _showForm = false;
  final _templates = <Map<String, dynamic>>[];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).translate('settingsMailTemplates')),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: AppColors.primary),
            onPressed: () => setState(() => _showForm = !_showForm),
          ),
        ],
      ),
      body: _showForm ? _buildForm() : _buildList(),
    );
  }

  Widget _buildList() {
    if (_templates.isEmpty) {
      return Center(
        child: Text(AppLocalizations.of(context).translate('settingsThereAreNoMail'),
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textDisabled)),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
      itemCount: _templates.length,
      itemBuilder: (context, index) {
        final t = _templates[index];
        return Container(
          margin: EdgeInsets.only(bottom: R.spacing(context, AppSpacing.xs)),
          padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.mdBorder,
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              TwoToneIcon(data: TwoToneIcons.share, size: 20, outlineColor: AppColors.primary),
              SizedBox(width: R.gap(context)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t['name'] ?? '', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    Text(t['subject'] ?? '', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textSecondary)),
                  ],
                ),
              ),
              IconButton(
                icon: TwoToneIcon(data: TwoToneIcons.delete, size: 18, outlineColor: AppColors.danger),
                onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheTemplateHasBeen')),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(R.spacing(context, AppSpacing.lg)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context).translate('settingsAddANewTemplate'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          FyonaTextField(
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).translate('designStudioTemplateName'),
              labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.surface,
              border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary)),
            ),
          ),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          FyonaTextField(
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).translate('settingsMailAddress'),
              labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.surface,
              border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary)),
            ),
          ),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          FyonaTextField(
            maxLines: 5,
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).translate('settingsMailText'),
              labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.surface,
              border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary)),
              alignLabelWithHint: true,
            ),
          ),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          Text(AppLocalizations.of(context).translate('settingsAvailableVariants'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textDisabled)),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          SizedBox(
            width: double.infinity,
            height: R.buttonHeight(context),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
              onPressed: () {
                setState(() => _showForm = false);
                showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheTemplateHasBeen2'));
              },
              child: Text(AppLocalizations.of(context).translate('designStudioSaveTheTemplate')),
            ),
          ),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          SizedBox(
            width: double.infinity,
            height: R.buttonHeight(context),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.textSecondary, side: BorderSide(color: AppColors.border), shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
              onPressed: () => setState(() => _showForm = false),
              child: Text(AppLocalizations.of(context).translate('cancel')),
            ),
          ),
        ],
      ),
    );
  }
}
