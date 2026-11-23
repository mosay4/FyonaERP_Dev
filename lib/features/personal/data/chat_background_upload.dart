import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

const String chatUploadTaskName = 'fyona.chat.upload';

@pragma('vm:entry-point')
void chatUploadCallbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    final path = '${inputData?['job_path'] ?? ''}';
    if (path.isEmpty) return true;
    return ChatBackgroundUpload.runJobFile(path);
  });
}

class ChatBackgroundUpload {
  static FlutterLocalNotificationsPlugin? _notifications;
  static bool _notificationsReady = false;

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/chat_upload_queue');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<String?> _copy(
    String? path,
    String id,
    int index,
    String name,
    Uint8List? bytes,
  ) async {
    final dir = await _dir();
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final target = '${dir.path}/${id}_$index-$safe';
    if (bytes != null) {
      await File(target).writeAsBytes(bytes, flush: true);
      return target;
    }
    if (path != null && path.isNotEmpty) {
      final f = File(path);
      if (await f.exists()) {
        await f.copy(target);
        return target;
      }
    }
    return null;
  }

  static Future<void> enqueueSingle({
    required String linkId,
    required String side,
    required String kind,
    required String id,
    Uint8List? bytes,
    String? path,
    required String fileName,
    String? caption,
    String? replyToId,
    int? durationMs,
    required String baseUrl,
    String? token,
  }) async {
    try {
      final stored = await _copy(path, id, 0, fileName, bytes);
      if (stored == null) return;
      final job = <String, dynamic>{
        'id': id,
        'type': 'single',
        'link_id': linkId,
        'side': side,
        'kind': kind,
        'file_name': fileName,
        'path': stored,
        'caption': caption,
        'reply_to_id': replyToId,
        'duration_ms': durationMs,
        'base_url': baseUrl,
        'token': token,
        'pct': 0,
        'attempts': 0,
      };
      final file = File('${(await _dir()).path}/$id.json');
      await file.writeAsString(jsonEncode(job), flush: true);
      await _schedule(id, file.path);
      await touch(id);
    } catch (_) {}
  }

  static Future<void> enqueueAlbum({
    required String linkId,
    required String side,
    required String id,
    required List<Map<String, dynamic>> items,
    String? caption,
    String? replyToId,
    required String baseUrl,
    String? token,
  }) async {
    try {
      final stored = <Map<String, dynamic>>[];
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final path = await _copy(
          it['path'] == null ? null : '${it['path']}',
          id,
          i,
          '${it['name']}',
          it['bytes'] as Uint8List?,
        );
        if (path == null) continue;
        stored.add({
          'url': '',
          'path': path,
          'name': '${it['name']}',
          'kind': '${it['kind']}',
        });
      }
      if (stored.isEmpty) return;
      final job = <String, dynamic>{
        'id': id,
        'type': 'album',
        'link_id': linkId,
        'side': side,
        'kind': 'album',
        'media': stored,
        'caption': caption,
        'reply_to_id': replyToId,
        'base_url': baseUrl,
        'token': token,
        'pct': 0,
        'attempts': 0,
      };
      final file = File('${(await _dir()).path}/$id.json');
      await file.writeAsString(jsonEncode(job), flush: true);
      await _schedule(id, file.path);
      await touch(id);
    } catch (_) {}
  }

  static Future<void> _schedule(String id, String jobPath) async {
    await Workmanager().registerOneOffTask(
      'chat-upload-$id',
      chatUploadTaskName,
      inputData: {'job_path': jobPath},
      initialDelay: const Duration(seconds: 60),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
      foregroundServiceConfig: ForegroundServiceConfig(
        notificationTitle: 'FYONA — رفع الوسائط',
        notificationText: 'جارٍ رفع الوسائط في الخلفية',
        notificationChannelId: 'chat_upload_progress',
        notificationChannelName: 'Chat uploads',
        notificationId: 9081,
        foregroundServiceType: ForegroundServiceType.dataSync,
      ),
    );
  }

  static Future<void> touch(String id) async {
    try {
      final d = await _dir();
      await File('${d.path}/$id.live').writeAsString('1', flush: true);
    } catch (_) {}
  }

  /// A terminal foreground failure must not be silently retried by WorkManager.
  /// Keep the persisted source for an explicit retry with the SAME client ID.
  static Future<void> setFailed(String id, bool failed) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/$id.json');
      if (!await file.exists()) return;
      final job = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      job['failed'] = failed;
      if (!failed) job['attempts'] = 0;
      await file.writeAsString(jsonEncode(job), flush: true);
      if (!failed) await _schedule(id, file.path);
    } catch (_) {}
  }

  static Future<void> remove(String id) async {
    try {
      final dir = await _dir();
      try {
        final live = File('${dir.path}/$id.live');
        if (await live.exists()) await live.delete();
      } catch (_) {}
      // A completion/cancel tombstone closes the small race where the
      // foreground upload finishes before the queued job file is written.
      await File('${dir.path}/$id.done').writeAsString('1', flush: true);
      final f = File('${dir.path}/$id.json');
      if (await f.exists()) {
        final job = jsonDecode(await f.readAsString()) as Map;
        for (final m in (job['media'] as List? ?? const [])) {
          if (m is Map && m['path'] != null) {
            final p = File('${m['path']}');
            if (await p.exists()) await p.delete();
          }
        }
        if (job['path'] != null) {
          final p = File('${job['path']}');
          if (await p.exists()) await p.delete();
        }
        await f.delete();
      }
      await _notificationsCancel(id.hashCode & 0x7fffffff);
    } catch (_) {}
  }

  static Future<bool> runJobFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return true;
    final live = File(path.replaceFirst(RegExp(r'\.json$'), '.live'));
    if (await live.exists()) {
      final age = DateTime.now().difference((await live.stat()).modified);
      if (age.inSeconds < 20) return false;
    }
    final done = File(path.replaceFirst(RegExp(r'\.json$'), '.done'));
    if (await done.exists()) {
      try {
        await file.delete();
        await done.delete();
      } catch (_) {}
      return true;
    }
    Map<String, dynamic> job;
    try {
      job = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    } catch (_) {
      return true;
    }
    final id = '${job['id'] ?? ''}';
    final base = '${job['base_url'] ?? ''}';
    if (id.isEmpty || base.isEmpty) {
      await file.delete();
      return true;
    }
    final token = '${job['token'] ?? ''}';
    if (job['failed'] == true || ((job['attempts'] as num?)?.toInt() ?? 0) >= 3)
      return true;
    final dio = Dio(
      BaseOptions(
        baseUrl: base,
        headers: {if (token.isNotEmpty) 'Authorization': token},
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    try {
      if ('${job['type']}' == 'album') {
        final uploaded = <Map<String, dynamic>>[];
        final media = (job['media'] as List? ?? const []).whereType<Map>();
        var i = 0;
        for (final it in media) {
          final path = '${it['path'] ?? ''}';
          if (path.isEmpty || !await File(path).exists()) continue;
          final uploadedMedia = await _upload(
            dio,
            job,
            id,
            path,
            '${it['name']}',
            (sent, total) {
              if (total <= 0) return;
              final pct = (((i + sent / total) / media.length) * 100)
                  .round()
                  .clamp(0, 100);
              _heartbeat(file, job, pct);
              _showProgress(id, '${media.length} files', pct);
            },
          );
          uploaded.add({
            'url': uploadedMedia['url'] ?? '',
            'thumbnail': uploadedMedia['thumbnail'] ?? '',
            'kind': '${it['kind']}',
            'file_name': '${it['name']}',
          });
          i++;
        }
        if (uploaded.isEmpty) {
          await file.delete();
          return true;
        }
        await dio.post(
          '/chat/${job['link_id']}/messages',
          data: {
            'kind': 'album',
            if ('${job['side']}'.isNotEmpty) 'side': '${job['side']}',
            'media': uploaded,
            if (_text(job) != null) 'text': _text(job),
            if ('${job['reply_to_id'] ?? ''}'.isNotEmpty)
              'reply_to_id': '${job['reply_to_id']}',
            'client_id': id,
            'client_message_id': id,
          },
        );
      } else {
        final path = '${job['path'] ?? ''}';
        if (path.isEmpty || !await File(path).exists()) {
          await file.delete();
          return true;
        }
        final uploadedMedia = await _upload(
          dio,
          job,
          id,
          path,
          '${job['file_name']}',
          (sent, total) {
            if (total <= 0) return;
            final pct = ((sent / total) * 100).round().clamp(0, 100);
            _heartbeat(file, job, pct);
            _showProgress(id, '${job['file_name']}', pct);
          },
        );
        final url = uploadedMedia['url'] ?? '';
        await dio.post(
          '/chat/${job['link_id']}/messages',
          data: {
            'kind': '${job['kind']}',
            if ('${job['side']}'.isNotEmpty) 'side': '${job['side']}',
            'media_path': url,
            'media': [
              {
                'url': url,
                'thumbnail': uploadedMedia['thumbnail'] ?? '',
                'kind': '${job['kind']}',
                'file_name': '${job['file_name']}',
              },
            ],
            if ('${job['kind']}' == 'file') 'file_name': '${job['file_name']}',
            if (_text(job) != null) 'text': _text(job),
            if ('${job['reply_to_id'] ?? ''}'.isNotEmpty)
              'reply_to_id': '${job['reply_to_id']}',
            if (job['duration_ms'] != null) 'duration_ms': job['duration_ms'],
            'client_id': id,
            'client_message_id': id,
          },
        );
      }
      await _cleanupFile(file, job);
      await _showDone(id);
      return true;
    } catch (error) {
      final attempts = (job['attempts'] as num?)?.toInt() ?? 0;
      job['attempts'] = attempts + 1;
      try {
        await file.writeAsString(jsonEncode(job), flush: true);
      } catch (_) {}
      final transient =
          error is DioException &&
          !CancelToken.isCancel(error) &&
          (error.response == null ||
              error.response!.statusCode == 429 ||
              (error.response!.statusCode ?? 0) >= 500);
      if (attempts >= 2 || !transient) {
        job['failed'] = true;
        await file.writeAsString(jsonEncode(job), flush: true);
        await _showFailed(id);
        return true;
      }
      return false;
    }
  }

  static Future<void> _cleanupFile(File file, Map job) async {
    try {
      for (final m in (job['media'] as List? ?? const [])) {
        if (m is Map && m['path'] != null) {
          final p = File('${m['path']}');
          if (await p.exists()) await p.delete();
        }
      }
      if (job['path'] != null) {
        final p = File('${job['path']}');
        if (await p.exists()) await p.delete();
      }
      final live = File(file.path.replaceFirst(RegExp(r'\.json$'), '.live'));
      if (await live.exists()) await live.delete();
      final done = File(file.path.replaceFirst(RegExp(r'\.json$'), '.done'));
      if (await done.exists()) await done.delete();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static String? _text(Map job) {
    final t = '${job['caption'] ?? ''}'.trim();
    return t.isEmpty ? null : t;
  }

  static Future<Map<String, String>> _upload(
    Dio dio,
    Map job,
    String id,
    String path,
    String name,
    void Function(int, int) onProgress,
  ) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        path,
        filename: name,
        contentType: MediaType.parse(mimeFor(name)),
      ),
    });
    final r = await dio.post(
      '/chat/${job['link_id']}/media',
      data: form,
      onSendProgress: onProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 60),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    final data = r.data is Map && r.data['data'] is Map
        ? r.data['data']
        : r.data;
    return {
      'url': '${data is Map ? data['url'] ?? '' : ''}',
      'thumbnail': '${data is Map ? data['thumbnail'] ?? '' : ''}',
    };
  }

  static String mimeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'm4v':
        return 'video/x-m4v';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case '3gp':
        return 'video/3gpp';
      case 'avi':
        return 'video/x-msvideo';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'csv':
        return 'text/csv';
      case 'txt':
        return 'text/plain';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      default:
        return 'application/octet-stream';
    }
  }

  static void _heartbeat(File file, Map job, int pct) {
    job['pct'] = pct;
    file.writeAsString(jsonEncode(job)).catchError((_) => file);
  }

  static Future<void> _readyNotifications() async {
    if (_notificationsReady) return;
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_launcher'),
      ),
    );
    _notifications = plugin;
    _notificationsReady = true;
  }

  static Future<void> _showProgress(String id, String name, int pct) async {
    try {
      await _readyNotifications();
      await _notifications?.show(
        id: id.hashCode & 0x7fffffff,
        title: 'رفع الوسائط',
        body: '$name • $pct%',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'chat_upload_progress',
            'Chat uploads',
            channelDescription: 'Background media upload progress',
            importance: Importance.low,
            priority: Priority.low,
            showProgress: true,
            maxProgress: 100,
            progress: pct,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            icon: 'ic_launcher',
          ),
        ),
      );
    } catch (_) {}
  }

  static Future<void> _notificationsCancel(int id) async {
    try {
      await _readyNotifications();
      await _notifications?.cancel(id: id);
    } catch (_) {}
  }

  static Future<void> _showDone(String id) async {
    try {
      await _notificationsCancel(id.hashCode & 0x7fffffff);
      await _readyNotifications();
      await _notifications?.show(
        id: id.hashCode & 0x7fffffff,
        title: 'FYONA',
        body: 'تم رفع الوسائط وإرسالها',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'chat_upload_progress',
            'Chat uploads',
            importance: Importance.low,
            priority: Priority.low,
            onlyAlertOnce: true,
            icon: 'ic_launcher',
          ),
        ),
      );
    } catch (_) {}
  }

  static Future<void> _showFailed(String id) async {
    try {
      await _notificationsCancel(id.hashCode & 0x7fffffff);
    } catch (_) {}
  }
}
