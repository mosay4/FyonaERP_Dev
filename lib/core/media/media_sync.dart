import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'media_store.dart';

/// The FYONA server side of media: short-lived presigned URLs only.
abstract class MediaRemote {
  /// {exists: true} or {url, headers} for a PUT.
  Future<Map<String, dynamic>> uploadUrl(MediaSection section, String sha,
      {required int size, required String mime, String? linkId});
  Future<void> commit(MediaSection section, String sha, {required int size, String? linkId});
  Future<String> downloadUrl(MediaSection section, String sha, {String? linkId});
}

/// Bytes to / from a presigned URL (R2). Replaceable in tests.
abstract class MediaTransfer {
  Future<int> put(String url, Map<String, String> headers, File file);
  Future<Uint8List> get(String url);
}

class HttpMediaTransfer implements MediaTransfer {
  HttpMediaTransfer({this.timeout = const Duration(minutes: 5)});
  final Duration timeout;

  @override
  Future<int> put(String url, Map<String, String> headers, File file) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl('PUT', Uri.parse(url));
      headers.forEach(req.headers.set);
      // Streamed from disk: a large video never sits in memory.
      await req.addStream(file.openRead());
      final res = await req.close().timeout(timeout);
      await res.drain<void>();
      return res.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Uint8List> get(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close().timeout(timeout);
      if (res.statusCode != 200) throw HttpException('download ${res.statusCode}');
      final b = BytesBuilder(copy: false);
      await for (final part in res) {
        b.add(part);
      }
      return b.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}

/// One pending upload (persisted until the cloud has it).
class _Job {
  _Job(this.sha, this.section, this.mime, this.size, {this.linkId, this.attempts = 0, this.notBefore = 0});
  final String sha;
  final MediaSection section;
  final String mime;
  final int size;
  final String? linkId;
  int attempts;
  int notBefore; // ms epoch

  String get key => '${section.name}:${linkId ?? ''}:$sha';

  Map<String, dynamic> toJson() => {
        'sha': sha, 's': section.name, 'm': mime, 'z': size,
        if (linkId != null) 'l': linkId, 'a': attempts, 'n': notBefore,
      };

  static _Job? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = MediaSection.values.where((x) => x.name == j['s']).firstOrNull;
    if (s == null || j['sha'] is! String) return null;
    return _Job('${j['sha']}', s, '${j['m'] ?? 'application/octet-stream'}', (j['z'] as num?)?.toInt() ?? 0,
        linkId: j['l'] as String?, attempts: (j['a'] as num?)?.toInt() ?? 0, notBefore: (j['n'] as num?)?.toInt() ?? 0);
  }
}

/// Moves media between this device and Cloudflare R2 through the FYONA
/// server's presigned URLs — never through the server itself.
///
/// * Uploads are queued durably (SharedPreferences) the moment a file is
///   added, and drained when online; app kill / reboot only delays them.
/// * A file the cloud already holds is never uploaded again (server HEAD).
/// * Downloads are verified against the SHA-256 in the reference before they
///   are accepted, so a wrong / tampered file is never shown or restored.
/// * Failures back off (2 s → 10 min) and never block the user's work.
class MediaSync {
  MediaSync({required this.store, required this.remote, MediaTransfer? transfer, this.now})
      : transfer = transfer ?? HttpMediaTransfer();

  final MediaStore store;
  final MediaRemote remote;
  final MediaTransfer transfer;
  final int Function()? now;

  static const _kQueue = 'media_upload_queue_v1';
  static const maxAttempts = 50;

  int _now() => now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  Future<List<_Job>> _load() async {
    final p = await SharedPreferences.getInstance();
    try {
      return [
        for (final j in (jsonDecode(p.getString(_kQueue) ?? '[]') as List)) ?_Job.fromJson(j),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<_Job> jobs) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kQueue, jsonEncode([for (final j in jobs) j.toJson()]));
  }

  /// Number of files still waiting for the cloud.
  Future<int> pending() async => (await _load()).length;

  /// Queues [ref] for upload (idempotent).
  Future<void> enqueue(String ref, MediaSection section, {String? linkId}) =>
      queue(store, ref, section, linkId: linkId);

  /// Queues from anywhere (no instance needed): the job is durable at once
  /// and the running uploader is woken through [kicks].
  static Future<void> queue(MediaStore store, String ref, MediaSection section, {String? linkId}) async {
    final sha = MediaStore.shaOf(ref);
    final meta = store.metaOf(ref);
    if (sha == null || meta == null) return;
    final p = await SharedPreferences.getInstance();
    List<_Job> jobs;
    try {
      jobs = [for (final j in (jsonDecode(p.getString(_kQueue) ?? '[]') as List)) ?_Job.fromJson(j)];
    } catch (_) {
      jobs = [];
    }
    final job = _Job(sha, section, meta.mime, meta.size, linkId: linkId);
    if (!jobs.any((j) => j.key == job.key)) {
      jobs.add(job);
      await p.setString(_kQueue, jsonEncode([for (final j in jobs) j.toJson()]));
    }
    _kicks.add(null);
  }

  static final _kicks = StreamController<void>.broadcast();

  /// Fires when something was queued (the app's uploader drains on it).
  static Stream<void> get kicks => _kicks.stream;

  bool _draining = false;

  /// Uploads what is due. Returns how many files reached the cloud.
  Future<int> drain() async {
    if (_draining) return 0;
    _draining = true;
    var done = 0;
    try {
      final jobs = await _load();
      for (final job in List<_Job>.of(jobs)) {
        if (job.notBefore > _now()) continue;
        final ok = await _upload(job);
        if (ok) {
          jobs.removeWhere((j) => j.key == job.key);
          done++;
        } else {
          job.attempts++;
          final backoff = Duration(seconds: (2 << job.attempts.clamp(0, 9)).clamp(2, 600));
          job.notBefore = _now() + backoff.inMilliseconds;
          if (job.attempts >= maxAttempts || store.fileOf(MediaStore.refFor(job.sha)) == null) {
            jobs.removeWhere((j) => j.key == job.key); // file gone: nothing left to send
          }
        }
        await _save(jobs); // progress survives a kill after every file
      }
    } finally {
      _draining = false;
    }
    return done;
  }

  Future<bool> _upload(_Job job) async {
    final file = store.fileOf(MediaStore.refFor(job.sha));
    if (file == null) return false;
    try {
      final r = await remote.uploadUrl(job.section, job.sha, size: job.size, mime: job.mime, linkId: job.linkId);
      if (r['exists'] == true) return true;
      final headers = {for (final e in (r['headers'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
      final status = await transfer.put('${r['url']}', headers, file);
      if (status != 200) return false;
      await remote.commit(job.section, job.sha, size: job.size, linkId: job.linkId);
      return true;
    } catch (_) {
      return false;
    }
  }

  final Map<String, Future<File?>> _inflight = {};

  /// The local file for [ref], downloading (and verifying) it when needed.
  Future<File?> ensureLocal(String ref, MediaSection section, {String? linkId, String mime = 'application/octet-stream'}) {
    final local = store.fileOf(ref);
    if (local != null) return Future.value(local);
    final sha = MediaStore.shaOf(ref);
    if (sha == null) return Future.value(null);
    return _inflight[sha] ??= () async {
      try {
        final url = await remote.downloadUrl(section, sha, linkId: linkId);
        final bytes = await transfer.get(url);
        if (!await store.putVerified(sha, bytes, mime: mime)) return null;
        return store.fileOf(ref);
      } catch (_) {
        return null;
      } finally {
        _inflight.remove(sha);
      }
    }();
  }
}
