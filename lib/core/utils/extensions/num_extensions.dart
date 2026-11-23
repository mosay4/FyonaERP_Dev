import 'package:intl/intl.dart';

import '../currency_formatter.dart';

extension NumExtensions on num {
  String formatCurrency({String symbol = 'ريال', int decimalDigits = 2}) {
    final formatter = NumberFormat.currency(
      symbol: symbol,
      decimalDigits: decimalDigits,
      locale: 'ar',
    );
    return formatter.format(this);
  }

  String formatNumber({int decimalDigits = 2}) {
    return fmtNum(this);
  }

  String formatCompact() {
    if (this >= 1000000) {
      return '${fmtNum(this / 1000000)}M';
    } else if (this >= 1000) {
      return '${fmtNum(this / 1000)}K';
    }
    return fmtNum(this);
  }

  bool get isPositive => this > 0;
  bool get isNegative => this < 0;
  bool get isZero => this == 0;
}
