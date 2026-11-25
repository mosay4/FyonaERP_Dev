import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/utils/subscription_identity.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';

/// Plan identity → badge: personal blue (1), business red (2),
/// أعمال + شخصي gold (3). The badge follows the LIVE status snapshot so a
/// paid upgrade / admin plan change recolours it without a reinstall.
void main() {
  test('identity colours per plan', () {
    expect(subscriptionIdentityColor('personal'), AppColors.info);
    expect(subscriptionIdentityColor('business'), AppColors.danger);
    expect(subscriptionIdentityColor('premium'), AppColors.gold);
    expect(subscriptionIdentityColor('باقة أعمال + شخصي'), AppColors.gold);
  });

  test('live snapshot wins over the cached profile (plan changed)', () {
    // Cached profile still says personal (1); admin switched to premium.
    expect(liveSubscriptionIdentityLevel('premium', cachedLevel: 1), 3);
    expect(liveSubscriptionIdentityLevel('business', cachedLevel: 3), 2);
    expect(liveSubscriptionIdentityLevel('Personal', cachedLevel: 2), 1);
  });

  test('no live paid plan (offline / loading / trial) keeps the cache', () {
    expect(liveSubscriptionIdentityLevel(null, cachedLevel: 2), 2);
    expect(liveSubscriptionIdentityLevel('trial', cachedLevel: 0), 0);
  });

  test('cached profile level uses the same canonical mapping', () {
    UserModel u(String? plan) => UserModel(id: 'u', subscriptionPlan: plan);
    expect(u('personal').verificationLevel, 1);
    expect(u('business_plan').verificationLevel, 2);
    expect(u('أعمال + شخصي').verificationLevel, 3);
    expect(u('PREMIUM').verificationLevel, 3);
    expect(u('trial').verificationLevel, 0);
    expect(u(null).verificationLevel, 0);
  });
}
