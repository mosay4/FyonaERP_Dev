import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../backup/backup_crypto.dart';
import '../backup/backup_stream.dart';
import 'media_store.dart';
import 'media_sync.dart';

/// Chat attachments (pictures, videos, voice notes, files) through
/// Cloudflare R2 — the FYONA server never stores their bytes.
///
/// The sender's device encrypts the file with a fresh random 256-bit key
/// (FYBK frames: ChaCha20-Poly1305, 1 MiB, every frame authenticated) and
/// uploads the ciphertext with a short-lived presigned URL to the chat's
/// private space `t/c_<link>/m/<sha256 of the ciphertext>` (only the two
/// participants get URLs, see backend storage.py). The message carries the
/// reference `fyc:<link>/<sha>.<ext>#<key>`; the receiving device downloads,
/// checks the SHA-256, decrypts and keeps the file for good. Cloudflare only
/// ever holds ciphertext; the object is deleted with the message on the server.
class ChatCloudMedia {
  ChatCloudMedia(this.remote, {Directory? temp}) : _temp = temp;

  final MediaRemote remote;
  final Directory? _temp;
  static final _rng = Random.secure();
  static final _ref = RegExp(r'^fyc:([0-9a-f-]{36})/([0-9a-f]{64})(\.[a-z0-9]{1,5})?#([A-Za-z0-9_-]{43})$');

  /// Largest attachment (the server signs at most 400 MB for a video).
  static const maxBytes = 400 * 1024 * 1024;

  static bool isRef(String s) => s.startsWith('fyc:');

  static ({String link, String sha, String ext, Uint8List key})? parse(String ref) {
    final m = _ref.firstMatch(ref.trim());
    if (m == null) return null;
    final key = base64Url.decode('${m.group(4)}=');
    if (key.length != 32) return null;
    return (link: m.group(1)!, sha: m.group(2)!, ext: m.group(3) ?? '', key: Uint8List.fromList(key));
  }

  Future<Directory> _tmp() async {
    final d = _temp ?? Directory('${Directory.systemTemp.path}/fyona-chat-media');
    await d.create(recursive: true);
    return d;
  }

  static String _ext(String name) {
    final n = name.split('/').last.toLowerCase();
    final dot = n.lastIndexOf('.');
    if (dot <= 0 || n.length - dot > 6) return '';
    final e = n.substring(dot);
    return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(e) ? e : '';
  }

  /// Encrypts and uploads [source]; returns the message reference.
  /// [onProgress] (sent, total) of the upload; [cancelled] stops it.
  Future<String> upload(String linkId, File source, String fileName, String mime,
      {void Function(int sent, int total)? onProgress, bool Function()? cancelled}) async {
    final size = await source.length();
    if (size <= 0) throw const FileSystemException('empty file');
    if (size > maxBytes) throw const FileSystemException('file too large');
    final key = Uint8List.fromList(List.generate(32, (_) => _rng.nextInt(256)));
    final sealed = File('${(await _tmp()).path}/up-${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 30)}');
    try {
      final w = BackupFileWriter(sealed, BackupKeys.keyFrom(key));
      try {
        await for (final b in source.openRead()) {
          if (cancelled?.call() == true) throw const ChatUploadCancelled();
          await w.add(b);
        }
        await w.close();
      } catch (_) {
        await w.abort();
        rethrow;
      }
      final sha = (await sha256.bind(sealed.openRead()).first).toString();
      final length = await sealed.length();
      final r = await remote.uploadUrl(MediaSection.chat, sha, size: length, mime: mime, linkId: linkId);
      if (r['exists'] != true) {
        final url = '${r['url'] ?? ''}';
        if (url.isEmpty) throw const HttpException('no upload url');
        final headers = {for (final e in ((r['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
        await _put(url, headers, sealed, length, onProgress, cancelled);
        await remote.commit(MediaSection.chat, sha, size: length, linkId: linkId);
      }
      onProgress?.call(length, length);
      return 'fyc:$linkId/$sha${_ext(fileName)}#${base64Url.encode(key).substring(0, 43)}';
    } finally {
      if (await sealed.exists()) await sealed.delete();
    }
  }

  static Future<void> _put(String url, Map<String, String> headers, File file, int length,
      void Function(int, int)? onProgress, bool Function()? cancelled) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.openUrl('PUT', Uri.parse(url));
      headers.forEach(req.headers.set);
      req.contentLength = length;
      var sent = 0;
      await req.addStream(file.openRead().map((b) {
        if (cancelled?.call() == true) {
          client.close(force: true);
          throw const ChatUploadCancelled();
        }
        sent += b.length;
        onProgress?.call(sent, length);
        return b;
      }));
      final res = await req.close().timeout(const Duration(minutes: 10));
      await res.drain<void>();
      if (res.statusCode != 200) throw HttpException('upload ${res.statusCode}');
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the attachment [ref] into [into] (decrypted, verified).
  /// False when it is no longer in the cloud (the sender's copy and the
  /// copies already kept on devices remain).
  Future<bool> fetch(String ref, File into, {MediaTransfer? transfer}) async {
    final p = parse(ref);
    if (p == null) throw const FormatException('not a chat media reference');
    final url = await remote.downloadUrl(MediaSection.chat, p.sha, linkId: p.link);
    final sealed = File('${(await _tmp()).path}/down-${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 30)}');
    try {
      if (!await (transfer ?? HttpMediaTransfer(timeout: const Duration(minutes: 10))).download(url, sealed)) {
        return false;
      }
      if (await sealed.length() > maxBytes + (maxBytes >> 10)) throw const FormatException('too large');
      final got = (await sha256.bind(sealed.openRead()).first).toString();
      if (got != p.sha) throw const FormatException('attachment altered');
      await into.parent.create(recursive: true);
      final part = File('${into.path}.part');
      final sink = part.openWrite();
      try {
        await sink.addStream(BackupStream.frames(sealed, BackupKeys.keyFrom(p.key)));
        await sink.flush();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        if (await part.exists()) await part.delete();
        rethrow;
      }
      await sink.close();
      await part.rename(into.path);
      return true;
    } finally {
      if (await sealed.exists()) await sealed.delete();
    }
  }
}

class ChatUploadCancelled implements Exception {
  const ChatUploadCancelled();
}

/// The chat side of the FYONA storage endpoints over a plain [Dio] (the
/// app's authenticated client, or the background uploader's own).
class DioChatMediaRemote implements MediaRemote {
  DioChatMediaRemote(this.dio);
  final Dio dio;

  Map<String, dynamic> _scope(String? linkId) => {'section': 'chat', 'link_id': linkId, 'area': 'm'};

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await dio.post<dynamic>(path, data: body);
    final m = r.data is Map ? r.data as Map : const {};
    final d = m['data'];
    return d is Map ? Map<String, dynamic>.from(d) : const {};
  }

  @override
  Future<Map<String, dynamic>> uploadUrl(MediaSection section, String sha,
          {required int size, required String mime, String? linkId}) =>
      _post('/storage/upload-url', {..._scope(linkId), 'sha256': sha, 'size': size, 'content_type': mime});

  @override
  Future<void> commit(MediaSection section, String sha, {required int size, String? linkId}) =>
      _post('/storage/commit', {..._scope(linkId), 'sha256': sha, 'size': size});

  @override
  Future<String> downloadUrl(MediaSection section, String sha, {String? linkId}) async =>
      '${(await _post('/storage/download-url', {..._scope(linkId), 'sha256': sha}))['url']}';
}
