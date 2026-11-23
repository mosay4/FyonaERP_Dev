import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../data/models/settings_model.dart';
import '../../di/settings_providers.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class TaxSettingsPage extends ConsumerStatefulWidget {
  TaxSettingsPage({super.key});
  @override
  ConsumerState<TaxSettingsPage> createState() => _TaxSettingsPageState();
}

class _TaxSettingsPageState extends ConsumerState<TaxSettingsPage> {
  bool _loading = true;
  final _taxes = <TaxSetting>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(settingsServiceProvider).getTaxSettings();
      _taxes
        ..clear()
        ..addAll(list);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggleActive(int index) async {
    final t = _taxes[index];
    _taxes[index] = t.copyWith(isActive: !t.isActive);
    setState(() {});
    await _save();
  }

  Future<void> _delete(int index) async {
    final confirmed = await showConfirmDialog(context, title: AppLocalizations.of(context).translate('settingsDeleteTheTax'), message: AppLocalizations.of(context).translate('settingsAreYouSureTo2', params: {'nameAr': _taxes[index].nameAr}), danger: true);
    if (confirmed == true) {
      _taxes.removeAt(index);
      setState(() {});
      await _save();
    }
  }

  Future<void> _save() async {
    try {
      await ref.read(settingsServiceProvider).updateTaxSettings(List.from(_taxes));
    } catch (_) {}
  }

  Future<void> _showDialog({int? index}) async {
    final isEdit = index != null;
    final existing = isEdit ? _taxes[index] : null;

    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final nameArCtrl = TextEditingController(text: existing?.nameAr ?? '');
    final rateCtrl = TextEditingController(text: existing?.rate.toString());
    final descCtrl = TextEditingController(text: existing?.description ?? '');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(isEdit ? AppLocalizations.of(context).translate('settingsTaxAdjustment') : AppLocalizations.of(context).translate('settingsAddANewTax'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
        content: SizedBox(
          width: R.dialogWidth(context),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FyonaTextField(
                  controller: nameCtrl,
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('nameEnglish'),
                    labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                    filled: true, fillColor: AppColors.background,
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
                  ),
                ),
                SizedBox(height: 12),
                FyonaTextField(
                  controller: nameArCtrl,
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('nameArabic'),
                    labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                    filled: true, fillColor: AppColors.background,
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
                  ),
                ),
                SizedBox(height: 12),
                BusinessNumberField(
                  controller: rateCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('settingsPercentage'),
                    labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                    filled: true, fillColor: AppColors.background,
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
                  ),
                ),
                SizedBox(height: 12),
                FyonaTextField(
                  controller: descCtrl,
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('description'),
                    labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                    filled: true, fillColor: AppColors.background,
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
            onPressed: () {
              final rate = double.tryParse(rateCtrl.text.trim()) ?? 0;
              if (nameCtrl.text.trim().isEmpty || nameArCtrl.text.trim().isEmpty || rate <= 0) {
                showSnackbar(context, message: AppLocalizations.of(context).translate('settingsPleaseFillOutAll'), color: AppColors.danger);
                return;
              }
              final tax = TaxSetting(
                name: nameCtrl.text.trim(),
                nameAr: nameArCtrl.text.trim(),
                rate: rate,
                description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
              );
              Navigator.pop(ctx);
              setState(() {
                if (isEdit) {
                  _taxes[index] = tax;
                } else {
                  _taxes.add(tax);
                }
              });
              _save();
              showSnackbar(context, message: isEdit ? AppLocalizations.of(context).translate('settingsTheTaxHasBeen') : AppLocalizations.of(context).translate('settingsTaxAdded'));
            },
            child: Text(AppLocalizations.of(context).translate('save')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(AppLocalizations.of(context).translate('settingsTaxes'))),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: () => _showDialog(),
        child: Icon(Icons.add, color: Colors.white),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _taxes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TwoToneIcon(data: TwoToneIcons.money, size: 72, outlineColor: AppColors.textDisabled),
                      SizedBox(height: 16),
                      Text(AppLocalizations.of(context).translate('settingsThereAreNoTaxes'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), color: AppColors.textPrimary)),
                      SizedBox(height: 8),
                      Text(AppLocalizations.of(context).translate('settingsClickTheButtonTo'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.all(16),
                  itemCount: _taxes.length,
                  itemBuilder: (context, index) {
                    final t = _taxes[index];
                    return Container(
                      margin: EdgeInsets.only(bottom: 10),
                      padding: EdgeInsets.all(14),
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
                                Row(
                                  children: [
                                    Text(t.nameAr, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                    SizedBox(width: 8),
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.warning.withAlpha(25),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text('${t.rate.toStringAsFixed(1)}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.bold, color: AppColors.warning)),
                                    ),
                                  ],
                                ),
                                if (t.description != null && t.description!.isNotEmpty) ...[
                                   SizedBox(height: 4),
                                  Text(t.description!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
                                ],
                              ],
                            ),
                          ),
                          Switch(
                            value: t.isActive,
                            activeThumbColor: AppColors.success,
                            onChanged: (_) => _toggleActive(index),
                          ),
                          IconButton(
                            icon: TwoToneIcon(data: TwoToneIcons.edit, size: 18, outlineColor: AppColors.textSecondary),
                            onPressed: () => _showDialog(index: index),
                          ),
                          IconButton(
                            icon: TwoToneIcon(data: TwoToneIcons.delete, size: 18, outlineColor: AppColors.danger),
                            onPressed: () => _delete(index),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
