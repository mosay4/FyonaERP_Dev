import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../shared/services/notification_service.dart';
import '../../../core/localization/app_localizations.dart';

import 'merchant_api.dart';
import 'chat_background_upload.dart';
import 'chat_timeline.dart';

/// Global background uploader for chat media. Uploads/sends continue even when
/// the chat page is closed; the pending bubbles live here (per relationship)
/// and the page renders them whenever it is open.
class ChatUploadManager {
  ChatUploadManager({
    bool persist = true,
    Future<void> Function(Duration)? wait,
  }) : _persist = persist,
       _wait = wait ?? Future<void>.delayed;
  static final ChatUploadManager instance = ChatUploadManager();
  final bool _persist;
  final Future<void> Function(Duration) _wait;
  static const maxPending = 50;
  static const maxConcurrent = 3;
  final Map<String, _UploadJob> _jobs = {};
  final List<String> _waiting = [];
  int _running = 0;
  Timer? _lease;

  final Map<String, List<Map<String, dynamic>>> _pending = {};
  final Map<String, ValueNotifier<int>> _tick = {};
  final Map<String, String> _errors = {};
  final Map<String, CancelToken> _tokens = {};
  final _rnd = Random();
  final _accepted =
      StreamController<
        ({String linkId, String side, Map<String, dynamic> result})
      >.broadcast();
  Stream<({String linkId, String side, Map<String, dynamic> result})>
  get accepted => _accepted.stream;

  ValueNotifier<int> tick(String linkId) =>
      _tick.putIfAbsent(linkId, () => ValueNotifier<int>(0));

  List<Map<String, dynamic>> pending(String linkId) =>
      _pending[linkId] ?? const [];

  String? takeError(String linkId) => _errors.remove(linkId);

  int _notificationId(String id) => id.hashCode & 0x7fffffff;

  Future<void> _progressNotification(
    String id,
    String name,
    int pct, {
    bool cancel = false,
  }) async {
    final plugin = NotificationService.sharedPlugin;
    if (plugin == null) return;
    final notifId = _notificationId(id);
    try {
      if (cancel) {
        await plugin.cancel(id: notifId);
        return;
      }
      await plugin.show(
        id: notifId,
        title: AppLocalizations.t('chatUploadingMedia'),
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
            progress: pct.clamp(0, 100),
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            icon: 'ic_launcher',
          ),
        ),
      );
    } catch (_) {}
  }

  /// User-initiated cancellation before the server receives the message.
  void cancel(String linkId, String id) {
    final job = _jobs.remove(id);
    _waiting.remove(id);
    if (job != null) job.cancelled = true;
    _tokens.remove(id)?.cancel('cancelled by user');
    _remove(linkId, id);
    _progressNotification(id, '', 0, cancel: true);
    if (_persist) unawaited(ChatBackgroundUpload.remove(id));
  }

  /// Polling may observe acceptance before the send response (or worker).
  bool acknowledge(String linkId, String side, Map<String, dynamic> message) {
    final id = ChatTimeline.clientId(message);
    final job = _jobs[id];
    if (job == null || job.linkId != linkId || job.side != side) return false;
    _jobs.remove(id);
    _waiting.remove(id);
    job.cancelled = true;
    _tokens.remove(id)?.cancel('already accepted');
    _remove(linkId, '$id');
    if (_persist) unawaited(ChatBackgroundUpload.remove('$id'));
    _accepted.add((linkId: linkId, side: side, result: {'message': message}));
    return true;
  }

  void retry(String linkId, String id) {
    final job = _jobs[id];
    if (job == null ||
        job.linkId != linkId ||
        job.item['failed'] != true ||
        job.item['busy'] == true)
      return;
    job.item['failed'] = false;
    job.item['busy'] = true;
    _waiting.add(id);
    _notify(linkId);
    _drain();
  }

  bool _canEnqueue(String linkId, int bytes) {
    final retained = _jobs.values.fold<int>(0, (sum, job) => sum + job.bytes);
    if (_jobs.length < maxPending && retained + bytes <= 32 * 1024 * 1024)
      return true;
    _errors[linkId] = 'قائمة الإرسال ممتلئة — أعد المحاولة بعد اكتمال الرسائل';
    _notify(linkId);
    return false;
  }

  void _schedule(String id, _UploadJob job) {
    _jobs[id] = job;
    job.item['busy'] = true;
    job.item['failed'] = false;
    _add(job.linkId, job.item);
    _waiting.add(id);
    _drain();
  }

  void _drain() {
    if (_persist &&
        _lease == null &&
        _jobs.values.any((job) => job.item['busy'] == true)) {
      _lease = Timer.periodic(const Duration(seconds: 5), (_) {
        for (final entry in _jobs.entries) {
          if (entry.value.item['busy'] == true)
            unawaited(ChatBackgroundUpload.touch(entry.key));
        }
        if (!_jobs.values.any((job) => job.item['busy'] == true)) {
          _lease?.cancel();
          _lease = null;
        }
      });
    }
    while (_running < maxConcurrent && _waiting.isNotEmpty) {
      final id = _waiting.removeAt(0);
      final job = _jobs[id];
      if (job == null) continue;
      _running++;
      unawaited(_run(id, job));
    }
  }

  Future<void> _run(String id, _UploadJob job) async {
    final token = CancelToken();
    _tokens[id] = token;
    try {
      if (_persist) {
        await job.persisted;
        if (job.cancelled) return;
        await ChatBackgroundUpload.setFailed(id, false);
        await ChatBackgroundUpload.touch(id);
      }
      for (var attempt = 0; attempt < 3 && !job.cancelled; attempt++) {
        try {
          final result = await job.operation(token);
          if (job.cancelled) return;
          final raw = result['message'];
          if (raw is! Map || raw['id'] == null)
            throw StateError('Missing accepted message');
          acknowledge(job.linkId, job.side, {
            ...Map<String, dynamic>.from(raw),
            'client_id': id,
            'client_message_id': id,
          });
          return;
        } catch (error) {
          if (job.cancelled) return;
          final transient =
              error is DioException &&
              !CancelToken.isCancel(error) &&
              (error.response == null ||
                  error.response!.statusCode == 429 ||
                  (error.response!.statusCode ?? 0) >= 500);
          if (!transient || attempt == 2) break;
          await _wait(Duration(milliseconds: 500 * (1 << attempt)));
        }
      }
      if (!job.cancelled) {
        job.item['failed'] = true;
        job.item['busy'] = false;
        if (_persist) await ChatBackgroundUpload.setFailed(id, true);
        _notify(job.linkId);
      }
    } finally {
      if (identical(_tokens[id], token)) _tokens.remove(id);
      unawaited(_progressNotification(id, '', 0, cancel: true));
      _running--;
      _drain();
    }
  }

  void _notify(String linkId) {
    tick(linkId).value++;
  }

  void _add(String linkId, Map<String, dynamic> item) {
    (_pending[linkId] ??= []).insert(0, item);
    _notify(linkId);
  }

  void _remove(String linkId, String id) {
    _pending[linkId]?.removeWhere((p) => p['id'] == id);
    _notify(linkId);
  }

  String _newId() =>
      'up-${DateTime.now().microsecondsSinceEpoch}-${_rnd.nextInt(99999)}';

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

  void enqueueSingle({
    required MerchantApi api,
    required String linkId,
    required String side,
    required String kind,
    Uint8List? bytes,
    String? path,
    required String fileName,
    String? caption,
    String? replyToId,
    int? durationMs,
  }) {
    if (!_canEnqueue(linkId, bytes?.length ?? 0)) return;
    final id = _newId();
    final item = <String, dynamic>{
      'id': id,
      'kind': kind,
      'bytes': bytes,
      'name': fileName,
      'caption': caption,
      'progress': 0.0,
      'compressing': false,
    };
    _progressNotification(id, fileName, 0);
    final tokenHeader = api.client.dio.options.headers['Authorization'];
    final persisted = _persist
        ? ChatBackgroundUpload.enqueueSingle(
            linkId: linkId,
            side: side,
            kind: kind,
            id: id,
            bytes: bytes,
            path: path,
            fileName: fileName,
            caption: caption,
            replyToId: replyToId,
            durationMs: durationMs,
            baseUrl: api.client.dio.options.baseUrl,
            token: tokenHeader is String ? tokenHeader : null,
          )
        : Future<void>.value();
    _schedule(
      id,
      _UploadJob(
        linkId,
        side,
        item,
        bytes?.length ?? 0,
        persisted,
        (token) => _runSingle(
          api,
          linkId,
          side,
          id,
          item,
          bytes,
          path,
          fileName,
          caption,
          replyToId,
          durationMs,
          token,
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> _runSingle(
    MerchantApi api,
    String linkId,
    String side,
    String id,
    Map<String, dynamic> item,
    Uint8List? bytes,
    String? path,
    String fileName,
    String? caption,
    String? replyToId,
    int? durationMs,
    CancelToken? cancelToken,
  ) async {
    final media =
        item['_uploaded'] as Map<String, String>? ??
        await api.uploadChatMedia(
          linkId,
          bytes ?? const [],
          fileName,
          mimeFor(fileName),
          path: path,
          cancelToken: cancelToken,
          onProgress: (sent, total) {
            if (total <= 0) return;
            final pct = ((sent / total) * 100).round();
            if (item['pct'] == pct) return;
            item['pct'] = pct;
            item['progress'] = (sent / total).clamp(0.0, 1.0);
            _notify(linkId);
            _progressNotification(id, fileName, pct);
            if (_persist) unawaited(ChatBackgroundUpload.touch(id));
          },
        );
    item['_uploaded'] = media;
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final url = media['url'] ?? '';
    return api.sendChat(
      linkId,
      kind: '${item['kind']}',
      side: side,
      mediaPath: url,
      fileName: item['kind'] == 'file' ? fileName : null,
      media: [
        {
          'url': url,
          'thumbnail': media['thumbnail'] ?? '',
          'kind': '${item['kind']}',
          'file_name': fileName,
        },
      ],
      text: (caption ?? '').trim().isEmpty ? null : caption!.trim(),
      replyToId: replyToId,
      durationMs: durationMs,
      clientId: id,
    );
  }

  void enqueueAlbum({
    required MerchantApi api,
    required String linkId,
    required String side,
    required List<Map<String, dynamic>> items,
    String? caption,
    String? replyToId,
    int? durationMs,
  }) {
    final retained = items.fold<int>(
      0,
      (sum, item) => sum + ((item['bytes'] as Uint8List?)?.length ?? 0),
    );
    if (!_canEnqueue(linkId, retained)) return;
    final id = _newId();
    final item = <String, dynamic>{
      'id': id,
      'kind': 'album',
      'media': items,
      'caption': caption,
      'progress': 0.0,
      'compressing': false,
    };
    _progressNotification(id, '${items.length} files', 0);
    final tokenHeader = api.client.dio.options.headers['Authorization'];
    final persisted = _persist
        ? ChatBackgroundUpload.enqueueAlbum(
            linkId: linkId,
            side: side,
            id: id,
            items: items,
            caption: caption,
            replyToId: replyToId,
            baseUrl: api.client.dio.options.baseUrl,
            token: tokenHeader is String ? tokenHeader : null,
          )
        : Future<void>.value();
    _schedule(
      id,
      _UploadJob(
        linkId,
        side,
        item,
        retained,
        persisted,
        (token) => _runAlbum(
          api,
          linkId,
          side,
          id,
          item,
          items,
          caption,
          replyToId,
          token,
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> _runAlbum(
    MerchantApi api,
    String linkId,
    String side,
    String id,
    Map<String, dynamic> item,
    List<Map<String, dynamic>> items,
    String? caption,
    String? replyToId,
    CancelToken? cancelToken,
  ) async {
    final uploaded =
        item.putIfAbsent('_uploaded', () => <Map<String, dynamic>>[])
            as List<Map<String, dynamic>>;
    for (var i = uploaded.length; i < items.length; i++) {
      final it = items[i];
      final p = '${it['path'] ?? ''}'.isEmpty ? null : '${it['path']}';
      final uploadedMedia = await api.uploadChatMedia(
        linkId,
        (it['bytes'] as Uint8List?) ?? const [],
        '${it['name']}',
        mimeFor('${it['name']}'),
        path: p,
        cancelToken: cancelToken,
        onProgress: (sent, total) {
          if (total <= 0) return;
          final pct = (((i + sent / total) / items.length) * 100).round();
          if (item['pct'] == pct) return;
          item['pct'] = pct;
          item['progress'] = ((i + sent / total) / items.length).clamp(
            0.0,
            1.0,
          );
          _notify(linkId);
          _progressNotification(id, '${items.length} files', pct);
          if (_persist) unawaited(ChatBackgroundUpload.touch(id));
        },
      );
      uploaded.add({
        'url': uploadedMedia['url'] ?? '',
        'thumbnail': uploadedMedia['thumbnail'] ?? '',
        'kind': it['kind'],
        'file_name': it['name'],
      });
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    return api.sendChat(
      linkId,
      kind: 'album',
      side: side,
      media: uploaded,
      text: (caption ?? '').trim().isEmpty ? null : caption!.trim(),
      replyToId: replyToId,
      clientId: id,
    );
  }
}

class _UploadJob {
  _UploadJob(
    this.linkId,
    this.side,
    this.item,
    this.bytes,
    this.persisted,
    this.operation,
  );
  final String linkId;
  final String side;
  final Map<String, dynamic> item;
  final int bytes;
  final Future<void> persisted;
  final Future<Map<String, dynamic>> Function(CancelToken) operation;
  bool cancelled = false;
}
