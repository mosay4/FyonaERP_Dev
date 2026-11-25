import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/services/notification_channels.dart';

/// Channel spec: all SIX channels exist with stable ids, correct sounds
/// (sound_1 everywhere except recurring → sound_2), high importance.
/// Pure spec objects — no plugin init involved.
void main() {
  group('six channels', () {
    test('exact id set', () {
      final ids = NotificationChannels.all.map((c) => c.id).toSet();
      expect(ids, {
        'suggestions_channel',
        'sara_channel',
        'server_channel',
        'subscription_channel',
        'recurring_channel',
        'inventory_channel',
      });
    });

    test('sound mapping: sound_1 vs sound_2 separation', () {
      final byId = {for (final c in NotificationChannels.all) c.id: c.sound};
      expect(byId['suggestions_channel'], ChannelSound.sound1);
      expect(byId['sara_channel'], ChannelSound.sound1);
      expect(byId['server_channel'], ChannelSound.sound1);
      expect(byId['subscription_channel'], ChannelSound.sound1);
      expect(byId['recurring_channel'], ChannelSound.sound2);
      expect(byId['inventory_channel'], ChannelSound.sound1);
      // Only recurring may use sound_2.
      final sound2 =
          NotificationChannels.all.where((c) => c.sound == 'sound_2').toList();
      expect(sound2.map((c) => c.id), ['recurring_channel']);
    });

    test('importance high for all', () {
      for (final c in NotificationChannels.all) {
        expect(c.importance, Importance.high);
      }
    });

    test('byId lookup', () {
      expect(NotificationChannels.byId('sara_channel')?.id, 'sara_channel');
      expect(NotificationChannels.byId('nope'), isNull);
    });
  });

  group('built platform objects', () {
    test('channel carries id, sound, vibration, badge', () {
      const spec = NotificationChannels.recurring;
      final ch = spec.channel(name: 'Recurring', description: 'desc');
      expect(ch.id, 'recurring_channel');
      expect(ch.importance, Importance.high);
      expect(
        (ch.sound as RawResourceAndroidNotificationSound?)?.sound,
        'sound_2',
      );
      expect(ch.enableVibration, isTrue);
      expect(ch.showBadge, isTrue);
    });

    test('details carry sound + vibration + badge', () {
      const spec = NotificationChannels.server;
      final d = spec.details(name: 'App', description: 'desc');
      expect(d.importance, Importance.high);
      expect(d.priority, Priority.high);
      expect(
        (d.sound as RawResourceAndroidNotificationSound?)?.sound,
        'sound_1',
      );
      expect(d.enableVibration, isTrue);
      expect(d.channelShowBadge, isTrue);
    });

    test('ios details use matching sound file', () {
      final d = NotificationChannels.subscription.iosDetails();
      expect(d.sound, 'sound_1.mp3');
      expect(
          NotificationChannels.recurring.iosDetails().sound, 'sound_2.wav');
    });
  });
}
