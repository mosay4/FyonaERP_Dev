import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/features/profile/presentation/providers/avatar_provider.dart'
    show avatarProvider, syncAvatarFromUrl;

/// Avatar push-event application: a new version downloads and publishes
/// (watchers rebuild with no profile open); stale events are ignored; the
/// tombstoned delete is never resurrected by an event.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uid = 'u-event-1';
  const urlV1 = 'uploads/avatars/u-event-1.jpg?v=111';
  const urlV2 = 'uploads/avatars/u-event-1.jpg?v=222';
  final bytesV2 = Uint8List.fromList(List<int>.generate(64, (i) => i));

  final _refProvider = Provider<Ref>((ref) => ref);

  Dio fakeDio({required List<String> hits}) {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        hits.add(options.uri.toString());
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: bytesV2,
        ));
      },
    ));
    return dio;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('syncAvatarFromUrl (push event application)', () {
    test('newer version downloads, publishes and records', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hits = <String>[];
      final applied = await syncAvatarFromUrl(
        container.read(_refProvider),
        userId: uid,
        serverRel: urlV2,
        absoluteUrl: 'http://host/$urlV2',
        dioOverride: fakeDio(hits: hits),
      );
      expect(applied, isTrue);
      expect(hits.length, 1);
      expect(container.read(avatarProvider), bytesV2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('profile_avatar_server_url_$uid'), urlV2);
    });

    test('same version is a no-op (no download)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('profile_avatar_server_url_$uid', urlV2);
      final hits = <String>[];
      final applied = await syncAvatarFromUrl(
        container.read(_refProvider),
        userId: uid,
        serverRel: urlV2,
        absoluteUrl: 'http://host/$urlV2',
        dioOverride: fakeDio(hits: hits),
      );
      expect(applied, isFalse);
      expect(hits, isEmpty);
    });

    test('tombstoned delete is not resurrected by its own event', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'profile_avatar_server_url_$uid', 'DELETED:$urlV2');
      final hits = <String>[];
      final applied = await syncAvatarFromUrl(
        container.read(_refProvider),
        userId: uid,
        serverRel: urlV2,
        absoluteUrl: 'http://host/$urlV2',
        dioOverride: fakeDio(hits: hits),
      );
      expect(applied, isFalse);
      expect(hits, isEmpty);
      expect(container.read(avatarProvider), isNull);
    });
  });
}
