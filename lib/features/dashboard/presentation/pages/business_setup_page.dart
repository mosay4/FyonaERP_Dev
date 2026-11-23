import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../inventory/presentation/providers/warehouse_settings.dart';
import '../../../reports/data/business_report_rates.dart';
import '../../../subscription/presentation/providers/subscription_providers.dart';

/// «تخصيص قسم الأعمال» — a REAL, simple 3-step wizard. Every switch applies to
/// an existing setting immediately; nothing is a placeholder. A pinned bottom
/// bar guarantees «رجوع / التالي / إنشاء قسم الأعمال» are always visible.
class BusinessSetupPage extends ConsumerStatefulWidget {
  const BusinessSetupPage({super.key});
  @override
  ConsumerState<BusinessSetupPage> createState() => _BusinessSetupPageState();
}

class _BusinessSetupPageState extends ConsumerState<BusinessSetupPage> {
  int _step = 0;
  bool _saving = false;
  String _activity = 'grocery';
  String _currency = 'SAR';

  static const _activities = <String, String>{
    'grocery': 'bizActGrocery',
    'electronics': 'bizActElectronics',
    'clothes': 'bizActClothes',
    'restaurant': 'bizActRestaurant',
    'pharmacy': 'bizActPharmacy',
    'other': 'bizActOther',
  };

  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      // Persist the profile locally (never blocks the flow).
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.setString('biz_setup_activity', _activity);
        await sp.setString('biz_setup_currency', _currency);
      } catch (_) {}
      await ref.read(dioProvider).post('/subscription/business-setup/complete');
      ref.invalidate(subscriptionStatusProvider);
      await ref.read(authProvider.notifier).setUsageMode('business');
      if (mounted) context.go(RouteNames.dashboard);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).translate('coreNetworkError'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _next() {
    if (_step < 2) {
      setState(() => _step++);
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(businessReportRateWarmupProvider);
    final l10n = AppLocalizations.of(context);
    final ws = ref.watch(warehouseSettingsProvider);
    final notifier = ref.read(warehouseSettingsProvider.notifier);
    final currencies =
        (ref.watch(enabledCurrenciesProvider).valueOrNull ??
                const <String>['SAR'])
            .toList();
    if (currencies.isNotEmpty && !currencies.contains(_currency)) {
      _currency = currencies.first;
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          l10n.translate('businessSetupTitle'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 16),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: Column(
        children: [
          // Step indicator
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  Expanded(
                    child: Container(
                      height: 5,
                      decoration: BoxDecoration(
                        color: i <= _step
                            ? AppColors.primary
                            : AppColors.border,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  if (i < 2) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l10n.translate('bizSetupIntro'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: switch (_step) {
                0 => _activityStep(l10n, currencies),
                1 => _stockStep(l10n, ws, notifier),
                _ => _numbersStep(l10n, ws, notifier),
              },
            ),
          ),
          // Pinned action bar — always visible, never clipped.
          Container(
            padding: EdgeInsets.fromLTRB(
              16,
              10,
              16,
              12 + MediaQuery.of(context).padding.bottom,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                if (_step > 0)
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() => _step--),
                        child: Text(
                          l10n.translate('back'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_step > 0) const SizedBox(width: 10),
                Expanded(
                  flex: _step > 0 ? 1 : 2,
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                      ),
                      onPressed: _saving ? null : _next,
                      child: Text(
                        l10n.translate(_step == 2 ? 'bizSetupCreate' : 'next'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13.5),
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    // A plain Row (NOT SwitchListTile) — a ListTile inside a coloured card
    // trips the "ListTile ... in a DecoratedBox" assertion and can hide ink.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            activeColor: AppColors.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _activityStep(AppLocalizations l10n, List<String> currencies) {
    return Column(
      children: [
        _card(
          title: l10n.translate('bizSetupActivityTitle'),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in _activities.entries)
                  ChoiceChip(
                    label: Text(
                      l10n.translate(e.value),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                      ),
                    ),
                    selected: _activity == e.key,
                    onSelected: (_) => setState(() => _activity = e.key),
                  ),
              ],
            ),
          ],
        ),
        _card(
          title: l10n.translate('bizSetupCurrencyTitle'),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in currencies)
                  ChoiceChip(
                    label: Text(
                      c,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                      ),
                    ),
                    selected: _currency == c,
                    onSelected: (_) => setState(() => _currency = c),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _stockStep(
    AppLocalizations l10n,
    WarehouseSettings ws,
    WarehouseSettingsNotifier n,
  ) {
    return _card(
      title: l10n.translate('bizSetupStockTitle'),
      children: [
        _switch(
          l10n.translate('bizSetupUseStock'),
          ws.extraOptions,
          n.setExtraOptions,
        ),
        _switch(l10n.translate('bizSetupBarcode'), ws.barcode, n.setBarcode),
        _switch(l10n.translate('bizSetupLow'), ws.lowStockAlert, n.setLowStock),
        _switch(l10n.translate('bizSetupExpiry'), ws.expiry, n.setExpiry),
      ],
    );
  }

  Widget _numbersStep(
    AppLocalizations l10n,
    WarehouseSettings ws,
    WarehouseSettingsNotifier n,
  ) {
    return _card(
      title: l10n.translate('bizSetupNumbersTitle'),
      children: [
        _switch(
          l10n.translate('bizSetupImages'),
          ws.productImages,
          n.setProductImages,
        ),
        _switch(l10n.translate('bizSetupCostProfit'), ws.showCost, (v) {
          n.setShowCost(v);
          n.setShowProfit(v);
        }),
        _switch(
          l10n.translate('bizSetupMultiCcy'),
          ws.multiCurrency,
          n.setMultiCurrency,
        ),
      ],
    );
  }
}
