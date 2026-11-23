import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─────────────────────────────────────────────────────────────
// NotificationChannels — the single spec for ALL FIVE Flutter
// notification channels. Created at startup (delete + recreate so
// already-installed devices pick up sound changes; channel sound is
// immutable on Android).
//
// Sound mapping (stable, never swap):
//   suggestions / sara / server / subscription → sound_1
//   recurring                                   → sound_2
//
// Pure spec objects — constructing them never touches the plugin, so
// unit tests can assert ids / sounds / importance without init.
// ─────────────────────────────────────────────────────────────

/// Sound resource (raw name, without extension).
class ChannelSound {
  static const String sound1 = 'sound_1';
  static const String sound2 = 'sound_2';
}

class NotificationChannelSpec {
  final String id;
  final String nameKey;
  final String descKey;
  final String sound;

  const NotificationChannelSpec({
    required this.id,
    required this.nameKey,
    required this.descKey,
    required this.sound,
  });

  Importance get importance => Importance.high;

  AndroidNotificationChannel channel({
    required String name,
    required String description,
  }) {
    return AndroidNotificationChannel(
      id,
      name,
      description: description,
      importance: Importance.high,
      sound: RawResourceAndroidNotificationSound(sound),
      enableVibration: true,
      showBadge: true,
    );
  }

  AndroidNotificationDetails details({
    required String name,
    required String description,
  }) {
    return AndroidNotificationDetails(
      id,
      name,
      channelDescription: description,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      icon: 'ic_launcher',
      color: const Color(0xFF000000),
      sound: RawResourceAndroidNotificationSound(sound),
      enableVibration: true,
      channelShowBadge: true,
    );
  }

  DarwinNotificationDetails iosDetails() {
    return DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: '$sound.mp3',
    );
  }
}

class NotificationChannels {
  NotificationChannels._();

  static const suggestions = NotificationChannelSpec(
    id: 'suggestions_channel',
    nameKey: 'notifChannelSuggestName',
    descKey: 'notifChannelSuggestDesc',
    sound: ChannelSound.sound1,
  );

  static const sara = NotificationChannelSpec(
    id: 'sara_channel',
    nameKey: 'notifChannelSaraName',
    descKey: 'notifChannelSaraDesc',
    sound: ChannelSound.sound1,
  );

  static const server = NotificationChannelSpec(
    id: 'server_channel',
    nameKey: 'notifChannelAppName',
    descKey: 'notifChannelAppDesc',
    sound: ChannelSound.sound1,
  );

  static const subscription = NotificationChannelSpec(
    id: 'subscription_channel',
    nameKey: 'notifChannelSubName',
    descKey: 'notifChannelSubDesc',
    sound: ChannelSound.sound1,
  );

  static const recurring = NotificationChannelSpec(
    id: 'recurring_channel',
    nameKey: 'recurringChannelName',
    descKey: 'recurringChannelDesc',
    sound: ChannelSound.sound2,
  );

  static const inventory = NotificationChannelSpec(
    id: 'inventory_channel',
    nameKey: 'notifChannelInventoryName',
    descKey: 'notifChannelInventoryDesc',
    sound: ChannelSound.sound1,
  );

  /// All channels, in creation order.
  static const List<NotificationChannelSpec> all = [
    suggestions,
    sara,
    server,
    subscription,
    recurring,
    inventory,
  ];

  static NotificationChannelSpec? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}
