import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/utils/validators/app_validators.dart';

void main() {
  group('AppValidators', () {
    group('validateEmail', () {
      test('returns null for valid email', () {
        expect(AppValidators.validateEmail('test@example.com'), null);
      });

      test('returns error for empty email', () {
        expect(AppValidators.validateEmail(''), isNotNull);
      });

      test('returns error for email without @', () {
        expect(AppValidators.validateEmail('invalid'), isNotNull);
      });
    });

    group('validatePassword', () {
      test('returns null for valid password', () {
        expect(AppValidators.validatePassword('Test1234!'), null);
      });

      test('returns error for short password', () {
        expect(AppValidators.validatePassword('Ab1!'), isNotNull);
      });

      test('returns error for missing uppercase', () {
        expect(AppValidators.validatePassword('test1234!'), isNotNull);
      });

      test('returns error for missing digit', () {
        expect(AppValidators.validatePassword('TestTest!'), isNotNull);
      });

      test('returns error for missing special char', () {
        expect(AppValidators.validatePassword('Test1234a'), isNotNull);
      });
    });

    group('validatePhone', () {
      test('returns null for valid phone', () {
        expect(AppValidators.validatePhone('+966501234567'), null);
      });

      test('returns error for empty phone', () {
        expect(AppValidators.validatePhone(''), isNotNull);
      });
    });

    group('validateRequired', () {
      test('returns null for non-empty', () {
        expect(AppValidators.validateRequired('test'), null);
      });

      test('returns error for empty', () {
        expect(AppValidators.validateRequired(''), isNotNull);
      });
    });

    group('validateConfirmPassword', () {
      test('returns null when passwords match', () {
        expect(AppValidators.validateConfirmPassword('Test1234!', 'Test1234!'), null);
      });

      test('returns error when passwords mismatch', () {
        expect(AppValidators.validateConfirmPassword('Test1234!', 'Different!'), isNotNull);
      });
    });
  });
}
