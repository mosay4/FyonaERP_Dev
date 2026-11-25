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
import '../../../../core/utils/currency_formatter.dart'
    show currencySymbol, currencyName, currencyLabel, currencyCode, currencyFlagEmoji;

class CurrencySettingsPage extends ConsumerStatefulWidget {
  CurrencySettingsPage({super.key});
  @override
  ConsumerState<CurrencySettingsPage> createState() => _CurrencySettingsPageState();
}

class _CurrencySettingsPageState extends ConsumerState<CurrencySettingsPage> {
  bool _loading = true;
  final _currencies = <CurrencySetting>[];
  String _defaultCurrency = 'SAR';

  static final _presetCurrencies = [
    ('SAR', AppLocalizations.t('currency_SAR'), '﷼'),
    ('USD', AppLocalizations.t('currency_USD'), '\$'),
    ('EUR', AppLocalizations.t('currency_EUR'), '€'),
    ('GBP', AppLocalizations.t('currency_GBP'), '£'),
    ('AED', AppLocalizations.t('currency_AED'), AppLocalizations.t('settingsDE')),
    ('EGP', AppLocalizations.t('currency_EGP'), AppLocalizations.t('settingsJM')),
    ('KWD', AppLocalizations.t('currency_KWD'), AppLocalizations.t('settingsKWD')),
    ('QAR', AppLocalizations.t('currency_QAR'), AppLocalizations.t('settingsQR')),
    ('BHD', AppLocalizations.t('currency_BHD'), AppLocalizations.t('settingsBear')),
    ('OMR', AppLocalizations.t('currency_OMR'), AppLocalizations.t('settingsRO')),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(settingsServiceProvider).getCurrencySettings();
      _currencies
        ..clear()
        ..addAll(list);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    try {
      await ref.read(settingsServiceProvider).updateCurrencySettings(List.from(_currencies));
    } catch (_) {}
  }

  Future<void> _updateRate(int index, String val) async {
    final rate = double.tryParse(val);
    if (rate != null && rate > 0) {
      _currencies[index] = _currencies[index].copyWith(rate: rate);
      await _save();
    }
  }

  Future<void> _delete(int index) async {
    final c = _currencies[index];
    final confirmed = await showConfirmDialog(context, title: AppLocalizations.of(context).translate('settingsDeleteCurrency'), message: AppLocalizations.of(context).translate('settingsAreYouSureTo', params: {'currency': c.currency}), danger: true);
    if (confirmed == true) {
      _currencies.removeAt(index);
      setState(() {});
      await _save();
    }
  }

  Future<void> _showAddDialog() async {
    String? selectedCode = 'SAR';
    final rateCtrl = TextEditingController(text: '1.0');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(AppLocalizations.of(context).translate('addCurrency'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
        content: SizedBox(
          width: R.dialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selectedCode,
                dropdownColor: AppColors.surface,
                style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).translate('currencyLabel'),
                  labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                  filled: true, fillColor: AppColors.background,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
                ),
                items: _presetCurrencies
                    .where((p) => !_currencies.any((c) => c.currency == p.$1))
                    .map((p) => DropdownMenuItem(value: p.$1, child: Text('${p.$1} — ${p.$2}')))
                    .toList(),
                onChanged: (v) => selectedCode = v,
              ),
              SizedBox(height: 12),
              BusinessNumberField(
                controller: rateCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).translate('exchangeRate'),
                  labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
                  filled: true, fillColor: AppColors.background,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
            onPressed: () {
              final rate = double.tryParse(rateCtrl.text.trim()) ?? 1.0;
              final entry = _presetCurrencies.firstWhere((p) => p.$1 == selectedCode);
              Navigator.pop(ctx);
              setState(() {
                _currencies.add(CurrencySetting(currency: entry.$1, name: entry.$2, symbol: entry.$3, rate: rate));
              });
              _save();
              showSnackbar(context, message: AppLocalizations.of(context).translate('adminCurrencyAdded'));
            },
            child: Text(AppLocalizations.of(context).translate('add')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).translate('adminCurrencies')),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: AppColors.primary),
            onPressed: _showAddDialog,
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _currencies.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TwoToneIcon(data: TwoToneIcons.transfer, size: 72, outlineColor: AppColors.textDisabled),
                      SizedBox(height: 16),
                      Text(AppLocalizations.of(context).translate('settingsThereAreNoCoins'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), color: AppColors.textPrimary)),
                      SizedBox(height: 8),
                      Text(AppLocalizations.of(context).translate('settingsPressTheButtonTo'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Container(
                      margin: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: AppRadius.mdBorder,
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          Text(AppLocalizations.of(context).translate('settingsDefaultCurrency'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
                          DropdownButton<String>(
                            value: _defaultCurrency,
                            dropdownColor: AppColors.surface,
                            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                            underline: SizedBox(),
                            items: _currencies.map((c) => DropdownMenuItem(value: c.currency, child: Text(currencyName(c.currency)))).toList(),
                            onChanged: (v) {
                              if (v != null) setState(() => _defaultCurrency = v);
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _currencies.length,
                        itemBuilder: (context, index) {
                          final c = _currencies[index];
                          return Container(
                            margin: EdgeInsets.only(bottom: 8),
                            padding: EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: AppRadius.mdBorder,
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 44, height: 44,
                                  decoration: BoxDecoration(
                                    color: AppColors.success.withAlpha(25),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Center(
                                    child: Text(currencyFlagEmoji(c.currency).isEmpty ? currencyCode(c.currency) : currencyFlagEmoji(c.currency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.bold, color: AppColors.success)),
                                  ),
                                ),
                                 SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(currencyLabel(c.currency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                       SizedBox(height: 4),
                                      Row(
                                        children: [
                                           Text(AppLocalizations.of(context).translate('adminExchangeRate'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
                                          SizedBox(
                                            width: 80,
                                            height: 32,
                                            child: BusinessNumberField(
                                              controller: TextEditingController(text: c.rate.toStringAsFixed(4)),
                                              keyboardType: TextInputType.number,
                                              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary),
                                              decoration: InputDecoration(
                                                filled: true, fillColor: AppColors.surfaceVariant,
                                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                                border: OutlineInputBorder(borderSide: BorderSide.none),
                                              ),
                                              onSubmitted: (val) => _updateRate(index, val),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                if (c.currency != _defaultCurrency)
                                  IconButton(
                                    icon: TwoToneIcon(data: TwoToneIcons.delete, size: 18, outlineColor: AppColors.danger),
                                    onPressed: () => _delete(index),
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
