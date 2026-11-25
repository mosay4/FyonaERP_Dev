import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/currency/business_currency_scope.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_formatter.dart';
import '../providers/current_user_provider.dart';
import 'business_selection_sheet.dart';

/// Exactly the Business currencies enabled in profile settings (sorted) —
/// the single list every Business currency picker offers.
Future<List<String>> readBizCurrencies(WidgetRef ref) async {
  Set<String> codes;
  try {
    // A slow link must never freeze a picker: fall back to the saved set.
    codes = await ref
        .read(bizEnabledCurrenciesProvider.future)
        .timeout(const Duration(seconds: 3));
  } catch (_) {
    codes = await loadBizEnabledCurrencies(ref.read(currentUserIdProvider));
  }
  return codes.toList()..sort();
}

/// Country flag badge (same emoji flags as the rest of the app); the code
/// when a currency has no flag.
Widget bizCurrencyFlag(String code, {double size = 42}) {
  final flag = currencyFlagEmoji(code);
  return Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: AppColors.surfaceVariant,
      border: Border.all(color: AppColors.border, width: .6),
    ),
    child: Text(
      flag.isEmpty ? currencyShort(code) : flag,
      style: TextStyle(
        fontFamily: flag.isEmpty ? 'Cairo' : null,
        fontSize: flag.isEmpty ? 10 : size * .5,
        fontWeight: FontWeight.w800,
        color: AppColors.primary,
      ),
    ),
  );
}

/// Sheet rows for [codes]: flag + currency name, code as subtitle.
List<BizSheetItem<String>> bizCurrencySheetItems(Iterable<String> codes) => [
      for (final c in codes)
        BizSheetItem<String>(
          value: c,
          title: currencyName(c),
          subtitle: currencyShort(c),
          leading: bizCurrencyFlag(c),
        ),
    ];

/// Invoice-currency choices: the payment accounts' currencies limited to the
/// Business enabled set (a disabled currency is never offered). Falls back to
/// [accountCurrencies] only when none of them is enabled, so invoicing is
/// never blocked.
Future<List<String>> limitToBizCurrencies(
  WidgetRef ref,
  Iterable<String> accountCurrencies,
) async {
  final all = {for (final c in accountCurrencies) c.toUpperCase()};
  final enabled = (await readBizCurrencies(ref)).toSet();
  final kept = all.where(enabled.contains).toList()..sort();
  return kept.isNotEmpty ? kept : (all.toList()..sort());
}
