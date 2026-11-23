/// Generic account/currency mismatch support for Sara financial writes.
///
/// No hardcoded account names or currency codes anywhere: every option is
/// derived from the user's real bank-account rows and the real FX engine.
/// A mismatch never writes, never converts, and never picks another account
/// or currency — it only describes valid choices for the user to pick from.
class MismatchFxOption {
  final String currency;
  final String accountId;
  final String accountName;
  final double rate;
  final double converted;
  const MismatchFxOption({
    required this.currency,
    required this.accountId,
    required this.accountName,
    required this.rate,
    required this.converted,
  });
}

class MismatchSibling {
  final String accountId;
  final String accountName;
  final String currency;
  const MismatchSibling({
    required this.accountId,
    required this.accountName,
    required this.currency,
  });
}

class MismatchChoice {
  final String kind; // 'fx' | 'account' | 'cancel' | 'unknown'
  final MismatchFxOption? fx;
  final MismatchSibling? sibling;
  const MismatchChoice._(this.kind, {this.fx, this.sibling});
  const MismatchChoice.fx(MismatchFxOption o) : this._('fx', fx: o);
  const MismatchChoice.account(MismatchSibling s) : this._('account', sibling: s);
  static const cancel = MismatchChoice._('cancel');
  static const unknown = MismatchChoice._('unknown');
}

/// Ordered, numbered options: FX conversions into the target account's own
/// currencies first, then sibling accounts that natively support the
/// requested currency. Numbers are 1-based in display order.
class MismatchOptions {
  final String accountId;
  final String accountName;
  final String accountCurrency;
  final String requestedCurrency;
  final double amount;
  final List<MismatchFxOption> fxOptions;
  final List<MismatchSibling> siblings;
  const MismatchOptions({
    required this.accountId,
    required this.accountName,
    required this.accountCurrency,
    required this.requestedCurrency,
    required this.amount,
    required this.fxOptions,
    required this.siblings,
  });

  int get total => fxOptions.length + siblings.length;
  bool get isEmpty => total == 0;
}

String _norm(String s) => s.trim().toLowerCase();

/// Parse the user's reply against numbered options. Never guesses:
/// unknown input (or a bare yes) returns [MismatchChoice.unknown] so the
/// caller re-asks instead of executing.
MismatchChoice parseMismatchChoice(String reply, MismatchOptions options) {
  final q = _norm(reply);
  if (q.isEmpty) return MismatchChoice.unknown;
  const cancelWords = [
    'إلغاء', 'الغاء', 'بطلت', 'انس', 'انسى', 'خلاص', 'cancel', 'never mind', 'لا',
  ];
  if (cancelWords.any((w) => q == w || q.startsWith('$w ') || q.startsWith('$w،'))) {
    return MismatchChoice.cancel;
  }
  // Numbered choice: "1", "2", "الأول", "الثاني", "الثالث", "first"...
  // Mapped by VALUE (not position): both hamza forms of "first" mean 1.
  int? pick;
  final digit = RegExp(r'(\d+)').firstMatch(q);
  if (digit != null) pick = int.tryParse(digit.group(1)!);
  const ordinals = <String, int>{
    'الأول': 1, 'الاول': 1, 'first': 1, 'one': 1, 'واحد': 1,
    'الثاني': 2, 'الثانى': 2, 'second': 2, 'two': 2, 'اثنين': 2,
    'الثالث': 3, 'third': 3, 'three': 3, 'ثلاثة': 3,
    'الرابع': 4, 'fourth': 4, 'four': 4, 'أربعة': 4,
    'الخامس': 5, 'fifth': 5, 'five': 5, 'خمسة': 5,
  };
  if (pick == null) {
    for (final e in ordinals.entries) {
      if (q.contains(e.key)) {
        pick = e.value;
        break;
      }
    }
  }
  if (pick != null && pick >= 1 && pick <= options.total) {
    final idx = pick - 1;
    if (idx < options.fxOptions.length) {
      return MismatchChoice.fx(options.fxOptions[idx]);
    }
    return MismatchChoice.account(
        options.siblings[idx - options.fxOptions.length]);
  }
  // Currency code match → the FX option carrying that currency.
  for (final fx in options.fxOptions) {
    if (q == fx.currency.toLowerCase() || q.contains(fx.currency.toLowerCase())) {
      return MismatchChoice.fx(fx);
    }
  }
  // Requested-currency code → the first sibling that natively supports it.
  // Still just a selection: confirmation + execution happen downstream.
  if (q == options.requestedCurrency.toLowerCase()) {
    if (options.siblings.isNotEmpty) {
      return MismatchChoice.account(options.siblings.first);
    }
    return MismatchChoice.unknown;
  }
  // Account-name match → the sibling with that name.
  for (final s in options.siblings) {
    final n = _norm(s.accountName);
    if (n.isNotEmpty && (q.contains(n) || n.contains(q))) {
      return MismatchChoice.account(s);
    }
  }
  return MismatchChoice.unknown;
}

/// Build the user-facing options question. Lists ONLY real data:
/// the target account's own currencies (with real FX conversions) and
/// sibling accounts that natively support the requested currency.
String buildMismatchQuestion(MismatchOptions o, {required bool arabic}) {
  final buf = StringBuffer();
  final amt = _fmtAmount(o.amount);
  if (arabic) {
    buf.writeln(
        'حساب "${o.accountName}" لا يدعم العملة ${o.requestedCurrency} — عملاته: ${o.accountCurrency}.');
    buf.writeln('المبلغ المطلوب: $amt ${o.requestedCurrency}.');
    buf.writeln('اختر واحدًا (بالرقم أو الاسم)، أو اكتب "إلغاء":');
  } else {
    buf.writeln(
        'Account "${o.accountName}" does not support ${o.requestedCurrency} — its currencies: ${o.accountCurrency}.');
    buf.writeln('Requested amount: $amt ${o.requestedCurrency}.');
    buf.writeln('Pick one (by number or name), or type "cancel":');
  }
  var n = 1;
  for (final fx in o.fxOptions) {
    if (arabic) {
      buf.writeln(
          '$n. تحويل $amt ${o.requestedCurrency} إلى ${fx.converted} ${fx.currency} في "${fx.accountName}" (السعر ${fx.rate})');
    } else {
      buf.writeln(
          '$n. Convert $amt ${o.requestedCurrency} to ${fx.converted} ${fx.currency} in "${fx.accountName}" (rate ${fx.rate})');
    }
    n++;
  }
  for (final s in o.siblings) {
    if (arabic) {
      buf.writeln(
          '$n. استخدام حساب "${s.accountName}" الذي يدعم ${s.currency} مباشرة ($amt ${o.requestedCurrency})');
    } else {
      buf.writeln(
          '$n. Use account "${s.accountName}" which natively supports ${s.currency} ($amt ${o.requestedCurrency})');
    }
    n++;
  }
  return buf.toString().trim();
}

String _fmtAmount(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}
