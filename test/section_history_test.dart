import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('business is initial default for dual or business subscriptions', () async {
    expect(await SectionHistory.restore('u', business: true, personal: true), 'business');
    expect(await SectionHistory.restore('u', business: true, personal: false), 'business');
    expect(await SectionHistory.restore('u', business: false, personal: true), 'personal');
  });

  test('restart restores personal, isolates users and respects revoked access', () async {
    await SectionHistory.save('u', 'personal');
    expect(await SectionHistory.restore('u', business: true, personal: true), 'personal');
    expect(await SectionHistory.restore('other', business: true, personal: true), 'business');
    expect(await SectionHistory.restore('u', business: true, personal: false), 'business');
    await SectionHistory.save('u', 'business');
    expect(await SectionHistory.restore('u', business: true, personal: true), 'business');
  });
}
