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

class CustomFieldsPage extends ConsumerStatefulWidget {
  CustomFieldsPage({super.key});
  @override
  ConsumerState<CustomFieldsPage> createState() => _CustomFieldsPageState();
}

class _CustomFieldsPageState extends ConsumerState<CustomFieldsPage> {
  String _selectedResource = 'customer';
  final _fields = <Map<String, dynamic>>[];

  final _resources = {
    'customer': AppLocalizations.t('customers'),
    'supplier': AppLocalizations.t('settingsSuppliers'),
    'product': AppLocalizations.t('products'),
    'employee': AppLocalizations.t('reportsStaff'),
    'sales_invoice': AppLocalizations.t('dataImportSalesInvoices'),
    'expense': AppLocalizations.t('expenses'),
  };

  final _fieldTypes = {
    'text': AppLocalizations.t('settingsText'),
    'number': AppLocalizations.t('settingsNumber'),
    'date': AppLocalizations.t('settingsDate'),
    'dropdown': AppLocalizations.t('settingsDropDownList'),
    'checkbox': AppLocalizations.t('settingsCheckbox'),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).translate('settingsCustomFields')),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: AppColors.primary),
            onPressed: () => _showFieldDialog(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
            child: DropdownButtonFormField<String>(
              initialValue: _selectedResource,
              dropdownColor: AppColors.surface,
              style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: R.font(context)),
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context).translate('settingsResources'),
                labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
                focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary)),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              items: _resources.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) {
                if (v != null) setState(() => _selectedResource = v);
              },
            ),
          ),
          Expanded(
            child: _fields.isEmpty
                ? Center(
                    child: Text(AppLocalizations.of(context).translate('settingsThereAreNoCustom'),
                        style: TextStyle(fontFamily: 'Cairo', color: AppColors.textDisabled)),
                  )
                : ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: R.spacing(context, AppSpacing.md)),
                    itemCount: _fields.length,
                    itemBuilder: (context, index) {
                      final f = _fields[index];
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
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(f['label'] ?? '', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                                  SizedBox(height: 2),
                                  Text('@${f['name']} — ${_fieldTypes[f['type']] ?? f['type']}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary)),
                                  Text(f['required'] == true ? AppLocalizations.of(context).translate('settingsRequired') : AppLocalizations.of(context).translate('optional'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: f['required'] == true ? AppColors.primary : AppColors.textDisabled)),
                                ],
                              ),
                            ),
                            IconButton(icon: TwoToneIcon(data: TwoToneIcons.edit, size: 18, outlineColor: AppColors.textSecondary), onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsEditingWillOpenSoon'))),
                            IconButton(icon: TwoToneIcon(data: TwoToneIcons.delete, size: 18, outlineColor: AppColors.danger), onPressed: () async {
                              final ok = await showConfirmDialog(context, title: AppLocalizations.of(context).translate('settingsDeleteField'), message: AppLocalizations.of(context).translate('areYouSure'));
                              if (ok == true && mounted) {
                                setState(() => _fields.removeAt(index));
                                showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheFieldHasBeen'));
                              }
                            }),
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

  void _showFieldDialog({bool edit = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(edit ? AppLocalizations.of(context).translate('settingsModifyAField') : AppLocalizations.of(context).translate('settingsAddANewField'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
        content: SizedBox(
          width: R.dialogWidth(context),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FyonaTextField(
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('settingsNameInLatinWithout'),
                    labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary)),
                  ),
                ),
                SizedBox(height: R.spacing(context, AppSpacing.sm)),
                FyonaTextField(
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('settingsNamingInArabic'),
                    labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary)),
                  ),
                ),
                SizedBox(height: R.spacing(context, AppSpacing.sm)),
                DropdownButtonFormField<String>(
                  initialValue: 'text',
                  dropdownColor: AppColors.surface,
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('settingsFieldType'),
                    labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary)),
                  ),
                  items: _fieldTypes.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheTypeHasBeen')),
                ),
                SizedBox(height: R.spacing(context, AppSpacing.sm)),
                CheckboxListTile(
                  title: Text(AppLocalizations.of(context).translate('settingsRequired'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
                  value: false,
                  activeColor: AppColors.primary,
                  onChanged: (v) => showSnackbar(context, message: v == true ? AppLocalizations.of(context).translate('settingsSelected') : AppLocalizations.of(context).translate('settingsCanceled')),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
            onPressed: () { Navigator.pop(ctx); showSnackbar(context, message: AppLocalizations.of(context).translate('settingsFieldAdded')); },
            child: Text(AppLocalizations.of(context).translate('save')),
          ),
        ],
      ),
    );
  }
}
