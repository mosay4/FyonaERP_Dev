// Chat attachments through Cloudflare R2, encrypted on the sender's device.
//
// Optional REAL R2 round trip: FYONA_R2_PRESIGN=<command> prints a presigned
// URL for `<method> <key> [content-type size]` (the server's own presigner,
// run where the R2 keys are; never in CI).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/media/chat_cloud_media.dart';
import 'package:fyona_flutter/core/media/media_store.dart';
import 'package:fyona_flutter/core/media/media_sync.dart';
import 'package:fyona_flutter/core/services/media/chat_media_store.dart';

import 'media_layer_test.dart' show FakeR2, FakeRemote;

Uint8List _bytes(int seed, int size) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(size, (_) => r.nextInt(256)));
}

/// The server's presigner (real R2), through a local command.
class _PresignRemote implements MediaRemote {
  _PresignRemote(this.cmd, this.tenant);
  final String cmd;
  final String tenant;
  final keys = <String>{};
  String _key(String sha) => 't/$tenant/m/$sha';
  Future<String> _sign(List<String> a) async {
    final r = await Process.run(cmd, a);
    if (r.exitCode != 0) throw StateError('presign failed');
    return '${r.stdout}'.trim();
  }

  @override
  Future<Map<String, dynamic>> uploadUrl(MediaSection section, String sha,
      {required int size, required String mime, String? linkId}) async {
    keys.add(_key(sha));
    return {'url': await _sign(['PUT', _key(sha), mime, '$size']), 'headers': {'content-type': mime, 'content-length': '$size'}};
  }

  @override
  Future<void> commit(MediaSection section, String sha, {required int size, String? linkId}) async {
    final got = await _sign(['HEAD', _key(sha)]);
    if (got != '$size') throw StateError('not stored: $got');
  }

  @override
  Future<String> downloadUrl(MediaSection section, String sha, {String? linkId}) => _sign(['GET', _key(sha)]);
}

void main() {
  late Directory dir;
  late FakeR2 r2;
  const link = '6f1c2a9e-3b4d-4e5f-8a7b-1c2d3e4f5a6b';
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fyona-chatcloud-');
    r2 = await FakeR2.start();
    ChatMediaStore.debugFolder = Directory('${dir.path}/kept');
  });
  tearDown(() async {
    ChatMediaStore.debugFolder = null;
    ChatMediaStore.cloud = null;
    await r2.close();
    await dir.delete(recursive: true);
  });

  test('a video is encrypted before it leaves the phone and comes back byte-exact', () async {
    final video = _bytes(1, 3 * 1024 * 1024 + 777);
    final src = File('${dir.path}/clip.mp4')..writeAsBytesSync(video);
    final cloud = ChatCloudMedia(FakeRemote(r2), temp: Directory('${dir.path}/tmp'));
    var last = 0;
    final ref = await cloud.upload(link, src, 'clip.mp4', 'video/mp4', onProgress: (s, _) => last = s);
    expect(ref, startsWith('fyc:$link/'));
    expect(ref, contains('.mp4#'));
    final parsed = ChatCloudMedia.parse(ref)!;
    final stored = r2.objects.values.single;
    expect(last, stored.length);
    // R2 holds ciphertext only: not the file, and named by the ciphertext hash.
    expect('${sha256.convert(stored)}', parsed.sha);
    expect('${sha256.convert(stored)}' == '${sha256.convert(video)}', isFalse);
    expect(latin1.decode(stored).contains(latin1.decode(video.sublist(1000, 1032))), isFalse);
    // The key travels in the message only.
    expect(r2.objects.keys.single.contains(base64Url.encode(parsed.key).substring(0, 20)), isFalse);
    final out = File('${dir.path}/got.mp4');
    expect(await cloud.fetch(ref, out), isTrue);
    expect(out.readAsBytesSync(), video);
    expect(Directory('${dir.path}/tmp').listSync(), isEmpty);
  });

  test('altered in the cloud, wrong key or another chat: refused, nothing kept', () async {
    final src = File('${dir.path}/p.jpg')..writeAsBytesSync(_bytes(2, 200000));
    final cloud = ChatCloudMedia(FakeRemote(r2), temp: Directory('${dir.path}/tmp'));
    final ref = await cloud.upload(link, src, 'p.jpg', 'image/jpeg');
    final out = File('${dir.path}/x.jpg');
    r2.tamper.add(r2.objects.keys.single);
    await expectLater(cloud.fetch(ref, out), throwsA(isA<FormatException>()));
    r2.tamper.clear();
    final p = ChatCloudMedia.parse(ref)!;
    final wrongKey = ref.replaceFirst(RegExp(r'#.*$'), '#${base64Url.encode(List.filled(32, 7)).substring(0, 43)}');
    await expectLater(cloud.fetch(wrongKey, out), throwsA(anything));
    expect(out.existsSync(), isFalse);
    expect(File('${out.path}.part').existsSync(), isFalse);
    expect(ChatCloudMedia.parse('fyc:$link/${p.sha}#short'), isNull);
    expect(ChatCloudMedia.parse('fyc:../x/${p.sha}.jpg#${'a' * 43}'), isNull);
    // Gone from the cloud (message purged): false, not an error.
    r2.objects.clear();
    expect(await cloud.fetch(ref, out), isFalse);
  });

  test('the chat store keeps the file once, offline afterwards; old server links unchanged', () async {
    final img = _bytes(3, 50000);
    final src = File('${dir.path}/a.png')..writeAsBytesSync(img);
    final cloud = ChatMediaStore.cloud = ChatCloudMedia(FakeRemote(r2), temp: Directory('${dir.path}/tmp'));
    final ref = await cloud.upload(link, src, 'a.png', 'image/png');
    expect(ChatMediaStore.isChatMedia(ref), isTrue);
    expect(ChatMediaStore.absolute(ref), ref);
    expect(ChatMediaStore.key(ref), endsWith('.png'));
    final f = await ChatMediaStore.fetchFile(ref);
    expect(f!.readAsBytesSync(), img);
    r2.down = true; // offline: the kept copy
    expect((await ChatMediaStore.fetchFile(ref))!.readAsBytesSync(), img);
    expect(ChatMediaStore.isChatMedia('uploads/chat/x.jpg'), isTrue);
  });

  test('a cancelled upload stops and leaves nothing behind', () async {
    final src = File('${dir.path}/big.mp4')..writeAsBytesSync(_bytes(4, 2 * 1024 * 1024));
    final cloud = ChatCloudMedia(FakeRemote(r2), temp: Directory('${dir.path}/tmp'));
    await expectLater(cloud.upload(link, src, 'big.mp4', 'video/mp4', cancelled: () => true),
        throwsA(isA<ChatUploadCancelled>()));
    expect(r2.objects, isEmpty);
    expect(Directory('${dir.path}/tmp').listSync(), isEmpty);
  });

  final presign = Platform.environment['FYONA_R2_PRESIGN'];
  test('REAL Cloudflare R2: encrypted upload, private, byte-exact download, removed', () async {
    final tenant = 'c_e2e${DateTime.now().millisecondsSinceEpoch}';
    final remote = _PresignRemote(presign!, tenant);
    final cloud = ChatCloudMedia(remote, temp: Directory('${dir.path}/tmp'));
    final voice = _bytes(5, 1500000);
    final src = File('${dir.path}/v.m4a')..writeAsBytesSync(voice);
    final sw = Stopwatch()..start();
    final ref = await cloud.upload(link, src, 'v.m4a', 'audio/mp4');
    final up = sw.elapsedMilliseconds;
    final key = remote.keys.single;
    // Private: the object is not readable without a signature.
    final get = await remote.downloadUrl(MediaSection.chat, ChatCloudMedia.parse(ref)!.sha);
    final plain = await (await HttpClient().getUrl(Uri.parse(get.split('?').first))).close();
    expect(plain.statusCode, anyOf(400, 401, 403));
    final out = File('${dir.path}/v-back.m4a');
    sw.reset();
    expect(await cloud.fetch(ref, out), isTrue);
    expect(out.readAsBytesSync(), voice);
    // ignore: avoid_print
    print('R2_E2E upload ${up}ms download+verify+decrypt ${sw.elapsedMilliseconds}ms (${voice.length} bytes)');
    expect(await Process.run(presign, ['DELETE', key]).then((r) => r.exitCode), 0);
    expect(await cloud.fetch(ref, out), isFalse);
  }, skip: presign == null ? 'set FYONA_R2_PRESIGN to run against real R2' : false);
}
