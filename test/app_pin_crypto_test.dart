import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/security/app_pin_crypto.dart';

/// App-lock PIN cryptography: salted SHA-256, never stores the PIN itself.
void main() {
  group('app PIN crypto', () {
    test('pack then verify round-trips', () {
      final record = packAppPin('12345');
      expect(record.contains(':'), isTrue);
      expect(verifyAppPinRecord('12345', record), isTrue);
    });

    test('wrong PIN fails', () {
      final record = packAppPin('12345');
      expect(verifyAppPinRecord('54321', record), isFalse);
      expect(verifyAppPinRecord('1234', record), isFalse);
      expect(verifyAppPinRecord('123456', record), isFalse);
    });

    test('malformed records fail closed', () {
      expect(verifyAppPinRecord('12345', null), isFalse);
      expect(verifyAppPinRecord('12345', ''), isFalse);
      expect(verifyAppPinRecord('12345', 'no-separator'), isFalse);
      expect(verifyAppPinRecord('12345', ':onlyhash'), isFalse);
      expect(verifyAppPinRecord('12345', 'salt:'), isFalse);
    });

    test('salts are unique per pack (same PIN, different records)', () {
      final a = packAppPin('12345');
      final b = packAppPin('12345');
      expect(a, isNot(equals(b)));
      expect(verifyAppPinRecord('12345', a), isTrue);
      expect(verifyAppPinRecord('12345', b), isTrue);
    });

    test('format validation accepts exactly 5 digits', () {
      expect(isValidAppPinFormat('12345'), isTrue);
      expect(isValidAppPinFormat('00000'), isTrue);
      expect(isValidAppPinFormat('1234'), isFalse);
      expect(isValidAppPinFormat('123456'), isFalse);
      expect(isValidAppPinFormat('12a45'), isFalse);
      expect(isValidAppPinFormat(''), isFalse);
      expect(isValidAppPinFormat(' 12345'), isFalse);
    });
  });
}
