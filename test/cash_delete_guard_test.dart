import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_banks_page.dart'
    show canDeleteBankCompletely;

/// Cash can never be deleted as a whole (any locale spelling), while any
/// user-added bank can. Regression coverage for the hole where the
/// "delete bank completely" button appeared when the cash account was
/// stored as 'CASH' (English locale) because the old check covered only
/// two of the three cash spellings.
void main() {
  group('cash delete protection', () {
    test('isCashAccount covers every cash spelling', () {
      expect(isCashAccount('كاش'), isTrue);
      expect(isCashAccount('Cash'), isTrue);
      expect(isCashAccount('CASH'), isTrue);
      expect(isCashAccount('AlRajhi'), isFalse);
      expect(isCashAccount('مصرف الراجحي'), isFalse);
    });

    test('delete-completely is never offered for cash', () {
      expect(canDeleteBankCompletely('كاش'), isFalse);
      expect(canDeleteBankCompletely('Cash'), isFalse);
      expect(canDeleteBankCompletely('CASH'), isFalse,
          reason: 'English-locale cash must also hide the button');
    });

    test('delete-completely stays offered for user-added banks', () {
      expect(canDeleteBankCompletely('AlRajhi'), isTrue);
      expect(canDeleteBankCompletely('مصرف الراجحي'), isTrue);
      expect(canDeleteBankCompletely('SNB'), isTrue);
    });
  });
}
