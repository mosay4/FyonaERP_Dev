import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/services/media/chat_media_store.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('chat_media');
    ChatMediaStore.debugFolder = dir;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('an attachment is downloaded once and then served from the device', () async {
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls++;
        h.resolve(Response(requestOptions: o, data: <int>[1, 2, 3]));
      }));
    const url = 'https://host.test/uploads/chat/a1.jpg';
    expect(await ChatMediaStore.bytes(dio, url), Uint8List.fromList([1, 2, 3]));
    // The server has deleted it: the device copy still answers.
    dio.interceptors.clear();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      calls++;
      h.reject(DioException(requestOptions: o, message: 'gone'));
    }));
    expect(await ChatMediaStore.bytes(dio, url), Uint8List.fromList([1, 2, 3]));
    expect(calls, 1);
  });

  test('the same file whatever host or path form the message uses', () async {
    await ChatMediaStore.save('uploads/chat/v.mp4', [9]);
    final f = await ChatMediaStore.file('https://other.test/uploads/chat/v.mp4');
    expect(f, isNotNull);
    expect(f!.path.endsWith('.mp4'), isTrue);
    expect(ChatMediaStore.key('/uploads/chat/v.mp4'), ChatMediaStore.key('uploads/chat/v.mp4'));
  });

  test('every attachment address in a message is found', () {
    final urls = ChatMediaStore.urlsOf({
      'media_path': 'uploads/chat/x.m4a',
      'media': [
        {'url': 'uploads/chat/p.jpg'},
        {'url': 'uploads/chat/q.mp4', 'thumbnail': 'uploads/chat/thumbs/q.jpg'},
      ],
    });
    expect(urls, hasLength(4));
  });

  test('a failed download leaves nothing half-written', () async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        h.reject(DioException(requestOptions: o, message: 'offline'));
      }));
    await expectLater(ChatMediaStore.bytes(dio, 'uploads/chat/z.png'), throwsA(isA<DioException>()));
    expect(await ChatMediaStore.file('uploads/chat/z.png'), isNull);
  });
}
