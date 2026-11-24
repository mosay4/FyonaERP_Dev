import 'package:flutter/material.dart';

import '../two_tone_icon.dart';

/// Selector value meaning "the whole bank — every currency together".
const String kBankAllCurrencies = '*';

/// One account of the bank, already normalised by the page (personal or
/// business) so the shared detail view and the PDF never care where the data
/// came from.
class BankDetailAccount {
  final String id;
  final String currency;
  final String typeLabel;
  final double balance;
  final String? note;

  const BankDetailAccount({
    required this.id,
    required this.currency,
    required this.typeLabel,
    required this.balance,
    this.note,
  });
}

/// One movement (deposit, withdrawal, transfer, ...) of the bank.
class BankDetailMovement {
  final String id;
  final String accountId;
  final String currency;
  final bool isIn;
  final double amount;
  final DateTime? date;

  /// Localised kind of the movement (e.g. «إيداع», «تحويل وارد»).
  final String title;

  /// Localised category, when the source has one (personal transactions).
  final String? category;

  /// Free text the user typed.
  final String? note;
  final Color color;
  final TwoToneIconData icon;

  const BankDetailMovement({
    required this.id,
    required this.accountId,
    required this.currency,
    required this.isIn,
    required this.amount,
    required this.date,
    required this.title,
    required this.color,
    required this.icon,
    this.category,
    this.note,
  });

  /// Grouping key for the in/out breakdown.
  String get breakdownKey =>
      (category != null && category!.trim().isNotEmpty) ? category! : title;
}

/// What the owner wants inside the exported PDF.
enum BankReportContent { full, summary, movements, flow }

class BankReportRequest {
  final BankReportContent content;

  /// `true` → the whole bank (one section per currency);
  /// `false` → only the currency selected on screen.
  final bool allCurrencies;

  const BankReportRequest({required this.content, required this.allCurrencies});

  bool get withSummary =>
      content == BankReportContent.full || content == BankReportContent.summary;
  bool get withFlow =>
      content == BankReportContent.full || content == BankReportContent.flow;
  bool get withMovements =>
      content == BankReportContent.full ||
      content == BankReportContent.movements;
}

/// Figures of one currency (or of the whole bank converted to the wallet
/// currency when [currency] is [kBankAllCurrencies]) for one period.
class BankCurrencyFigures {
  final String currency;

  /// Currency the totals are expressed in ([currency] itself, or the wallet
  /// currency for the whole-bank view).
  final String displayCurrency;
  final double balance;
  final double totalIn;
  final double totalOut;
  final List<BankDetailAccount> accounts;

  /// Newest first.
  final List<BankDetailMovement> movements;
  final Map<String, double> inByKey;
  final Map<String, double> outByKey;
  final Map<int, double> dailyIn;
  final Map<int, double> dailyOut;

  const BankCurrencyFigures({
    required this.currency,
    required this.displayCurrency,
    required this.balance,
    required this.totalIn,
    required this.totalOut,
    required this.accounts,
    required this.movements,
    required this.inByKey,
    required this.outByKey,
    required this.dailyIn,
    required this.dailyOut,
  });

  bool get isAll => currency == kBankAllCurrencies;
  double get net => totalIn - totalOut;
  int get count => movements.length;
  int get inCount => movements.where((m) => m.isIn).length;
  int get outCount => count - inCount;

  /// [periodMovements] must already be limited to the period on screen.
  /// [toWallet] converts an amount of `from` into [walletCurrency]; it is only
  /// used for the whole-bank view.
  static BankCurrencyFigures compute({
    required String currency,
    required String walletCurrency,
    required List<BankDetailAccount> accounts,
    required List<BankDetailMovement> periodMovements,
    required double Function(double amount, String from) toWallet,
  }) {
    final all = currency == kBankAllCurrencies;
    double value(double amount, String from) =>
        all ? toWallet(amount, from) : amount;
    final accs =
        all ? accounts : accounts.where((a) => a.currency == currency).toList();
    final moves = (all
            ? List<BankDetailMovement>.of(periodMovements)
            : periodMovements.where((m) => m.currency == currency).toList())
      ..sort((a, b) {
        final da = a.date, db = b.date;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });
    var balance = 0.0, totalIn = 0.0, totalOut = 0.0;
    for (final a in accs) {
      balance += value(a.balance, a.currency);
    }
    final inByKey = <String, double>{}, outByKey = <String, double>{};
    final dailyIn = <int, double>{}, dailyOut = <int, double>{};
    for (final m in moves) {
      final v = value(m.amount.abs(), m.currency);
      final day = m.date?.day;
      if (m.isIn) {
        totalIn += v;
        inByKey[m.breakdownKey] = (inByKey[m.breakdownKey] ?? 0) + v;
        if (day != null) dailyIn[day] = (dailyIn[day] ?? 0) + v;
      } else {
        totalOut += v;
        outByKey[m.breakdownKey] = (outByKey[m.breakdownKey] ?? 0) + v;
        if (day != null) dailyOut[day] = (dailyOut[day] ?? 0) + v;
      }
    }
    return BankCurrencyFigures(
      currency: currency,
      displayCurrency: all ? walletCurrency : currency,
      balance: balance,
      totalIn: totalIn,
      totalOut: totalOut,
      accounts: accs,
      movements: moves,
      inByKey: inByKey,
      outByKey: outByKey,
      dailyIn: dailyIn,
      dailyOut: dailyOut,
    );
  }
}

/// Distinct currencies of a bank, wallet currency first, then by account
/// count, then alphabetically.
List<String> bankCurrencies(List<BankDetailAccount> accounts,
    List<BankDetailMovement> movements, String walletCurrency) {
  final count = <String, int>{};
  for (final a in accounts) {
    count[a.currency] = (count[a.currency] ?? 0) + 1;
  }
  for (final m in movements) {
    count.putIfAbsent(m.currency, () => 0);
  }
  final list = count.keys.where((c) => c.trim().isNotEmpty).toList()
    ..sort((a, b) {
      if (a == walletCurrency) return -1;
      if (b == walletCurrency) return 1;
      final byCount = count[b]!.compareTo(count[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return list;
}

/// Everything the PDF needs, prepared by the detail view from exactly the
/// figures it shows on screen.
class BankReportBundle {
  final String bankName;
  final String period;
  final String walletCurrency;
  final BankReportRequest request;

  /// One section per currency in the report scope.
  final List<BankCurrencyFigures> sections;

  /// Whole bank converted to [walletCurrency] — only when the scope spans
  /// more than one currency.
  final BankCurrencyFigures? combined;
  final int accountCount;

  const BankReportBundle({
    required this.bankName,
    required this.period,
    required this.walletCurrency,
    required this.request,
    required this.sections,
    required this.combined,
    required this.accountCount,
  });
}
