import 'package:flutter/material.dart';
import 'business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../../shared/widgets/business_selection_sheet.dart';
import '../../../personal/data/merchant_api.dart';
import '../../../purchases/presentation/providers/purchase_providers.dart';
import 'debt_widgets.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Simple «add a supplier/customer with an opening debt» form for the DEBTS
/// lists: name + optional phone + the opening balance and its currency. The
/// party is created first, then one confirmed opening invoice so it behaves
/// exactly like every other debtor/supplier from that moment.
Future<bool> showAddPartyDebtSheet(
  BuildContext context,
  WidgetRef ref, {
  required bool isSupplier,
  List<String> existingNames = const [],
  Future<void> Function(
    String name,
    String phone,
    String amount,
    String currency,
  )?
  saveLocal,
  String Function(Object error)? localError,
}) async {
  final l10n = AppLocalizations.of(context);
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final amountCtrl = TextEditingController();
  final userId = ref.read(currentUserIdProvider);
  var currencies = <String>[];
  try {
    currencies = (await loadEnabledCurrencies(userId)).toList()..sort();
  } catch (_) {}
  var currency = '';
  try {
    currency = await resolveDefaultCurrency(userId);
  } catch (_) {}
  if (currency.isEmpty)
    currency = currencies.isNotEmpty ? currencies.first : 'SAR';

  if (!context.mounted) {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    amountCtrl.dispose();
    return false;
  }

  String? err;
  bool confirmed = false;
  final navigator = Navigator.of(context);
  final material = MaterialLocalizations.of(context);
  final route = ModalBottomSheetRoute<bool>(
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    barrierLabel: material.scrimLabel,
    barrierOnTapHint: material.scrimOnTapHint(material.bottomSheetLabel),
    modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          16,
          14,
          16,
          16 + MediaQuery.of(ctx).padding.bottom,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSt) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      DebtIcon(
                        isSupplier
                            ? Icons.local_shipping_outlined
                            : Icons.person_add_alt_1_outlined,
                        size: 40,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.translate(
                            isSupplier
                                ? 'bizAddSupplierNew'
                                : 'bizAddCustomerNew',
                          ),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FyonaTextField(
                    controller: nameCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l10n.translate(
                        isSupplier ? 'purSupplierName' : 'purSupplierName',
                      ),
                      labelStyle: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                      ),
                    ),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                  const SizedBox(height: 10),
                  FyonaTextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l10n.translate('purSupplierPhoneOpt'),
                      labelStyle: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                      ),
                    ),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: BusinessNumberField(
                          controller: amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [AmountInputFormatter()],
                          decoration: InputDecoration(
                            labelText: l10n.translate('debtOpeningAmountLabel'),
                            labelStyle: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                            ),
                          ),
                          style: const TextStyle(fontFamily: 'Cairo'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () async {
                            final options = currencies.isEmpty
                                ? [currency]
                                : currencies;
                            final picked =
                                await showBusinessSelectionSheet<String>(
                                  context: ctx,
                                  title: l10n.translate('currencyLabel'),
                                  selected: currency,
                                  items: [
                                    for (final c in options)
                                      BizSheetItem(
                                        value: c,
                                        title: debtCurrencyLabel(c),
                                        subtitle: c,
                                        icon: Icons.monetization_on_outlined,
                                      ),
                                  ],
                                );
                            if (picked != null) setSt(() => currency = picked);
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: l10n.translate('currencyLabel'),
                              labelStyle: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11.5,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    debtCurrencyLabel(currency),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const Icon(Icons.expand_more_rounded, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 6),
                      child: Text(
                        l10n.translate(err!),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          height: 1.35,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: DebtStyle.red,
                        minimumSize: const Size(0, 54),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        if (confirmed) return;
                        final name = nameCtrl.text.trim();
                        final amount =
                            parseFormattedAmount(amountCtrl.text) ?? 0;
                        if (name.isEmpty) {
                          setSt(() => err = 'debtOpeningMissing');
                          return;
                        }
                        final dup = existingNames.any(
                          (n) => n.trim().toLowerCase() == name.toLowerCase(),
                        );
                        if (dup) {
                          setSt(
                            () => err = isSupplier
                                ? 'debtDuplicateSupplier'
                                : 'debtDuplicateCustomer',
                          );
                          return;
                        }
                        if (amount < 0) {
                          setSt(() => err = 'debtOpeningMissing');
                          return;
                        }
                        confirmed = true;
                        Navigator.pop(ctx, true);
                      },
                      child: Text(
                        l10n.translate('save'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          height: 1.4,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );

  final ok = await navigator.push(route);
  final name = nameCtrl.text.trim();
  final phone = phoneCtrl.text.trim();
  final typedAmount = amountCtrl.text.replaceAll(',', '').trim();
  final amount = parseFormattedAmount(amountCtrl.text) ?? 0;
  route.completed.whenComplete(() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    amountCtrl.dispose();
  });
  // A party may be added WITHOUT an opening debt (amount = 0).
  if (ok != true || name.isEmpty || !context.mounted) {
    return false;
  }

  try {
    if (saveLocal != null) {
      await saveLocal(
        name,
        phone,
        typedAmount.isEmpty ? '0' : typedAmount,
        currency,
      );
      if (context.mounted) {
        showFyonaSnack(
          context,
          l10n.translate('debtPartyAdded'),
          success: true,
        );
      }
      return true;
    }
    final purchases = ref.read(purchaseApiProvider);
    final created = isSupplier
        ? await purchases.createSupplier(
            name: name,
            phone: phone.isEmpty ? null : phone,
          )
        : await purchases.createCustomer(
            name: name,
            phone: phone.isEmpty ? null : phone,
          );
    final id = '${created['id'] ?? ''}';
    if (id.isEmpty) throw Exception('create');
    var debtOk = true;
    if (amount > 0) {
      try {
        await ref
            .read(merchantApiProvider)
            .createOpeningDebt(
              partyKind: isSupplier ? 'supplier' : 'customer',
              partyId: id,
              amount: amount,
              currency: currency,
            );
      } catch (_) {
        // The party IS created; never pretend it failed (the list reloads).
        debtOk = false;
      }
    }
    if (context.mounted) {
      showFyonaSnack(
        context,
        l10n.translate(debtOk ? 'debtPartyAdded' : 'debtOpeningFailed'),
        success: debtOk,
      );
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      showFyonaSnack(
        context,
        localError?.call(error) ?? l10n.translate('debtPartyDeleteFailed'),
        success: false,
      );
    }
    return false;
  }
}
