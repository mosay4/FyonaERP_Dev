import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_interceptors.dart'
    show DeviceIdentity;
import 'package:fyona_flutter/features/auth/data/models/session_model.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';

/// Sessions: device recognition data, secondary badge inputs, avatar sync
/// inputs — pure unit coverage (no widgets, no platform channels).
void main() {
  group('SessionModel device recognition', () {
    Map<String, dynamic> base() => {
          'id': 's1',
          'user_id': 'u1',
          'is_active': true,
          'is_current': false,
          'is_primary': false,
          'last_activity': DateTime.now().toIso8601String(),
          'created_at': DateTime.now().toIso8601String(),
        };

    test('parses full device recognition payload', () {
      final m = SessionModel.fromJson({
        ...base(),
        'device_info': 'Samsung SM-S918B',
        'device_model': 'SM-S918B',
        'os_version': 'Android 14',
        'fingerprint': 'android:abc123',
        'country': 'Yemen',
        'region': 'Sanaa',
        'city': 'Sanaa',
        'ip_address': '1.2.3.4',
        'is_current': true,
        'is_primary': false,
      });
      expect(m.deviceModel, 'SM-S918B');
      expect(m.osVersion, 'Android 14');
      expect(m.fingerprint, 'android:abc123');
      expect(m.country, 'Yemen');
      expect(m.isCurrent, isTrue);
      expect(m.locationLabel, 'Yemen، Sanaa');
    });

    test('locationLabel tolerates missing parts', () {
      final m = SessionModel.fromJson({...base(), 'country': 'Yemen'});
      expect(m.locationLabel, 'Yemen');
      final empty = SessionModel.fromJson(base());
      expect(empty.locationLabel, isEmpty);
      expect(empty.deviceModel, isNull);
    });

    test('legacy payloads without new keys still parse', () {
      final m = SessionModel.fromJson(base());
      expect(m.isPrimary, isFalse);
      expect(m.ipAddress, isNull);
    });
  });

  group('UserModel avatar', () {
    Map<String, dynamic> baseUser() => {
          'id': 'u1',
          'organization_id': 'o1',
        };

    test('parses server avatar path', () {
      final u = UserModel.fromJson({
        ...baseUser(),
        'avatar': 'uploads/avatars/u1.jpg',
      });
      expect(u.avatar, 'uploads/avatars/u1.jpg');
    });

    test('missing avatar stays null (legacy payloads)', () {
      final u = UserModel.fromJson(baseUser());
      expect(u.avatar, isNull);
    });

    test('copyWith carries avatar', () {
      const u = UserModel(id: 'u1');
      expect(u.copyWith(avatar: 'a.jpg').avatar, 'a.jpg');
    });
  });

  group('DeviceIdentity', () {
    test('always yields a non-empty name without platform', () {
      DeviceIdentity.debugReset();
      expect(DeviceIdentity.name.isNotEmpty, isTrue);
    });
  });
}
