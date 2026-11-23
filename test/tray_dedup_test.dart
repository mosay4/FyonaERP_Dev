import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/shared/services/notification_service.dart';

/// Tray event-identity: the same logical event via bridge + poll paints
/// exactly once (persisted, restart-proof); distinct events always pass.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('identical triple claims once, duplicate skipped', () async {
    const p = 'notifications';
    const t = 'T';
    const b = 'same body text';
    expect(
      await NotificationService.tryClaimTrayKey(
        NotificationService.trayEventKey(
            actionPayload: p, title: t, body: b)),
      isTrue,
    );
    expect(
      await NotificationService.tryClaimTrayKey(
        NotificationService.trayEventKey(
            actionPayload: p, title: t, body: b)),
      isFalse,
    );
  });

  test('body truncation normalizes bridge vs poll variants', () async {
    const p = 'suggestions';
    const t = 'reply';
    final full = '${'x' * 200} tail-segment';
    final cut = '${'x' * 200}';
    final k1 = NotificationService.trayEventKey(
        actionPayload: p, title: t, body: full);
    final k2 = NotificationService.trayEventKey(
        actionPayload: p, title: t, body: cut);
    expect(k1, k2);
    expect(await NotificationService.tryClaimTrayKey(k1), isTrue);
    expect(await NotificationService.tryClaimTrayKey(k2), isFalse);
  });

  test('distinct events both pass', () async {
    final k1 = NotificationService.trayEventKey(
        actionPayload: 'notifications', title: 'A', body: 'one');
    final k2 = NotificationService.trayEventKey(
        actionPayload: 'notifications', title: 'A', body: 'two');
    expect(await NotificationService.tryClaimTrayKey(k1), isTrue);
    expect(await NotificationService.tryClaimTrayKey(k2), isTrue);
  });

  test('release allows redelivery after a failed show', () async {
    final k = NotificationService.trayEventKey(
        actionPayload: 'p', title: 't', body: 'b');
    expect(await NotificationService.tryClaimTrayKey(k), isTrue);
    await NotificationService.releaseTrayKey(k);
    expect(await NotificationService.tryClaimTrayKey(k), isTrue);
  });

  test('empty key never suppresses', () async {
    expect(await NotificationService.tryClaimTrayKey('  '), isTrue);
  });
}
