/// Business bank account model (org-level `/banking/*` endpoints).
///
/// Separate data from Personal on purpose: Business amounts must never mix
/// with Personal ones. Field set mirrors the backend `bank_accounts` table
/// (bank + account name/number, IBAN, balance, currency).
class BusinessBankAccount {
  final String id;
  final String bankName;
  final String groupKey;
  final String accountName;
  final String accountNumber;
  final String? iban;
  final double balance;
  final String currency;
  final String accountType;
  final bool isActive;

  const BusinessBankAccount({
    required this.id,
    required this.bankName,
    this.groupKey = '',
    this.accountName = '',
    this.accountNumber = '',
    this.iban,
    this.balance = 0,
    this.currency = 'SAR',
    this.accountType = 'checking',
    this.isActive = true,
  });

  static String _idStr(dynamic v) => v?.toString() ?? '';

  static double _num(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  factory BusinessBankAccount.fromServer(Map<String, dynamic> json) {
    return BusinessBankAccount(
      id: _idStr(json['id']),
      bankName: (json['bank_name'] ?? '').toString(),
      groupKey: (json['group_key'] ??
              json['bank_group_key'] ??
              'name:${(json['bank_name'] ?? '').toString()}')
          .toString(),
      accountName: (json['account_name'] ?? '').toString(),
      accountNumber: (json['account_number'] ?? '').toString(),
      iban: json['iban']?.toString(),
      balance: _num(json['balance']),
      currency: (json['currency'] ?? 'SAR').toString(),
      accountType: (json['account_type'] ?? 'checking').toString(),
      isActive: json['is_active'] != false,
    );
  }
}

/// Cash identity for Business (same three spellings as Personal).
bool isBizCashAccount(String name) =>
    name == 'كاش' || name == 'Cash' || name == 'CASH';
