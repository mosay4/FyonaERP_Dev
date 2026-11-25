import 'package:flutter/widgets.dart';

import '../../../../shared/widgets/account_type_bar.dart';
import '../../data/models/personal_models.dart';

/// Shared rules for every Personal account picker.
///
/// A bank may hold the SAME currency more than once (e.g. «الكريمي» USD
/// جاري + USD توفير). Pickers must therefore never key a bank's accounts by
/// currency: each account is its own row (picked by id), and the rows that
/// share a currency inside one bank carry a small account-type tag.

bool _isCash(PersonalBankAccount a) =>
    a.bankName == 'كاش' || a.bankName == 'Cash' || a.accountType == 'cash';

/// True when [a]'s bank holds another non-cash account in the same currency,
/// i.e. the currency alone does not identify the account.
bool personalAccountNeedsTypeTag(
    Iterable<PersonalBankAccount> accounts, PersonalBankAccount a) {
  if (_isCash(a)) return false;
  final cur = a.currency.trim().toUpperCase();
  var n = 0;
  for (final x in accounts) {
    if (_isCash(x)) continue;
    if (x.bankName == a.bankName && x.currency.trim().toUpperCase() == cur) {
      n++;
      if (n > 1) return true;
    }
  }
  return false;
}

/// The accounts of [bankName] (cash excluded), one entry per account — never
/// collapsed by currency.
List<PersonalBankAccount> personalBankAccountsOf(
        Iterable<PersonalBankAccount> accounts, String bankName) =>
    [for (final a in accounts) if (!_isCash(a) && a.bankName == bankName) a];

/// Resolves the account an operation must run on. An explicit [accountId]
/// always wins; otherwise bank + currency is used only when it is
/// unambiguous (exactly one match). Returns null when ambiguous/not found so
/// the caller asks the user instead of guessing.
PersonalBankAccount? resolvePersonalAccount(
  Iterable<PersonalBankAccount> accounts, {
  String? accountId,
  String? bankName,
  String? currency,
}) {
  if (accountId != null && accountId.isNotEmpty) {
    for (final a in accounts) {
      if (a.id == accountId) return a;
    }
    return null;
  }
  if (bankName == null || currency == null) return null;
  final cur = currency.trim().toUpperCase();
  final matches = [
    for (final a in accounts)
      if (a.bankName == bankName && a.currency.trim().toUpperCase() == cur) a
  ];
  return matches.length == 1 ? matches.first : null;
}

/// Small type chip (جاري / توفير) shown only where it disambiguates; an empty
/// box otherwise so existing rows keep their look.
class PersonalAccountTypeTag extends StatelessWidget {
  final Iterable<PersonalBankAccount> accounts;
  final PersonalBankAccount account;
  final bool always;
  const PersonalAccountTypeTag({
    super.key,
    required this.accounts,
    required this.account,
    this.always = false,
  });

  @override
  Widget build(BuildContext context) {
    final show = always
        ? !_isCash(account)
        : personalAccountNeedsTypeTag(accounts, account);
    if (!show) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: AccountTypeBadge(type: account.accountType, dense: true),
    );
  }
}
