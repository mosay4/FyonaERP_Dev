import '../../data/models/personal_models.dart';

/// Account type (جاري / توفير) sync rules for Personal bank accounts.
///
/// The server stores the type (`account_type`, current/savings) and says
/// whether it was ever stated (`account_type_set`). Older app versions kept
/// the type ONLY on the device, in a SharedPreferences map (account id →
/// type). These pure helpers decide which source wins and which legacy
/// device-only types must be pushed up once.

bool _isCash(PersonalBankAccount a) =>
    a.accountType == 'cash' || a.bankName == 'كاش' || a.bankName == 'Cash';

/// The type every screen shows for each account.
///
/// * Server stated the type (`accountTypeSet == true`) → the server wins;
///   a stale device map can never override it.
/// * Server row predates the type or the server is older
///   (`accountTypeSet` false/null) → the legacy device map, when it has an
///   entry, keeps showing what the user picked on this device.
List<PersonalBankAccount> resolvePersonalAccountTypes(
  List<PersonalBankAccount> accounts,
  Map<String, String> localTypes,
) {
  if (localTypes.isEmpty) return accounts;
  return [
    for (final a in accounts)
      if (_isCash(a) || a.accountTypeSet == true)
        a
      else if (localTypes[a.id] != null &&
          personalAccountTypeFromServer(localTypes[a.id]) != a.accountType)
        PersonalBankAccount(
          id: a.id,
          bankName: a.bankName,
          balance: a.balance,
          currency: a.currency,
          notes: a.notes,
          accountType: personalAccountTypeFromServer(localTypes[a.id]),
          accountTypeSet: a.accountTypeSet,
        )
      else
        a,
  ];
}

/// Legacy device-only types to push to the server once (account id → type).
///
/// Only rows the server explicitly reports as never typed
/// (`accountTypeSet == false`) are migrated, and only a `savings` entry is
/// pushed: an unstated server row already reads as جاري, so pushing
/// "checking" could only ever lock out a real توفير picked on another
/// device. Rows with a stated server type, unknown status (older server)
/// or cash are never touched — a reinstall (empty map) pushes nothing and
/// therefore can never overwrite a savings account with current.
Map<String, String> planPersonalAccountTypeMigration(
  List<PersonalBankAccount> accounts,
  Map<String, String> localTypes,
) {
  if (localTypes.isEmpty) return const {};
  final out = <String, String>{};
  for (final a in accounts) {
    if (_isCash(a) || a.accountTypeSet != false) continue;
    final local = localTypes[a.id];
    if (local == null) continue;
    if (personalAccountTypeFromServer(local) == 'savings') {
      out[a.id] = 'savings';
    }
  }
  return out;
}
