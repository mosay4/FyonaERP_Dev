import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/services/currency/currency_engine.dart';
import '../../../../../shared/providers/current_user_provider.dart';
import '../../../data/models/personal_models.dart';
import '../../providers/personal_providers.dart';
import 'personal_report_data.dart';
import '../../../../../core/services/currency/enabled_currencies_service.dart';

/// Where the Personal reports read from: the same providers the Personal
/// pages use (device-first), valued with the app's currency engine.
class PersonalReportSource {
  PersonalReportSource._();

  static String _prefKey(WidgetRef ref) {
    final id = ref.read(currentUserProvider)?.id ?? '';
    return 'personal_report_currency_${id.isEmpty ? 'anonymous' : id}';
  }

  /// The report currency the user chose last (defaults to the wallet's).
  static Future<String?> savedCurrency(WidgetRef ref) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefKey(ref));
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveCurrency(WidgetRef ref, String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey(ref), code);
    } catch (_) {}
  }

  /// Reads everything the reports need (local mirror first; never blocks on
  /// the network for long).
  static Future<void> warm(WidgetRef ref) async {
    Future<void> guard(Future<void> Function() run) async {
      try {
        await run().timeout(const Duration(seconds: 6));
      } catch (_) {}
    }

    await Future.wait([
      guard(() => ref.read(personalFinanceProvider.notifier).load()),
      guard(() => ref.read(budgetProvider.notifier).load()),
      guard(() => ref.read(currencyEngineProvider).load()),
    ]);
  }

  /// Approved device rate first (same engine as every Personal total), then
  /// the user's own saved rates (direct or inverse).
  static PersonalReportRate rateOf(
    CurrencyEngine engine,
    List<ExchangeRate> manual,
  ) {
    return (from, to) {
      try {
        final r = engine.getRate(from, to);
        if (r != null && r.isFinite && r > 0) return r;
      } catch (_) {}
      for (final m in manual) {
        if (m.fromCurrency.toUpperCase() == from &&
            m.toCurrency.toUpperCase() == to &&
            m.rate > 0) {
          return m.rate;
        }
      }
      for (final m in manual) {
        if (m.fromCurrency.toUpperCase() == to &&
            m.toCurrency.toUpperCase() == from &&
            m.rate > 0) {
          return 1 / m.rate;
        }
      }
      return null;
    };
  }

  static PersonalReportData build(
    WidgetRef ref, {
    required String currency,
    required PersonalReportWindow window,
  }) {
    final st = ref.read(personalFinanceProvider);
    final budgets = ref.read(budgetProvider).budgets;
    final engine = ref.read(currencyEngineProvider);
    return PersonalReportData.build(
      currency: currency,
      window: window,
      rate: rateOf(engine, st.exchangeRates),
      transactions: st.transactions,
      banks: st.bankAccounts,
      goals: st.savingsGoals,
      budgets: budgets,
      debts: st.debts,
      otherLabel: AppLocalizations.t('repExpenseOther'),
    );
  }

  /// The user's own currencies (accounts, operations, goals, debts, budgets),
  /// most used first.
  static List<String> mine(WidgetRef ref) {
    final st = ref.read(personalFinanceProvider);
    final count = <String, int>{};
    void add(String c, [int n = 1]) {
      final code = c.trim().toUpperCase();
      if (code.isEmpty) return;
      count[code] = (count[code] ?? 0) + n;
    }

    add(st.walletCurrency, 1000);
    for (final b in st.bankAccounts) {
      add(b.currency, 50);
    }
    for (final t in st.transactions) {
      add(t.currency);
    }
    for (final g in st.savingsGoals) {
      add(g.currency, 5);
    }
    for (final d in st.debts) {
      add(d.currency, 5);
    }
    for (final b in ref.read(budgetProvider).budgets) {
      add(b.currency, 5);
    }
    final out = count.keys.toList()
      ..sort((a, b) => count[b]!.compareTo(count[a]!));
    return out;
  }

  /// The currencies the user enabled for Personal (Profile › preferences):
  /// the only ones the report currency picker offers.
  static Future<List<String>> enabled(WidgetRef ref) async {
    final userId = ref.read(currentUserIdProvider);
    final set = await loadEnabledCurrencies(userId);
    final order = mine(ref);
    final list = set.map((c) => c.trim().toUpperCase()).toSet().toList()
      ..sort((a, b) {
        final ia = order.indexOf(a), ib = order.indexOf(b);
        if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
        if (ia >= 0) return -1;
        if (ib >= 0) return 1;
        return a.compareTo(b);
      });
    return list;
  }

  /// Every currency this device can value right now.
  static List<String> all(WidgetRef ref) {
    final engine = ref.read(currencyEngineProvider);
    // Only currencies with an approved rate: a report in a currency the
    // device cannot value would leave every amount out.
    final codes = <String>{...engine.availableCurrencies}..remove('YER');
    final list = codes.toList()..sort();
    return list;
  }
}
