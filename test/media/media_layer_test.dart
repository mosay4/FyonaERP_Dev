import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/media/media_store.dart';
import 'package:fyona_flutter/core/media/media_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A local HTTP server standing in for R2 presigned URLs (PUT / GET).
class FakeR2 {
  FakeR2._(this._server);
  final HttpServer _server;
  final Map<String, Uint8List> objects = {};
  bool down = false;
  int puts = 0;
  final Set<String> tamper = {};

  static Future<FakeR2> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final r = FakeR2._(s);
    s.listen(r._handle);
    return r;
  }

  String url(String key) => 'http://127.0.0.1:${_server.port}/$key';

  Future<void> _handle(HttpRequest req) async {
    final key = req.uri.path.substring(1);
    if (down) {
      req.response.statusCode = 503;
      await req.response.close();
      return;
    }
    if (req.method == 'PUT') {
      final b = BytesBuilder();
      await for (final part in req) {
        b.add(part);
      }
      final declared = int.tryParse(req.headers.value('content-length') ?? '');
      final body = b.takeBytes();
      if (declared != body.length) {
        req.response.statusCode = 403;
      } else {
        objects[key] = body;
        puts++;
      }
    } else if (req.method == 'GET') {
      final o = objects[key];
      if (o == null) {
        req.response.statusCode = 404;
      } else {
        req.response.add(tamper.contains(key) ? (Uint8List.fromList(o)..[0] ^= 0xFF) : o);
      }
    }
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// Server side stand-in: tenant = section (+ link), HEAD = object present.
class FakeRemote implements MediaRemote {
  FakeRemote(this.r2);
  final FakeR2 r2;
  int uploadUrls = 0;

  String _key(MediaSection s, String sha, String? link) => 't/${s.name}${link ?? ''}/m/$sha';

  @override
  Future<Map<String, dynamic>> uploadUrl(MediaSection section, String sha,
      {required int size, required String mime, String? linkId}) async {
    if (r2.down) throw const SocketException('down');
    uploadUrls++;
    final key = _key(section, sha, linkId);
    if (r2.objects[key]?.length == size) return {'exists': true};
    return {'url': r2.url(key), 'headers': {'content-type': mime, 'content-length': '$size'}};
  }

  @override
  Future<void> commit(MediaSection section, String sha, {required int size, String? linkId}) async {
    if (r2.objects[_key(section, sha, linkId)]?.length != size) throw StateError('incomplete');
  }

  @override
  Future<String> downloadUrl(MediaSection section, String sha, {String? linkId}) async =>
      r2.url(_key(section, sha, linkId));
}

Uint8List _jpeg(int seed, int size) {
  final r = Random(seed);
  final b = Uint8List(size);
  for (var i = 0; i < size; i++) {
    b[i] = r.nextInt(256);
  }
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[2] = 0xFF;
  return b;
}

void main() {
  late Directory dir;
  late MediaStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('fyona-media-');
    store = MediaStore(Directory('${dir.path}/media'));
  });
  tearDown(() => dir.delete(recursive: true));

  group('store', () {
    test('a file is stored once, by fingerprint, and the record keeps only a short ref', () async {
      final img = _jpeg(1, 300 * 1024);
      final a = await store.put(img, mime: 'image/jpeg');
      final b = await store.put(img, mime: 'image/jpeg');
      expect(a, b);
      expect(a.length, 'media:'.length + 64);
      expect(MediaStore.isRef(a), isTrue);
      expect(await store.usedBytes(), img.length);
      expect(store.readSync(a), img);
      expect(store.metaOf(a)!.mime, 'image/jpeg');
      // No half-written file survives under a real name.
      final parts = dir.listSync(recursive: true).where((e) => e.path.endsWith('.part'));
      expect(parts, isEmpty);
    });

    test('only bytes that match the fingerprint are accepted', () async {
      final img = _jpeg(2, 1000);
      final sha = MediaStore.shaHex(img);
      expect(await store.putVerified(sha, Uint8List.fromList(img)..[5] ^= 1, mime: 'image/jpeg'), isFalse);
      expect(store.fileOf(MediaStore.refFor(sha)), isNull);
      expect(await store.putVerified(sha, img, mime: 'image/jpeg'), isTrue);
    });

    test('sweep removes only files no record references', () async {
      final keep = await store.put(_jpeg(3, 500), mime: 'image/jpeg');
      final drop = await store.put(_jpeg(4, 500), mime: 'image/jpeg');
      expect(await store.sweep({keep}), 1);
      expect(store.fileOf(keep), isNotNull);
      expect(store.fileOf(drop), isNull);
    });

    test('thousands of images: time, disk and memory stay bounded (measured)', () async {
      const n = 2000;
      final rssBefore = ProcessInfo.currentRss;
      final sw = Stopwatch()..start();
      final refs = <String>{};
      for (var i = 0; i < n; i++) {
        // 1 in 4 is a repeat of an earlier picture (same product photo reused).
        refs.add(await store.put(_jpeg(i % 1500, 20 * 1024), mime: 'image/jpeg'));
      }
      sw.stop();
      final used = await store.usedBytes();
      final rssGrowth = ProcessInfo.currentRss - rssBefore;
      // ignore: avoid_print
      print('MEDIA_BENCH n=$n unique=${refs.length} ms=${sw.elapsedMilliseconds} '
          'disk=${(used / 1048576).toStringAsFixed(1)}MB rssGrowth=${(rssGrowth / 1048576).toStringAsFixed(1)}MB');
      expect(refs.length, 1500);
      expect(used, 1500 * 20 * 1024); // duplicates cost nothing
      expect(rssGrowth, lessThan(200 * 1024 * 1024));
    });
  });

  group('cloud sync (real HTTP to a local R2 stand-in)', () {
    late FakeR2 r2;
    late FakeRemote remote;
    setUp(() async {
      r2 = await FakeR2.start();
      remote = FakeRemote(r2);
    });
    tearDown(() => r2.close());

    test('queued uploads survive an app kill and reach the cloud later', () async {
      final ref = await store.put(_jpeg(5, 50 * 1024), mime: 'image/jpeg');
      await MediaSync.queue(store, ref, MediaSection.business);
      // "Kill": a brand-new instance only knows what was persisted.
      final fresh = MediaSync(store: store, remote: remote);
      expect(await fresh.pending(), 1);
      expect(await fresh.drain(), 1);
      expect(await fresh.pending(), 0);
      expect(r2.objects.values.single, store.readSync(ref));
    });

    test('the same picture is never uploaded twice', () async {
      final ref = await store.put(_jpeg(6, 4096), mime: 'image/jpeg');
      final sync = MediaSync(store: store, remote: remote);
      await sync.enqueue(ref, MediaSection.business);
      await sync.drain();
      await sync.enqueue(ref, MediaSection.business);
      await sync.drain();
      expect(r2.puts, 1);
    });

    test('cloud outage: nothing lost, retried with back-off, user never blocked', () async {
      var clock = 1000000;
      final ref = await store.put(_jpeg(7, 4096), mime: 'image/jpeg');
      final sync = MediaSync(store: store, remote: remote, now: () => clock);
      await sync.enqueue(ref, MediaSection.personal);
      r2.down = true;
      expect(await sync.drain(), 0);
      expect(await sync.pending(), 1);
      r2.down = false;
      expect(await sync.drain(), 0, reason: 'backing off');
      clock += 60 * 1000;
      expect(await sync.drain(), 1);
      expect(await sync.pending(), 0);
    });

    test('a new device downloads on demand and rejects a tampered file', () async {
      final img = _jpeg(8, 8192);
      final other = MediaStore(Directory('${dir.path}/other'));
      final ref = await other.put(img, mime: 'image/jpeg');
      await MediaSync(store: other, remote: remote).enqueue(ref, MediaSection.business);
      await MediaSync(store: other, remote: remote).drain();

      final sync = MediaSync(store: store, remote: remote);
      final f = await sync.ensureLocal(ref, MediaSection.business, mime: 'image/jpeg');
      expect(f, isNotNull);
      expect(await f!.readAsBytes(), img);

      final img2 = _jpeg(9, 8192);
      final ref2 = await other.put(img2, mime: 'image/jpeg');
      await MediaSync(store: other, remote: remote).enqueue(ref2, MediaSection.business);
      await MediaSync(store: other, remote: remote).drain();
      r2.tamper.add('t/business/m/${MediaStore.shaOf(ref2)}');
      expect(await sync.ensureLocal(ref2, MediaSection.business), isNull);
      expect(store.fileOf(ref2), isNull);
    });

    test('spaces are separate: a business file is not found as personal', () async {
      final ref = await store.put(_jpeg(10, 2048), mime: 'image/jpeg');
      final sync = MediaSync(store: store, remote: remote);
      await sync.enqueue(ref, MediaSection.business);
      await sync.drain();
      final elsewhere = MediaStore(Directory('${dir.path}/x'));
      expect(await MediaSync(store: elsewhere, remote: remote).ensureLocal(ref, MediaSection.personal), isNull);
    });

    test('a large video is streamed from disk to the cloud', () async {
      final big = File('${dir.path}/video.mp4');
      final raf = big.openSync(mode: FileMode.write);
      final chunk = _jpeg(11, 1 << 20);
      for (var i = 0; i < 24; i++) {
        raf.writeFromSync(chunk);
      }
      raf.closeSync();
      final ref = await store.putFile(big, mime: 'video/mp4');
      final sync = MediaSync(store: store, remote: remote);
      await sync.enqueue(ref, MediaSection.chat, linkId: 'L1');
      expect(await sync.drain(), 1);
      expect(r2.objects.values.single.length, 24 << 20);
    });
  });
}
