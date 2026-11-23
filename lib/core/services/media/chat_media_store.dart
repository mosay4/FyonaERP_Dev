import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../config/app_config.dart';

/// Chat attachments (pictures, videos, voice notes, files) kept on the
/// device for good. The server only carries a file until both sides have it
/// and then deletes it, so every later view, playback or save reads this
/// copy, online or offline.
abstract final class ChatMediaStore {
  static final Map<String, Future<Uint8List?>> _pending = {};
  static Directory? _dir;

  /// Chat attachments only (other protected images keep their own cache).
  static bool isChatMedia(String url) => url.contains('uploads/chat/');

  /// The same attachment whatever host or form the URL was written in.
  static String _path(String url) {
    final u = url.trim();
    final i = u.indexOf('uploads/');
    return i < 0 ? u : u.substring(i);
  }

  /// Full address to download a stored path (as the chat page builds it).
  static String absolute(String url) {
    final u = url.trim();
    if (u.isEmpty || u.startsWith('http')) return u;
    return '${AppConfig.apiHostUrl}/${_path(u)}';
  }

  /// Download what a message refers to, in the background, so it is on the
  /// device before the server deletes it.
  static void keep(Dio dio, Iterable<Map> messages) {
    for (final m in messages) {
      for (final url in urlsOf(m)) {
        if (!url.contains('uploads/')) continue;
        unawaited(bytes(dio, absolute(url)).catchError((Object _) => null));
      }
    }
  }

  /// Stable file name for a URL (FNV-1a, 64-bit spread over two halves).
  static String key(String raw) {
    final url = _path(raw);
    var a = 0x811C9DC5, b = 0x01000193;
    for (var i = 0; i < url.length; i++) {
      a = ((a ^ url.codeUnitAt(i)) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ url.codeUnitAt(url.length - 1 - i)) * 0x01000193) & 0xFFFFFFFF;
    }
    // Keep the extension: players pick the format from it.
    final name = url.split('?').first.split('/').last;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 6 ? name.substring(dot).toLowerCase() : '';
    return '${a.toRadixString(16).padLeft(8, '0')}${b.toRadixString(16).padLeft(8, '0')}$ext';
  }

  static Future<Directory> _folder() async {
    final dir = _dir ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/chat_media',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// Test hook: keep the files in a given folder.
  static set debugFolder(Directory? dir) => _dir = dir;

  /// Where this attachment is (or will be) kept.
  static Future<String> pathFor(String url) async =>
      '${(await _folder()).path}/${key(url)}';

  /// The stored file, when this attachment is already on the device.
  static Future<File?> file(String url) async {
    final f = File('${(await _folder()).path}/${key(url)}');
    return await f.exists() && await f.length() > 0 ? f : null;
  }

  /// The attachment's bytes: from the device, or downloaded once and kept.
  static Future<Uint8List?> bytes(Dio dio, String url) {
    if (url.trim().isEmpty) return Future.value(null);
    return _pending[url] ??= () async {
      try {
        final local = await file(url);
        if (local != null) return await local.readAsBytes();
        final res = await dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        final data = res.data;
        if (data == null || data.isEmpty) return null;
        final out = Uint8List.fromList(data);
        await save(url, out);
        return out;
      } finally {
        unawaited(_pending.remove(url));
      }
    }();
  }

  /// Keep bytes we already have (e.g. our own upload) under the URL.
  static Future<void> save(String url, List<int> data) async {
    if (url.trim().isEmpty || data.isEmpty) return;
    final target = File('${(await _folder()).path}/${key(url)}');
    final tmp = File('${target.path}.part');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(target.path);
  }

  /// Every attachment URL a chat message refers to.
  static List<String> urlsOf(Map message) => [
    for (final u in [
      message['url'],
      message['media_url'],
      message['media_path'],
      message['thumbnail'],
      for (final it in (message['media'] as List?) ?? const [])
        if (it is Map) ...[it['url'], it['thumbnail']],
    ])
      if (u is String && u.trim().isNotEmpty) u.trim(),
  ];
}
