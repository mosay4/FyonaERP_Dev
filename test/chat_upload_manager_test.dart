import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/data/chat_upload_manager.dart';

class _MediaApi extends MerchantApi {
  _MediaApi() : super(ApiClient(dio: Dio()));
  int uploads = 0;
  int failures = 0;
  int uploadFailures = 0;
  final ids = <String?>[];
  Completer<void>? uploadGate;
  int concurrent = 0;
  int peak = 0;
  @override
  Future<Map<String, String>> uploadChatMedia(
    String linkId,
    List<int> bytes,
    String filename,
    String mime, {
    String? path,
    CancelToken? cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    uploads++;
    if (uploadFailures-- > 0)
      throw DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionTimeout,
      );
    concurrent++;
    if (concurrent > peak) peak = concurrent;
    await uploadGate?.future;
    concurrent--;
    return {'url': 'uploads/$filename', 'thumbnail': ''};
  }

  @override
  Future<Map<String, dynamic>> sendChat(
    String linkId, {
    required String kind,
    String? side,
    String? text,
    String? mediaPath,
    String? fileName,
    String? invoiceId,
    String? replyToId,
    int? durationMs,
    List<Map<String, dynamic>>? media,
    String? clientId,
  }) async {
    ids.add(clientId);
    if (failures-- > 0)
      throw DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionTimeout,
      );
    return {
      'message': {
        'id': 'server-$clientId',
        'client_id': clientId,
        'kind': kind,
        'mine': true,
        'created_at': '2027-01-01',
        'text': text,
      },
    };
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in ['image', 'video', 'voice', 'file', 'album']) {
    test(
      '$kind: red terminal failure, manual retry same item/id, cached upload, one acceptance',
      () async {
        final delays = <Duration>[];
        final manager = ChatUploadManager(
          persist: false,
          wait: (delay) async {
            delays.add(delay);
          },
        );
        final api = _MediaApi()..failures = 3;
        var accepted = 0;
        final sub = manager.accepted.listen((event) {
          accepted++;
          expect(event.result['message']['text'], isNull);
        });
        if (kind == 'album') {
          manager.enqueueAlbum(
            api: api,
            linkId: 'link',
            side: 'personal',
            items: [
              {'kind': 'image', 'name': 'photo.jpg', 'bytes': Uint8List(4)},
              {
                'kind': 'video',
                'name': 'video.mp4',
                'path': '/not-read-by-fake',
              },
            ],
          );
        } else {
          manager.enqueueSingle(
            api: api,
            linkId: 'link',
            side: 'personal',
            kind: kind,
            bytes: Uint8List(4),
            fileName: '$kind.dat',
          );
        }
        final original = manager.pending('link').single;
        await _flush();
        expect(original['failed'], true);
        expect(original['busy'], false);
        expect(manager.pending('link').single, same(original));
        expect(api.ids.length, 3);
        expect(api.ids.toSet(), {original['id']});
        expect(delays.map((d) => d.inMilliseconds), [500, 1000]);
        final uploads = api.uploads;
        manager.retry('link', '${original['id']}');
        manager.retry('link', '${original['id']}');
        expect(manager.pending('link').length, 1);
        await _flush();
        expect(api.uploads, uploads);
        expect(api.ids.length, 4);
        expect(api.ids.toSet().length, 1);
        expect(manager.pending('link'), isEmpty);
        expect(accepted, 1);
        manager.retry('link', '${original['id']}');
        await _flush();
        expect(api.ids.length, 4);
        await sub.cancel();
      },
    );
  }

  test(
    'upload failure retries with backoff; polling acceptance cancels pending retries',
    () async {
      final gate = Completer<void>();
      final manager = ChatUploadManager(
        persist: false,
        wait: (_) => gate.future,
      );
      final api = _MediaApi()..uploadFailures = 1;
      manager.enqueueSingle(
        api: api,
        linkId: 'link',
        side: 'personal',
        kind: 'file',
        fileName: 'file.pdf',
      );
      await _flush();
      expect(api.uploads, 1);
      gate.complete();
      await _flush();
      expect(api.uploads, 2);
      expect(manager.pending('link'), isEmpty);

      final backoff = Completer<void>();
      final second = ChatUploadManager(
        persist: false,
        wait: (_) => backoff.future,
      );
      final failing = _MediaApi()..failures = 3;
      var accepted = 0;
      final sub = second.accepted.listen((_) => accepted++);
      second.enqueueSingle(
        api: failing,
        linkId: 'link',
        side: 'personal',
        kind: 'voice',
        fileName: 'voice.m4a',
      );
      final id = second.pending('link').single['id'];
      await _flush();
      expect(
        second.acknowledge('other', 'personal', {
          'id': 'server',
          'client_id': id,
        }),
        false,
      );
      expect(
        second.acknowledge('link', 'personal', {
          'id': 'server',
          'client_id': id,
        }),
        true,
      );
      expect(
        second.acknowledge('link', 'personal', {
          'id': 'server',
          'client_id': id,
        }),
        false,
      );
      backoff.complete();
      await _flush();
      expect(failing.ids.length, 1);
      expect(second.pending('link'), isEmpty);
      expect(accepted, 1);
      await sub.cancel();
    },
  );

  test(
    'rapid media burst is bounded to 50 pending and three active uploads',
    () async {
      final manager = ChatUploadManager(persist: false);
      final api = _MediaApi()..uploadGate = Completer<void>();
      final watch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        manager.enqueueSingle(
          api: api,
          linkId: 'burst',
          side: 'personal',
          kind: 'file',
          fileName: '$i.pdf',
        );
      }
      expect(manager.pending('burst').length, ChatUploadManager.maxPending);
      expect(api.peak, ChatUploadManager.maxConcurrent);
      expect(watch.elapsedMilliseconds, lessThan(1000));
      api.uploadGate!.complete();
      await _flush();
      expect(manager.pending('burst'), isEmpty);
      expect(api.ids.length, 50);
      expect(api.ids.toSet().length, 50);
    },
  );
}
