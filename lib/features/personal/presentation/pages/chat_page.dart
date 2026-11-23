import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/secure_image.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/presentation/widgets/debt_widgets.dart';
import '../../data/merchant_api.dart';
import '../providers/merchant_unread_provider.dart';
import '../../data/chat_upload_manager.dart';
import '../../data/chat_timeline.dart';
import '../../data/chat_sounds.dart';
import '../../data/active_chat.dart';
import '../widgets/chat_style.dart';
import '../widgets/chat_video_surface.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Isolated chat between a merchant and one LINKED customer/supplier.
/// Direction is SIDE-based (merchant/personal), so the same account can be
/// both sides. Supports text/image/video/voice/invoice, captions, edit/delete
/// (30 min, server-enforced), receipts, presence and near-instant polling.
class ChatPage extends ConsumerStatefulWidget {
  final String linkId;
  final bool isMerchant;
  final String? focusMessageId;
  final ChatUploadManager? uploadManager;
  final ChatSounds? sounds;
  const ChatPage({
    super.key,
    required this.linkId,
    required this.isMerchant,
    this.focusMessageId,
    this.uploadManager,
    this.sounds,
  });
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _picker = ImagePicker();

  Map<String, dynamic> _info = const {};
  final _timeline = ChatTimeline();
  List<Map<String, dynamic>> get _messages => _timeline.messages;
  late final ChatSounds _sounds;
  final List<Map<String, dynamic>> _outbox = [];
  StreamSubscription? _acceptedSub;
  late MerchantApi _api;
  Timer? _heartbeat;
  Future<void> _presenceQueue = Future.value();
  bool _closed = false;
  bool _foreground = true;
  bool _routeVisible = true;
  ProviderContainer? _presenceContainer;
  bool _loadBusy = false;
  bool _olderBusy = false;
  bool _hasOlder = true;
  bool _historyWindow = false;
  bool _catchingUp = false;
  String? _after;
  DateTime? _lastRefresh;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  Timer? _poll;
  CancelToken? _liveCancel;
  bool _auxBusy = false;
  bool _needsRead = false;
  String? _highlightId;
  bool _atBottom = true;

  // Voice recording
  bool _recording = false;
  bool _paused = false;
  final Map<String, GlobalKey> _messageKeys = {};
  final List<double> _amps = [];
  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription<void>? _playerSub;
  Map? _replyTo;
  bool _saving = false;
  String? _playingId;
  final Map<String, String> _voiceCache = {};
  DateTime? _seekGrace;
  double? _seekTarget;
  bool _voicePaused = false;
  double _voicePos = 0;
  double _voiceDur = 0;
  double _voiceSpeed = 1.0;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  DateTime? _recStart;
  DateTime? _pausedAt;
  Duration _pausedTotal = Duration.zero;
  String? _recordPath;
  Timer? _recordTick;

  String get _side => widget.isMerchant ? 'merchant' : 'personal';
  ChatUploadManager get _uploads =>
      widget.uploadManager ?? ChatUploadManager.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ref.read(merchantApiProvider);
    _sounds = widget.sounds ?? ChatSounds();
    _acceptedSub = _uploads.accepted.listen((event) {
      if (mounted && event.linkId == widget.linkId && event.side == _side) {
        _accept(event.result);
      }
    });
    unawaited(_presence(true));
    _heartbeat = Timer.periodic(const Duration(seconds: 12), (_) {
      unawaited(_presence(_visible));
    });
    _highlightId = widget.focusMessageId;
    _catchingUp = widget.focusMessageId != null;
    _scroll.addListener(() {
      _atBottom = _scroll.offset <= 40;
      if (_scroll.position.extentAfter < 240) unawaited(_loadOlder());
    });
    _playerSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingId = null;
          _voicePaused = false;
          _voicePos = 0;
        });
      }
    });
    _posSub = _player.onPositionChanged.listen((p) {
      final s = p.inMilliseconds / 1000.0;
      if (!mounted) return;
      final grace = _seekGrace;
      if (grace != null) {
        if (DateTime.now().isBefore(grace)) return;
        _seekGrace = null;
      }
      if ((s - _voicePos).abs() >= 0.1) {
        setState(() => _voicePos = s);
      }
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) {
        setState(() => _voiceDur = d.inMilliseconds / 1000.0);
      }
    });
    _uploads.tick(widget.linkId).addListener(_onUploadTick);
    _bootstrap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _presenceContainer = ProviderScope.containerOf(context, listen: false);
      _setLocalChat(_visible);
    });
  }

  void _onUploadTick() {
    if (!mounted) return;
    for (final pending in _uploads.pending(widget.linkId)) {
      _sentSound('${pending['id']}');
    }
    final err = _uploads.takeError(widget.linkId);
    if (err != null) _snack(err);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _closed = true;
    if (mounted && _presenceContainer != null) _updateLocalChat(false);
    _presenceContainer = null;
    _acceptedSub?.cancel();
    unawaited(_presence(false));
    _sounds.dispose();
    _poll?.cancel();
    _liveCancel?.cancel();
    _recordTick?.cancel();
    _ampSub?.cancel();
    _playerSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _uploads.tick(widget.linkId).removeListener(_onUploadTick);
    _text.dispose();
    _scroll.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _load(initial: true);
    _poll?.cancel();
    if (!mounted) return;
    unawaited(_pollLive());
  }

  Future<void> _pollLive() async {
    if (!mounted || _closed) return;
    if (_visible && !_historyWindow) await _load(waitForChanges: true);
    if (!mounted || _closed) return;
    _poll = Timer(
      Duration(milliseconds: _api.realtimeAvailable ? 250 : 1500),
      () => unawaited(_pollLive()),
    );
  }

  bool get _visible =>
      mounted && _foreground && (ModalRoute.of(context)?.isCurrent ?? true);

  Future<void> _presence(bool active) {
    if (!active) _liveCancel?.cancel();
    _setLocalChat(active);
    // Preserve open/leave ordering even on a slow network. Never let a queued
    // active beat resurrect a conversation after background/disposal.
    return _presenceQueue = _presenceQueue.then((_) async {
      if (active && (_closed || !_visible)) return;
      try {
        await _api.chatPresence(widget.linkId, active: active, side: _side);
      } catch (_) {}
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    unawaited(_presence(_visible));
    if (_visible) unawaited(_load());
  }

  void _setLocalChat(bool active) {
    if (!mounted) return;
    if (_presenceContainer == null) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _setLocalChat(active);
      });
      return;
    }
    _updateLocalChat(active);
  }

  void _updateLocalChat(bool active) {
    if (!mounted) return;
    final container = _presenceContainer;
    if (container == null) return;
    try {
      final old = container.read(activeChatViewProvider);
      if (active) {
        if (old?.linkId == widget.linkId && old?.side == _side) return;
        container.read(activeChatViewProvider.notifier).state = ActiveChatView(
          widget.linkId,
          _side,
        );
      } else if (old?.linkId == widget.linkId && old?.side == _side) {
        container.read(activeChatViewProvider.notifier).state = null;
      }
    } catch (_) {}
  }

  void _scrollToMessage(String id) {
    if (id.isEmpty) return;
    final ctx = _messageKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOut,
      );
    } else {
      final idx = _messages.indexWhere((m) => '${m['id']}' == id);
      if (idx >= 0 && _scroll.hasClients) {
        final reversed = _messages.length - 1 - idx;
        final target = (reversed * 90.0).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        );
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 650),
          curve: Curves.easeInOut,
        );
      }
    }
    setState(() => _highlightId = id);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _highlightId == id) {
        setState(() => _highlightId = null);
      }
    });
  }

  Future<void> _load({
    bool initial = false,
    bool waitForChanges = false,
  }) async {
    if (_loadBusy || _olderBusy || !mounted) return;
    _loadBusy = true;
    try {
      final api = _api;
      final refresh =
          initial ||
          _lastRefresh == null ||
          DateTime.now().difference(_lastRefresh!).inSeconds >= 12;
      final info = refresh && !waitForChanges
          ? await api.chatInfo(widget.linkId, side: _side)
          : _info;
      if (waitForChanges) _liveCancel = CancelToken();
      final msgs = await api.chatMessages(
        widget.linkId,
        side: _side,
        after: initial ? null : _after,
        around: initial ? widget.focusMessageId : null,
        limit: ChatTimeline.pageSize,
        waitForChanges: waitForChanges,
        cancelToken: waitForChanges ? _liveCancel : null,
      );
      if (!mounted) return;
      if (msgs.isNotEmpty) _after = '${msgs.last['id']}';
      var changed = _mergeMessages(msgs, live: !initial && !_catchingUp);
      // Render immediately. Receipt/presence/metadata requests must not delay
      // displaying the message on a slow connection.
      if (changed || _loading || _error != null)
        setState(() {
          _loading = false;
          _error = null;
          _info = info;
        });
      if (!initial && msgs.length < ChatTimeline.pageSize) _catchingUp = false;
      if (initial) _hasOlder = msgs.length == ChatTimeline.pageSize;
      // Refresh recent receipts/edits/deletes without replaying sounds. Never
      // refresh ahead of the forward cursor during a large incoming burst.
      if (refresh ||
          msgs.any(
            (m) =>
                m['mine'] != true && m['read'] != true && m['deleted'] != true,
          )) {
        _needsRead =
            _needsRead ||
            msgs.any((m) => m['mine'] != true && m['read'] != true);
        unawaited(_refreshAuxiliary(refresh: refresh));
      }
      if (refresh) _lastRefresh = DateTime.now();
      final hasIncoming = msgs.any(
        (m) => m['mine'] != true && m['read'] != true && m['deleted'] != true,
      );
      if (!mounted) return;
      if (changed || !mapEquals(_info, info) || _loading || _error != null)
        setState(() {
          _info = info;
          _loading = false;
          _error = null;
        });
      _pruneCaches();
      if ((initial || (changed && _atBottom)) && _scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.animateTo(
              0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (initial) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    } finally {
      _loadBusy = false;
    }
  }

  Future<void> _refreshAuxiliary({required bool refresh}) async {
    if (_auxBusy || !mounted) return;
    _auxBusy = true;
    try {
      if (_needsRead) {
        _needsRead = false;
        try {
          await _api.markChatRead(widget.linkId);
          if (mounted) {
            ref.invalidate(chatUnreadProvider(_side));
            ref.invalidate(debtUnreadProvider(_side));
          }
        } catch (_) {}
      }
      if (refresh && mounted) {
        final info = await _api.chatInfo(widget.linkId, side: _side);
        final recent = await _api.chatMessages(widget.linkId, side: _side);
        if (!mounted) return;
        final changed = _mergeMessages(recent);
        if (changed || !mapEquals(_info, info)) setState(() => _info = info);
      }
    } catch (_) {
    } finally {
      _auxBusy = false;
    }
  }

  void _pruneCaches() {
    final ids = _messages.map((m) => '${m['id']}').toSet();
    _messageKeys.removeWhere((id, _) => !ids.contains(id));
    _voiceCache.removeWhere((id, _) => !ids.contains(id));
  }

  Future<void> _loadOlder() async {
    if (_olderBusy || _loadBusy || !_hasOlder || _messages.isEmpty) return;
    _olderBusy = true;
    try {
      final page = await _api.chatMessages(
        widget.linkId,
        side: _side,
        before: '${_messages.first['id']}',
        limit: ChatTimeline.pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (_messages.length + page.length > ChatTimeline.capacity)
          _historyWindow = true;
        _mergeMessages(page, older: true);
        _hasOlder = page.length == ChatTimeline.pageSize;
      });
      _pruneCaches();
    } catch (_) {
      if (mounted)
        _snack(AppLocalizations.of(context).translate('chatSendFailed'));
    } finally {
      _olderBusy = false;
    }
  }

  bool _mergeMessages(
    List<Map<String, dynamic>> page, {
    bool live = false,
    bool older = false,
  }) {
    // Every ingress (response, forward poll, refresh, history) reconciles the
    // optimistic row synchronously, before a frame can show the server row.
    var changed = _timeline.merge(page, live: live, older: older);
    // Use the canonical rows: a refresh can omit the client key that was
    // already learned from an acknowledgement with the same server id.
    for (final message in _messages) {
      final clientId = ChatTimeline.clientId(message);
      if (message['mine'] != true || clientId == null) continue;
      final previousLength = _outbox.length;
      _outbox.removeWhere((m) => m['client_id'] == clientId);
      changed = previousLength != _outbox.length || changed;
      changed = _uploads.acknowledge(widget.linkId, _side, message) || changed;
    }
    return changed;
  }

  void _sentSound(String id) {
    if (_timeline.accepted(id) && _visible) _sounds.play(sent: true);
  }

  void _accept(Map<String, dynamic> result) {
    final raw = result['message'];
    if (!mounted || raw is! Map) return;
    final message = Map<String, dynamic>.from(raw);
    if (message['kind'] == 'invoice' && message['invoice_number'] == null) {
      for (final pending in _outbox) {
        if (pending['client_id'] == ChatTimeline.clientId(message)) {
          message['invoice_number'] = pending['invoice_number'];
          break;
        }
      }
    }
    setState(() {
      _mergeMessages([message]);
    });
    _sentSound('${ChatTimeline.clientId(message) ?? message['id']}');
  }

  void _snack(String msg, {bool ok = false}) {
    if (mounted) showFyonaSnack(context, msg, success: ok);
  }

  Future<void> _sendText() async {
    final t = _text.text.trim();
    if (t.isEmpty || _outbox.length >= 50) return;
    final message = <String, dynamic>{
      'kind': 'text',
      'client_id': const Uuid().v4(),
      'text': t,
      'reply_to_id': _replyTo?['id'],
      'failed': false,
      'busy': false,
    };
    _text.clear();
    setState(() {
      _replyTo = null;
      _outbox.add(message);
    });
    unawaited(_sendPending(message));
  }

  Future<void> _sendPending(Map<String, dynamic> message) async {
    if (message['busy'] == true || !_outbox.contains(message)) return;
    _sentSound('${message['client_id']}');
    setState(() {
      message['busy'] = true;
      message['failed'] = false;
    });
    for (var attempt = 0; attempt < 3 && mounted; attempt++) {
      if (!_outbox.contains(message)) return;
      try {
        final result = await _api.sendChat(
          widget.linkId,
          kind: '${message['kind'] ?? 'text'}',
          side: _side,
          text: message['text'],
          replyToId: message['reply_to_id'],
          invoiceId: message['invoice_id'],
          clientId: message['client_id'],
        );
        if (result['message'] is! Map || result['message']['id'] == null) {
          throw StateError('Missing accepted message');
        }
        _accept({
          ...result,
          'message': {
            ...Map<String, dynamic>.from(result['message']),
            'client_id': message['client_id'],
            'client_message_id': message['client_id'],
          },
        });
        return;
      } catch (error) {
        final retry =
            error is DioException &&
            !CancelToken.isCancel(error) &&
            (error.response == null ||
                error.response!.statusCode == 429 ||
                (error.response!.statusCode ?? 0) >= 500);
        if (!retry || attempt == 2) break;
        await Future<void>.delayed(
          Duration(milliseconds: 500 * (1 << attempt)),
        );
      }
    }
    if (mounted)
      setState(() {
        message['busy'] = false;
        message['failed'] = true;
      });
  }

  String _mediaUrl(String url) {
    final u = url.trim();
    if (u.isEmpty || u.startsWith('http')) return u;
    final p = u.startsWith('uploads/') ? '/$u' : u;
    if (p.startsWith('/uploads/')) return '${AppConfig.apiHostUrl}$p';
    return p;
  }

  String _mimeFor(String name) {
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
      case '3gp':
        return 'video/3gpp';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'm4v':
        return 'video/x-m4v';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
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

  bool _isVideo(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return const {
      'mp4',
      'mov',
      'm4v',
      'webm',
      'mkv',
      'avi',
      '3gp',
    }.contains(ext);
  }

  /// Shows the media in the chat IMMEDIATELY (as a pending bubble) and uploads
  /// it with a live percentage; once 100% it is sent to the other side.
  Future<void> _uploadAndSend({
    required String kind,
    Uint8List? bytes,
    String? path,
    required String fileName,
    String? caption,
    int? durationMs,
  }) async {
    _uploads.enqueueSingle(
      api: ref.read(merchantApiProvider),
      linkId: widget.linkId,
      side: _side,
      kind: kind,
      bytes: bytes,
      path: path,
      fileName: fileName,
      caption: caption,
      replyToId: _replyTo?['id'],
      durationMs: durationMs,
    );
    if (mounted) setState(() => _replyTo = null);
  }

  Future<void> _pickCameraImage() async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 82,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final caption = await _showMediaPreview(bytes, video: false);
      if (caption == null) return;
      await _uploadAndSend(
        kind: 'image',
        bytes: bytes,
        fileName: x.name,
        caption: caption,
      );
    } catch (_) {
      _snack(AppLocalizations.of(context).translate('chatSendFailed'));
    }
  }

  /// Gallery: native photo/video picker; supports MULTIPLE selection.
  /// Android's system Photo Picker is enabled in main() (ImageAndVideo).
  Future<void> _pickGallery() async {
    try {
      final files = await _picker.pickMultipleMedia(
        imageQuality: 80,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (!mounted) return;
      // Some external picker activities can outlive the page stack. If the
      // shell fell back to the debts list, restore THIS chat before showing
      // the preview/upload so the merchant never loses the conversation.
      final chatPath = widget.isMerchant ? '/debts/chat' : '/personal/chat';
      if (GoRouterState.of(context).uri.path != chatPath) {
        context.go(
          Uri(
            path: chatPath,
            queryParameters: {'link': widget.linkId},
          ).toString(),
        );
        return;
      }
      if (files.isEmpty) return;
      if (files.length == 1) {
        final x = files.first;
        final video =
            _isVideo(x.name) || (x.mimeType?.startsWith('video/') ?? false);
        final bytes = video ? null : await x.readAsBytes();
        final caption = await _showMediaPreview(
          bytes ?? Uint8List(0),
          video: video,
          videoPath: video ? x.path : null,
        );
        if (caption == null) return;
        await _uploadAndSend(
          kind: video ? 'video' : 'image',
          bytes: bytes,
          path: x.path,
          fileName: x.name,
          caption: caption,
        );
        return;
      }
      await _pickAlbum(files);
    } catch (_) {
      _snack(AppLocalizations.of(context).translate('chatSendFailed'));
    }
  }

  Future<void> _pickAlbum(List<XFile> files) async {
    final items = <Map<String, dynamic>>[];
    for (final f in files.take(10)) {
      final video =
          _isVideo(f.name) || (f.mimeType?.startsWith('video/') ?? false);
      final bytes = video ? null : await f.readAsBytes();
      items.add({
        'path': f.path,
        'bytes': bytes,
        'name': f.name,
        'kind': video ? 'video' : 'image',
      });
    }
    final res = await _showAlbumPreview(items);
    if (res == null) return;
    final remaining = (res['items'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (remaining.isEmpty) return;
    await _uploadAlbum(remaining, '${res['caption'] ?? ''}');
  }

  Future<Map?> _showAlbumPreview(List<Map<String, dynamic>> items) async {
    final ctrl = TextEditingController();
    final list = List<Map<String, dynamic>>.from(items);
    final res = await showDialog<Map>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return AlertDialog(
            title: Text(
              AppLocalizations.of(ctx).translate('chatAlbumPreview'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    children: [
                      for (var i = 0; i < list.length; i++)
                        Stack(
                          children: [
                            Positioned.fill(
                              child: GestureDetector(
                                onTap: () => _showLocalPreview(list[i]),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: list[i]['kind'] == 'video'
                                      ? Container(
                                          color: Colors.black26,
                                          child: const Icon(
                                            Icons.play_circle_fill,
                                            color: Colors.white,
                                            size: 32,
                                          ),
                                        )
                                      : (list[i]['bytes'] != null
                                            ? Image.memory(
                                                list[i]['bytes'] as Uint8List,
                                                fit: BoxFit.cover,
                                              )
                                            : Container(color: Colors.black12)),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: () => setSt(() => list.removeAt(i)),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FyonaTextField(
                    controller: ctrl,
                    maxLines: 2,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: AppLocalizations.of(
                        ctx,
                      ).translate('chatMediaCaption'),
                      hintStyle: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  AppLocalizations.of(ctx).translate('chatCancel'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: DebtStyle.red),
                onPressed: list.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, {
                        'caption': ctrl.text,
                        'items': list,
                      }),
                child: Text(
                  AppLocalizations.of(ctx).translate('chatSendMedia'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
              ),
            ],
          );
        },
      ),
    );
    ctrl.dispose();
    return res;
  }

  void _showLocalPreview(Map item) {
    if (item['kind'] == 'video') {
      final path = '${item['path'] ?? ''}';
      if (path.isEmpty) return;
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => _MediaViewerPage(videoFile: path)),
      );
      return;
    }
    final bytes = item['bytes'] as Uint8List?;
    if (bytes == null) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(8),
        child: Stack(
          children: [
            SizedBox(
              width: double.infinity,
              height: MediaQuery.sizeOf(ctx).height * 0.8,
              child: InteractiveViewer(
                child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadAlbum(
    List<Map<String, dynamic>> items,
    String caption,
  ) async {
    _uploads.enqueueAlbum(
      api: ref.read(merchantApiProvider),
      linkId: widget.linkId,
      side: _side,
      items: items,
      caption: caption,
      replyToId: _replyTo?['id'],
    );
    if (mounted) setState(() => _replyTo = null);
  }

  Future<void> _pickFiles() async {
    try {
      final res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'pdf',
          'doc',
          'docx',
          'xls',
          'xlsx',
          'csv',
          'txt',
          'odt',
          'ods',
          'ppt',
          'pptx',
        ],
        allowMultiple: false,
        withData: false,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.single;
      await _uploadAndSend(kind: 'file', path: f.path, fileName: f.name);
    } catch (_) {
      _snack(AppLocalizations.of(context).translate('chatSendFailed'));
    }
  }

  Future<bool> _saveRemote(
    String url,
    String name, {
    bool notify = true,
  }) async {
    if (_saving) return false;
    setState(() => _saving = true);
    final l10n = AppLocalizations.of(context);
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const imgs = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'};
    const vids = {'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi'};
    void okSnack(String key) {
      if (notify && mounted) _snack(l10n.translate(key), ok: true);
    }

    try {
      final dio = ref.read(dioProvider);
      final res = await dio.get<List<int>>(
        _mediaUrl(url),
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = Uint8List.fromList(res.data ?? const []);
      if (imgs.contains(ext) || vids.contains(ext)) {
        var granted = await Gal.hasAccess(toAlbum: true);
        if (!granted) granted = await Gal.requestAccess(toAlbum: true);
        if (granted) {
          final dir = await getTemporaryDirectory();
          final f = File(
            '${dir.path}/fyona_${DateTime.now().microsecondsSinceEpoch}.$ext',
          );
          await f.writeAsBytes(bytes);
          if (imgs.contains(ext)) {
            await Gal.putImage(f.path, album: 'FYONA');
          } else {
            await Gal.putVideo(f.path, album: 'FYONA');
          }
          okSnack(imgs.contains(ext) ? 'chatSavedImage' : 'chatSavedVideo');
          return true;
        }
      }
      final saved = await FilePicker.saveFile(
        fileName: name.isEmpty ? 'file' : name,
        bytes: bytes,
      );
      if (saved != null) {
        okSnack(
          imgs.contains(ext)
              ? 'chatSavedImage'
              : (vids.contains(ext) ? 'chatSavedVideo' : 'chatSavedFile'),
        );
        return true;
      }
      if (notify && mounted) _snack(l10n.translate('chatSaveFailed'));
      return false;
    } catch (_) {
      try {
        final dio = ref.read(dioProvider);
        final res = await dio.get<List<int>>(
          _mediaUrl(url),
          options: Options(responseType: ResponseType.bytes),
        );
        final saved = await FilePicker.saveFile(
          fileName: name.isEmpty ? 'file' : name,
          bytes: Uint8List.fromList(res.data ?? const []),
        );
        if (saved != null) {
          okSnack('chatSavedFile');
          return true;
        }
      } catch (_) {}
      if (notify && mounted) _snack(l10n.translate('chatSaveFailed'));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAll(List media) async {
    final list = media.whereType<Map>().toList();
    if (list.isEmpty) return;
    var n = 0;
    for (final m in list) {
      final ok = await _saveRemote(
        '${m['url']}',
        '${m['file_name'] ?? ''}',
        notify: false,
      );
      if (ok) n++;
    }
    if (mounted) {
      _snack(
        AppLocalizations.of(
          context,
        ).translate('chatSavedAll', params: {'n': '$n'}),
        ok: n > 0,
      );
    }
  }

  Future<void> _toggleVoice(Map m) async {
    final id = '${m['id']}';
    final url = '${m['media_url'] ?? ''}';
    if (_playingId == id) {
      if (_voicePaused) {
        await _player.resume();
        if (mounted) setState(() => _voicePaused = false);
      } else {
        await _player.pause();
        if (mounted) setState(() => _voicePaused = true);
      }
      return;
    }
    try {
      var local = _voiceCache[id];
      if (local == null || !File(local).existsSync()) {
        final dio = ref.read(dioProvider);
        final res = await dio.get<List<int>>(
          _mediaUrl(url),
          options: Options(responseType: ResponseType.bytes),
        );
        final dir = await getTemporaryDirectory();
        final f = File(
          '${dir.path}/play_${DateTime.now().millisecondsSinceEpoch}.m4a',
        );
        await f.writeAsBytes(res.data ?? const []);
        local = f.path;
        _voiceCache[id] = local;
      }
      await _player.stop();
      // Ignore stale position events from the previous clip for 400ms.
      _seekTarget = 0;
      _seekGrace = DateTime.now().add(const Duration(milliseconds: 400));
      // A new clip always starts at 1x so the bar matches its real duration;
      // the user can still speed up the current clip afterwards.
      _voiceSpeed = 1.0;
      await _player.setPlaybackRate(1.0);
      await _player.play(DeviceFileSource(local));
      if (mounted) {
        setState(() {
          _playingId = id;
          _voicePaused = false;
          _voicePos = 0;
          _voiceDur = 0;
          _voiceSpeed = 1.0;
        });
      }
    } catch (_) {}
  }

  Future<void> _seekVoice(double v) async {
    _seekTarget = v;
    _seekGrace = DateTime.now().add(const Duration(milliseconds: 700));
    if (mounted) setState(() => _voicePos = v);
    await _player.seek(Duration(milliseconds: (v * 1000).round()));
  }

  Future<void> _cycleSpeed() async {
    final next = _voiceSpeed == 1.0 ? 1.5 : (_voiceSpeed == 1.5 ? 2.0 : 1.0);
    await _player.setPlaybackRate(next);
    if (mounted) setState(() => _voiceSpeed = next);
  }

  Future<void> _openVideo(String url) async {
    final full = _mediaUrl(url);
    final headers = <String, String>{};
    // Dio attaches auth in an interceptor, not in options.headers. Read the
    // same token while the viewer is already opening, never pre-download.
    final accessToken =
        Uri.parse(full).host == Uri.parse(AppConfig.apiHostUrl).host
        ? ref.read(secureStorageProvider).getToken()
        : null;

    // Open immediately. The native player streams the authenticated source;
    // no full-file download, thumbnail or unrelated cache blocks navigation.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MediaViewerPage(
          videoUrl: full,
          headers: headers,
          accessToken: accessToken,
          onSave: () => _saveRemote(url, 'video.mp4'),
        ),
      ),
    );
  }

  Future<String?> _showMediaPreview(
    Uint8List bytes, {
    required bool video,
    String? videoPath,
  }) async {
    final ctrl = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          AppLocalizations.of(ctx).translate('chatPreview'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (video)
                _InlineVideoPreview(path: videoPath)
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    bytes,
                    height: 190,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(height: 12),
              FyonaTextField(
                controller: ctrl,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(
                    ctx,
                  ).translate('chatMediaCaption'),
                  hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              AppLocalizations.of(ctx).translate('chatCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DebtStyle.red),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(
              AppLocalizations.of(ctx).translate('chatSendMedia'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return res;
  }

  Duration get _recordElapsed {
    final start = _recStart;
    if (start == null) return Duration.zero;
    final now = DateTime.now();
    var d = now.difference(start) - _pausedTotal;
    if (_paused && _pausedAt != null) {
      d -= now.difference(_pausedAt!);
    }
    return d.isNegative ? Duration.zero : d;
  }

  String _mmss(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:'
      '${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Future<void> _startRecording() async {
    final l10n = AppLocalizations.of(context);
    try {
      if (!await _recorder.hasPermission()) {
        _snack(l10n.translate('chatMicDenied'));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(), path: path);
      setState(() {
        _recording = true;
        _paused = false;
        _recStart = DateTime.now();
        _pausedAt = null;
        _pausedTotal = Duration.zero;
        _recordPath = path;
      });
      _recordTick?.cancel();
      _recordTick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
      _ampSub?.cancel();
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amp) {
            if (!mounted) return;
            final v = ((amp.current + 60) / 60).clamp(0.05, 1.0);
            setState(() {
              _amps.add(v);
              if (_amps.length > 36) _amps.removeAt(0);
            });
          });
    } catch (_) {
      _snack(l10n.translate('chatMicDenied'));
    }
  }

  Future<void> _pauseResume() async {
    try {
      if (!_recording) return;
      if (_paused) {
        await _recorder.resume();
        setState(() {
          if (_pausedAt != null) {
            _pausedTotal += DateTime.now().difference(_pausedAt!);
          }
          _paused = false;
          _pausedAt = null;
        });
      } else {
        await _recorder.pause();
        setState(() {
          _paused = true;
          _pausedAt = DateTime.now();
        });
      }
    } catch (_) {}
  }

  Future<void> _cancelRecording() async {
    try {
      await _recorder.stop();
    } catch (_) {}
    final p = _recordPath;
    _resetRecording();
    if (p != null) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
  }

  void _resetRecording() {
    _recordTick?.cancel();
    _ampSub?.cancel();
    _ampSub = null;
    _amps.clear();
    setState(() {
      _recording = false;
      _paused = false;
      _recStart = null;
      _pausedAt = null;
      _pausedTotal = Duration.zero;
      _recordPath = null;
    });
  }

  Future<void> _sendRecording() async {
    if (!_recording) return;
    try {
      final durMs = _recordElapsed.inMilliseconds;
      final path = await _recorder.stop();
      final p = path ?? _recordPath;
      _resetRecording();
      if (p == null) return;
      final bytes = await File(p).readAsBytes();
      await _uploadAndSend(
        kind: 'voice',
        bytes: bytes,
        fileName: 'voice.m4a',
        durationMs: durMs,
      );
    } catch (_) {
      if (mounted) {
        _snack(AppLocalizations.of(context).translate('chatSendFailed'));
      }
    }
  }

  void _openImage(String url) {
    final full = url.startsWith('uploads/') ? '/$url' : url;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MediaViewerPage(
          imageUrl: full,
          onSave: () => _saveRemote(url, url.split('/').last),
        ),
      ),
    );
  }

  Future<void> _openFile(String url, String name) async {
    try {
      final res = await ref
          .read(dioProvider)
          .get<List<int>>(
            _mediaUrl(url),
            options: Options(responseType: ResponseType.bytes),
          );
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${name.isEmpty ? 'file' : name}');
      await f.writeAsBytes(res.data ?? const []);
      await OpenFilex.open(f.path);
    } catch (_) {
      if (mounted) {
        _snack(AppLocalizations.of(context).translate('chatSaveFailed'));
      }
    }
  }

  void _openAlbum(List media, int initialIndex) {
    final list = media
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (list.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _AlbumViewerPage(
          media: list,
          initialIndex: initialIndex.clamp(0, list.length - 1),
          onSave: (m) => _saveRemote('${m['url']}', '${m['file_name'] ?? ''}'),
          onSaveAll: _saveAll,
          onOpenVideo: _openVideo,
        ),
      ),
    );
  }

  Future<void> _pickInvoice() async {
    final l10n = AppLocalizations.of(context);
    List<Map<String, dynamic>> rows;
    try {
      rows = await ref.read(merchantApiProvider).chatInvoices(widget.linkId);
    } catch (_) {
      _snack(l10n.translate('chatPickInvoiceFailed'));
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _InvoicePickerSheet(rows: rows),
    );
    if (picked == null) return;
    if (!mounted) return;
    final caption = await _showInvoiceCaption(picked);
    if (caption == null || !mounted || _outbox.length >= 50) return;
    final message = <String, dynamic>{
      'client_id': const Uuid().v4(),
      'kind': 'invoice',
      'invoice_id': '${picked['id']}',
      'invoice_number': picked['number'],
      'text': caption.trim().isEmpty ? null : caption.trim(),
      'reply_to_id': _replyTo?['id'],
      'busy': false,
      'failed': false,
    };
    setState(() {
      _replyTo = null;
      _outbox.add(message);
    });
    unawaited(_sendPending(message));
  }

  Future<String?> _showInvoiceCaption(Map picked) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('chatInvoicePick'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long_outlined, color: DebtStyle.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${picked['number'] ?? ''}',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FyonaTextField(
              controller: ctrl,
              maxLines: 2,
              minLines: 1,
              decoration: InputDecoration(
                hintText: l10n.translate('chatInvoiceNoteHint'),
                hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              l10n.translate('chatCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DebtStyle.red),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(
              l10n.translate('chatSendMedia'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return res;
  }

  void _openInvoice(Map m) {
    final id = '${m['invoice_id'] ?? ''}';
    if (id.isEmpty) return;
    if (widget.isMerchant) {
      final type = '${_info['party_kind'] ?? 'customer'}' == 'supplier'
          ? 'purchase'
          : 'sale';
      context.push('/invoices/view?id=$id&type=$type');
    } else {
      context.push(
        '/personal/debt-operation?link=${widget.linkId}&inv=$id'
        '&name=${Uri.encodeComponent('${m['invoice_number'] ?? ''}')}',
      );
    }
  }

  bool _withinEditWindow(Map m) {
    final d = DateTime.tryParse('${m['created_at'] ?? ''}');
    if (d == null) return false;
    final mins = (_info['edit_window_minutes'] as num?)?.toInt() ?? 30;
    return DateTime.now().difference(d.toLocal()).inMinutes < mins;
  }

  void _showActions(Map m) {
    if (m['deleted'] == true) return;
    final l10n = AppLocalizations.of(context);
    final mine = m['mine'] == true;
    final kind = '${m['kind'] ?? 'text'}';
    final canEdit =
        mine &&
        _withinEditWindow(m) &&
        (kind == 'text' || kind == 'image' || kind == 'video');
    final canDelete = mine && _withinEditWindow(m);
    final canCopy = kind == 'text' && '${m['text'] ?? ''}'.isNotEmpty;
    final canReply = m['deleted'] != true;
    if (!canEdit && !canDelete && !canCopy && !canReply) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply, color: DebtStyle.red),
              title: Text(
                l10n.translate('chatReply'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyTo = m);
              },
            ),
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_rounded, color: DebtStyle.red),
                title: Text(
                  l10n.translate('chatCopy'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: '${m['text'] ?? ''}'));
                  _snack(l10n.translate('chatCopied'), ok: true);
                },
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: DebtStyle.red),
                title: Text(
                  l10n.translate('chatEdit'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _editMessage(m);
                },
              ),
            if (canDelete)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.danger,
                ),
                title: Text(
                  l10n.translate('chatDelete'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteMessage(m);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editMessage(Map m) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: '${m['text'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('chatEdit'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: InputDecoration(
            hintText: l10n.translate('chatEditHint'),
            hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
          ),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('chatCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DebtStyle.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('chatEdit'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(merchantApiProvider)
          .editChat(widget.linkId, '${m['id']}', text);
      if (!mounted) return;
      setState(() {
        m['text'] = text;
        m['edited'] = true;
      });
    } catch (_) {
      _snack(l10n.translate('chatEditExpired'));
    }
  }

  Future<void> _deleteMessage(Map m) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('chatDelete'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.translate('chatDeleteConfirm'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('chatCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('chatDelete'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(merchantApiProvider)
          .deleteChat(widget.linkId, '${m['id']}');
      if (!mounted) return;
      setState(() {
        m['deleted'] = true;
        m['text'] = null;
      });
      _snack(l10n.translate('chatDeleteDone'), ok: true);
    } catch (_) {
      _snack(l10n.translate('chatActionFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    if (visible != _routeVisible) {
      _routeVisible = visible;
      unawaited(_presence(visible));
    }
    final l10n = AppLocalizations.of(context);
    final name = '${_info['other_name'] ?? ''}';
    final online = _info['online'] == true;
    return Scaffold(
      backgroundColor: ChatStyle.pinkBg,
      body: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: ChatBackgroundPainter()),
          ),
          SafeArea(
            top: false,
            child: Column(
              children: [
                _chatHeader(context, l10n, name, online),
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _uploads.tick(widget.linkId),
                    builder: (context, tick, child) {
                      final _pending = _uploads.pending(widget.linkId);
                      return _loading
                          ? const Center(child: CircularProgressIndicator())
                          : _error != null && _messages.isEmpty
                          ? DebtRetry(
                              message: debtFriendlyError(
                                _error ?? '',
                                (k) => l10n.translate(k),
                              ),
                              retry: () => _load(initial: true),
                            )
                          : (_messages.isEmpty &&
                                _pending.isEmpty &&
                                _outbox.isEmpty)
                          ? Center(
                              child: Text(
                                l10n.translate('chatHint'),
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  color: ChatStyle.grey,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              reverse: true,
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              itemCount:
                                  _outbox.length +
                                  _pending.length +
                                  _messages.length +
                                  (_hasOlder ? 1 : 0),
                              itemBuilder: (_, i) {
                                if (i < _outbox.length) {
                                  final message =
                                      _outbox[_outbox.length - 1 - i];
                                  final failed = message['failed'] == true;
                                  return ListTile(
                                    key: ValueKey<String>(
                                      '${message['client_id']}',
                                    ),
                                    title: Text(
                                      message['kind'] == 'invoice'
                                          ? '🧾 ${message['invoice_number'] ?? ''}\n${message['text'] ?? ''}'
                                          : '${message['text']}',
                                      textAlign: TextAlign.end,
                                      style: TextStyle(
                                        color: failed
                                            ? Colors.red
                                            : ChatStyle.grey,
                                      ),
                                    ),
                                    trailing: failed
                                        ? IconButton(
                                            icon: const Icon(
                                              Icons.refresh,
                                              color: Colors.red,
                                            ),
                                            onPressed: () =>
                                                _sendPending(message),
                                          )
                                        : const Icon(Icons.schedule, size: 16),
                                    onLongPress: failed
                                        ? () => setState(
                                            () => _outbox.remove(message),
                                          )
                                        : null,
                                  );
                                }
                                i -= _outbox.length;
                                if (i < _pending.length) {
                                  return _pendingBubble(_pending[i]);
                                }
                                if (i == _pending.length + _messages.length) {
                                  return TextButton(
                                    onPressed: _loadOlder,
                                    child: const Icon(Icons.expand_less),
                                  );
                                }
                                final m =
                                    _messages[_messages.length -
                                        1 -
                                        (i - _pending.length)];
                                if (_visible &&
                                    _timeline.rendered('${m['id']}')) {
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (_visible) _sounds.play(sent: false);
                                  });
                                }
                                final gkey = _messageKeys.putIfAbsent(
                                  '${m['id']}',
                                  () => GlobalKey(),
                                );
                                return KeyedSubtree(
                                  key: gkey,
                                  child: _SwipeReply(
                                    onReply: () {
                                      HapticFeedback.mediumImpact();
                                      setState(() => _replyTo = m);
                                    },
                                    leftBackground: _replySwipeBg(
                                      Alignment.centerLeft,
                                    ),
                                    rightBackground: _replySwipeBg(
                                      Alignment.centerRight,
                                    ),
                                    child: _ChatBubble(
                                      key: ValueKey('${m['id']}'),
                                      message: m,
                                      animate: i == _pending.length,
                                      highlight:
                                          _highlightId != null &&
                                          m['id'] == _highlightId,
                                      voiceState: _playingId == m['id']
                                          ? (_voicePaused ? 2 : 1)
                                          : 0,
                                      voicePos: _playingId == m['id']
                                          ? _voicePos
                                          : 0,
                                      voiceDur: _playingId == m['id']
                                          ? _voiceDur
                                          : 0,
                                      voiceSpeed: _voiceSpeed,
                                      onSeekVoice: _seekVoice,
                                      onCycleSpeed: _cycleSpeed,
                                      onLongPress: () => _showActions(m),
                                      onToggleVoice: _toggleVoice,
                                      onOpenVideo: _openVideo,
                                      onOpenImage: _openImage,
                                      onOpenFile: _openFile,
                                      onSaveFile: _saveRemote,
                                      onOpenInvoice: _openInvoice,
                                      onReply: () =>
                                          setState(() => _replyTo = m),
                                      otherName: '${_info['other_name'] ?? ''}',
                                      onTapReply: _scrollToMessage,
                                      onOpenAlbum: _openAlbum,
                                    ),
                                  ),
                                );
                              },
                            );
                    },
                  ),
                ),
                if (_historyWindow)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _historyWindow = false;
                        _timeline.messages.clear();
                        _after = null;
                        _loading = true;
                      });
                      unawaited(_load(initial: true));
                    },
                    child: const Icon(Icons.keyboard_double_arrow_down),
                  ),
                if (_recording) _recordingBar(l10n),
                _composer(l10n),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatHeader(
    BuildContext context,
    AppLocalizations l10n,
    String name,
    bool online,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: ChatStyle.red.withAlpha(18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          KeyedSubtree(
            key: const ValueKey('chat-peer-avatar'),
            child: _avatar('${_info['other_avatar'] ?? ''}', name),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              textDirection: TextDirection.rtl,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? '…' : name,
                  key: const ValueKey('chat-peer-name'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: ChatStyle.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  textDirection: TextDirection.rtl,
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: online
                            ? ChatStyle.green
                            : const Color(0xFFEF4444),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      l10n.translate(online ? 'chatOnline' : 'chatOffline'),
                      key: const ValueKey('chat-peer-status'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: online ? ChatStyle.green : ChatStyle.grey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            key: const ValueKey('chat-back'),
            onTap: () {
              // A push-tap deep link may replace the whole stack, leaving
              // nothing to pop — fall back to the right list so the arrow
              // ALWAYS responds.
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(
                  widget.isMerchant
                      ? '/debts/notifications'
                      : '/personal/merchant-accounts',
                );
              }
            },
            borderRadius: BorderRadius.circular(30),
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(
                  color: ChatStyle.red.withAlpha(70),
                  width: 1.2,
                ),
              ),
              child: const Icon(
                Icons.chevron_left,
                color: ChatStyle.red,
                size: 22,
                textDirection: TextDirection.ltr,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _replySwipeBg(Alignment alignment) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    alignment: alignment,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.reply_rounded, color: DebtStyle.red, size: 22),
        const SizedBox(width: 6),
        Text(
          AppLocalizations.of(context).translate('chatReply'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: DebtStyle.red,
          ),
        ),
      ],
    ),
  );

  Widget _pendingBubble(Map p) {
    if (p['failed'] == true) {
      return ListTile(
        key: ValueKey('failed-upload-${p['id']}'),
        title: Text(
          '${p['name'] ?? p['caption'] ?? p['kind']}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.red),
        ),
        leading: IconButton(
          key: ValueKey('dismiss-upload-${p['id']}'),
          icon: const Icon(Icons.close, color: Colors.red),
          onPressed: () => _uploads.cancel(widget.linkId, '${p['id']}'),
        ),
        trailing: IconButton(
          key: ValueKey('retry-upload-${p['id']}'),
          icon: const Icon(Icons.refresh, color: Colors.red),
          onPressed: () => _uploads.retry(widget.linkId, '${p['id']}'),
        ),
      );
    }
    final kind = '${p['kind']}';
    final bytes = p['bytes'] as Uint8List?;
    final progress = (p['progress'] as num?)?.toDouble() ?? 0;
    final pct = (progress * 100).round();
    final isFile = kind == 'file';
    final isVoice = kind == 'voice';
    final isVideo = kind == 'video';
    final isAlbum = kind == 'album';
    final status = p['compressing'] == true ? 'جارٍ الضغط…' : 'جارٍ الإرسال…';
    final circle = SizedBox(
      width: 34,
      height: 34,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress <= 0 ? null : progress,
            strokeWidth: 3,
            color: Colors.white,
            backgroundColor: Colors.white24,
          ),
          Text(
            '$pct',
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
    final textual = isFile || isVoice;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        padding: EdgeInsets.all(textual ? 10 : 4),
        decoration: const BoxDecoration(
          color: DebtStyle.red,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(6),
            bottomRight: Radius.circular(20),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (textual)
              Row(
                children: [
                  Icon(
                    isVoice ? Icons.mic : Icons.insert_drive_file_outlined,
                    color: Colors.white,
                    size: 24,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isVoice ? 'تسجيل صوتي' : '${p['name'] ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          status,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 9.5,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: AppLocalizations.of(
                      context,
                    ).translate('chatCancelUpload'),
                    onPressed: () =>
                        _uploads.cancel(widget.linkId, '${p['id']}'),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 4),
                  circle,
                ],
              )
            else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (isVideo)
                      Container(
                        width: 210,
                        height: 140,
                        color: Colors.black26,
                        child: const Icon(
                          Icons.play_circle_fill,
                          size: 52,
                          color: Colors.white,
                        ),
                      )
                    else if (isAlbum)
                      SizedBox(
                        width: 180,
                        child: GridView.count(
                          crossAxisCount: 2,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                          children: [
                            for (final it
                                in ((p['media'] as List?) ?? const [])
                                    .whereType<Map>()
                                    .take(4))
                              it['kind'] == 'video'
                                  ? Container(
                                      color: Colors.black26,
                                      child: const Icon(
                                        Icons.play_circle_fill,
                                        color: Colors.white,
                                        size: 26,
                                      ),
                                    )
                                  : (it['bytes'] != null
                                        ? Image.memory(
                                            it['bytes'] as Uint8List,
                                            fit: BoxFit.cover,
                                          )
                                        : Container(color: Colors.black12)),
                          ],
                        ),
                      )
                    else if (bytes != null)
                      Image.memory(
                        bytes,
                        width: 200,
                        height: 200,
                        fit: BoxFit.cover,
                      )
                    else
                      const SizedBox(width: 160, height: 120),
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withAlpha(80),
                        child: Center(child: circle),
                      ),
                    ),
                  ],
                ),
              ),
              if ('${p['caption'] ?? ''}'.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
                  child: Text(
                    '${p['caption']}',
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 2, 2, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        status,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9.5,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: AppLocalizations.of(
                        context,
                      ).translate('chatCancelUpload'),
                      onPressed: () =>
                          _uploads.cancel(widget.linkId, '${p['id']}'),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _recordingBar(AppLocalizations l10n) {
    final bars = _amps.isEmpty ? List<double>.filled(28, 0.12) : _amps;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: ChatStyle.red.withAlpha(12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.fiber_manual_record,
                size: 12,
                color: ChatStyle.red,
              ),
              const SizedBox(width: 6),
              Text(
                _mmss(_recordElapsed),
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 26,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final a in bars.take(36))
                        Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            height: 4 + (a.clamp(0.0, 1.0) * 20),
                            decoration: BoxDecoration(
                              color: ChatStyle.red.withAlpha(180),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ChatStyle.red,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      side: BorderSide(color: ChatStyle.red.withAlpha(120)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _cancelRecording,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: Text(
                      l10n.translate('chatCancelRecord'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ChatStyle.red,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      side: BorderSide(color: ChatStyle.red.withAlpha(120)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _pauseResume,
                    icon: Icon(
                      _paused ? Icons.play_arrow : Icons.pause,
                      size: 16,
                    ),
                    label: Text(
                      l10n.translate(_paused ? 'chatResume' : 'chatPause'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: ChatStyle.red,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _sendRecording,
                    icon: const Icon(Icons.send, size: 15),
                    label: Text(
                      l10n.translate('chatSendRecord'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _avatar(String url, String name) {
    final fallback = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF59E0B), ChatStyle.red],
        ),
      ),
      child: Text(
        name.trim().isEmpty ? '?' : name.trim().characters.first,
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
    if (url.trim().isEmpty) return fallback;
    return ClipOval(
      child: SecureImage(
        url: url.startsWith('uploads/') ? '/$url' : url,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }

  Widget _composer(AppLocalizations l10n) {
    final hasText = _text.text.trim().isNotEmpty;
    return Container(
      padding: EdgeInsets.fromLTRB(
        10,
        8,
        10,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyTo != null) _replyPreview(l10n),
          Row(
            children: [
              _circleButton(
                icon: Icons.add,
                onTap: _sending ? null : _showAttach,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: ChatStyle.red.withAlpha(12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: FyonaTextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _sendText(),
                    decoration: InputDecoration(
                      hintText: l10n.translate('chatHint'),
                      hintStyle: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        color: ChatStyle.grey,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13.5,
                      color: ChatStyle.ink,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (c, a) => ScaleTransition(
                  scale: a,
                  child: FadeTransition(opacity: a, child: c),
                ),
                child: hasText
                    ? _circleButton(
                        key: const ValueKey('send'),
                        icon: Icons.send,
                        onTap: _sending ? null : _sendText,
                      )
                    : _circleButton(
                        key: const ValueKey('mic'),
                        icon: Icons.mic,
                        onTap: _recording ? null : _startRecording,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _circleButton({
    Key? key,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    return Material(
      key: key,
      color: ChatStyle.red,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            color: onTap == null ? Colors.white54 : Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _replyPreview(AppLocalizations l10n) {
    final m = _replyTo!;
    final t = '${m['text'] ?? m['file_name'] ?? m['invoice_number'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: BorderDirectional(
          start: BorderSide(color: ChatStyle.red, width: 3),
        ),
        boxShadow: [
          BoxShadow(
            color: ChatStyle.red.withAlpha(10),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.translate('chatReply'),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: DebtStyle.red,
                  ),
                ),
                Text(
                  t.isEmpty ? l10n.translate('chatHint') : t,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  void _showAttach() {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: DebtStyle.red,
              ),
              title: Text(
                l10n.translate('chatCamera'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickCameraImage();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: DebtStyle.red,
              ),
              title: Text(
                l10n.translate('chatGallery'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              subtitle: Text(
                l10n.translate('chatGalleryHint'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 10.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file, color: DebtStyle.red),
              title: Text(
                l10n.translate('chatFiles'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              subtitle: Text(
                l10n.translate('chatFilesHint'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 10.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickFiles();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.receipt_long_outlined,
                color: DebtStyle.red,
              ),
              title: Text(
                l10n.translate('chatInvoicePick'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickInvoice();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatBubble extends StatefulWidget {
  final Map message;
  final bool animate;
  final bool highlight;
  final VoidCallback onLongPress;
  final int voiceState;
  final double voicePos;
  final double voiceDur;
  final double voiceSpeed;
  final ValueChanged<double> onSeekVoice;
  final VoidCallback onCycleSpeed;
  final void Function(Map m) onToggleVoice;
  final void Function(String url) onOpenVideo;
  final void Function(String url) onOpenImage;
  final void Function(String url, String name) onOpenFile;
  final void Function(String url, String name) onSaveFile;
  final void Function(Map m) onOpenInvoice;
  final VoidCallback onReply;
  final String otherName;
  final void Function(String id) onTapReply;
  final void Function(List media, int index) onOpenAlbum;
  const _ChatBubble({
    super.key,
    required this.message,
    required this.animate,
    required this.highlight,
    required this.voiceState,
    required this.voicePos,
    required this.voiceDur,
    required this.voiceSpeed,
    required this.onSeekVoice,
    required this.onCycleSpeed,
    required this.onLongPress,
    required this.onToggleVoice,
    required this.onOpenVideo,
    required this.onOpenImage,
    required this.onOpenFile,
    required this.onSaveFile,
    required this.onOpenInvoice,
    required this.onReply,
    required this.otherName,
    required this.onTapReply,
    required this.onOpenAlbum,
  });
  @override
  State<_ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<_ChatBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ac,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.12),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _ac.forward();
    } else {
      _ac.value = 1;
    }
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final m = widget.message;
    final mine = m['mine'] == true;
    final deleted = m['deleted'] == true;
    final kind = '${m['kind'] ?? 'text'}';
    final edited = m['edited'] == true;
    final caption = '${m['text'] ?? ''}';
    final msgDurMs = (m['duration_ms'] as num?)?.toInt() ?? 0;
    final totalDur = msgDurMs > 0 ? msgDurMs / 1000.0 : widget.voiceDur;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final mineOnRight = mine ? !rtl : rtl;
    final bubbleMedia = ((m['media'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final videoThumb = kind == 'video' && bubbleMedia.isNotEmpty
        ? '${bubbleMedia.first['thumbnail'] ?? ''}'
        : '';
    final bg = mine ? ChatStyle.red : Colors.white;
    final fg = mine ? Colors.white : ChatStyle.ink;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Align(
          alignment: mine
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          child: GestureDetector(
            onLongPress: deleted ? null : widget.onLongPress,
            onHorizontalDragUpdate: null,
            onHorizontalDragEnd: null,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (_drag > 8)
                  Positioned(
                    left: mineOnRight ? -26 : null,
                    right: mineOnRight ? null : -26,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Opacity(
                        opacity: (_drag / 70).clamp(0.0, 1.0),
                        child: const Icon(
                          Icons.reply,
                          size: 20,
                          color: DebtStyle.red,
                        ),
                      ),
                    ),
                  ),
                Transform.translate(
                  offset: Offset(mineOnRight ? -_drag : _drag, 0),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.78,
                    ),
                    padding: EdgeInsets.all(
                      kind == 'image' || kind == 'video' ? 4 : 10,
                    ),
                    decoration: BoxDecoration(
                      gradient: mine
                          ? const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [ChatStyle.red, ChatStyle.redDark],
                            )
                          : null,
                      color: mine ? null : bg,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(20),
                        topRight: const Radius.circular(20),
                        bottomLeft: Radius.circular(mine ? 6 : 20),
                        bottomRight: Radius.circular(mine ? 20 : 6),
                      ),
                      border: Border.all(
                        color: widget.highlight
                            ? const Color(0xFFFFC107)
                            : (mine ? Colors.transparent : ChatStyle.pinkSoft),
                        width: widget.highlight ? 2 : 1,
                      ),
                      boxShadow: mine
                          ? null
                          : [
                              BoxShadow(
                                color: ChatStyle.red.withAlpha(12),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (deleted)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Text(
                              l10n.translate('chatDeletedMsg'),
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12.5,
                                fontStyle: FontStyle.italic,
                                color: mine ? Colors.white70 : Colors.grey,
                              ),
                            ),
                          )
                        else ...[
                          if (m['reply'] is Map)
                            _replyQuote(context, mine, m['reply'] as Map),
                          if (kind == 'album') _albumGrid(context, m, mine),
                          if (kind == 'image')
                            InkWell(
                              onTap: () =>
                                  widget.onOpenImage('${m['media_url'] ?? ''}'),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SecureImage(
                                  url:
                                      '${m['media_url'] ?? ''}'.startsWith(
                                        'uploads/',
                                      )
                                      ? '/${m['media_url']}'
                                      : '${m['media_url'] ?? ''}',
                                  width: 200,
                                  height: 200,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 200,
                                    height: 140,
                                    color: Colors.black12,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (kind == 'video')
                            InkWell(
                              onTap: () =>
                                  widget.onOpenVideo('${m['media_url'] ?? ''}'),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SizedBox(
                                  width: 210,
                                  height: 140,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (videoThumb.isNotEmpty)
                                        SecureImage(
                                          url: videoThumb.startsWith('uploads/')
                                              ? '/$videoThumb'
                                              : videoThumb,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              Container(color: Colors.black87),
                                        )
                                      else
                                        Container(color: Colors.black87),
                                      const Center(
                                        child: Icon(
                                          Icons.play_circle_fill,
                                          size: 52,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (kind == 'voice')
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      InkWell(
                                        onTap: () => widget.onToggleVoice(m),
                                        child: Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: mine
                                                ? Colors.white.withAlpha(40)
                                                : ChatStyle.pinkSoft,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            widget.voiceState == 1
                                                ? Icons.pause
                                                : Icons.play_arrow,
                                            color: mine
                                                ? Colors.white
                                                : ChatStyle.red,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: _VoiceWave(
                                          progress: totalDur > 0
                                              ? (widget.voicePos / totalDur)
                                                    .clamp(0.0, 1.0)
                                              : 0.0,
                                          mine: mine,
                                          onSeekFraction: (f) {
                                            if (totalDur > 0) {
                                              widget.onSeekVoice(f * totalDur);
                                            }
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      InkWell(
                                        onTap: widget.onCycleSpeed,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: mine
                                                ? Colors.white.withAlpha(35)
                                                : ChatStyle.pinkPale,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            '${widget.voiceSpeed == 1.0 ? '1' : (widget.voiceSpeed == 1.5 ? '1.5' : '2')}×',
                                            style: TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w800,
                                              color: mine
                                                  ? Colors.white
                                                  : ChatStyle.red,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Text(
                                        _fmtSec(widget.voicePos),
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 9,
                                          color: mine
                                              ? Colors.white70
                                              : ChatStyle.grey,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        _fmtSec(totalDur),
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 9,
                                          color: mine
                                              ? Colors.white70
                                              : ChatStyle.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          if (kind == 'file')
                            InkWell(
                              onTap: () => widget.onOpenFile(
                                '${m['media_url'] ?? ''}',
                                '${m['file_name'] ?? ''}',
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: mine
                                            ? Colors.white
                                            : ChatStyle.pinkPale,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Icon(
                                        Icons.description_outlined,
                                        color: ChatStyle.red,
                                        size: 24,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        '${m['file_name'] ?? l10n.translate('chatFiles')}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: fg,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.download_outlined,
                                        size: 18,
                                        color: mine
                                            ? Colors.white
                                            : ChatStyle.red,
                                      ),
                                      onPressed: () => widget.onSaveFile(
                                        '${m['media_url'] ?? ''}',
                                        '${m['file_name'] ?? 'file'}',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (kind == 'invoice')
                            InkWell(
                              onTap: () => widget.onOpenInvoice(m),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.receipt_long_outlined,
                                      color: fg,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        '${l10n.translate('debtInvoiceWord')} '
                                        '${m['invoice_number'] ?? ''}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: fg,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (kind == 'text')
                            Text(
                              caption,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13.5,
                                color: fg,
                              ),
                            )
                          else if (caption.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                              child: Text(
                                caption,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 12.5,
                                  color: fg,
                                ),
                              ),
                            ),
                        ],
                        const SizedBox(height: 3),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (edited)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  end: 8,
                                ),
                                child: Text(
                                  l10n.translate('chatEdited'),
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: mine ? Colors.white : Colors.black87,
                                  ),
                                ),
                              ),
                            Text(
                              _time('${m['created_at'] ?? ''}'),
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color: mine ? Colors.white70 : ChatStyle.grey,
                              ),
                            ),
                            if (mine && !deleted) ...[
                              const SizedBox(width: 5),
                              _receipt(m),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _replyQuote(BuildContext context, bool mine, Map reply) {
    final l10n = AppLocalizations.of(context);
    var t =
        '${reply['text'] ?? reply['file_name'] ?? reply['invoice_number'] ?? ''}';
    final mediaCount = (reply['media_count'] is num)
        ? (reply['media_count'] as num).toInt()
        : 0;
    if (t.isEmpty && mediaCount > 0) {
      t = l10n.translate('chatAlbumCount', params: {'n': '$mediaCount'});
    }
    final who = reply['mine'] == true
        ? l10n.translate('chatYou')
        : (widget.otherName.trim().isEmpty
              ? l10n.translate('chatOtherParty')
              : widget.otherName);
    final base = mine ? Colors.white : DebtStyle.red;
    return GestureDetector(
      onTap: () => widget.onTapReply('${reply['id'] ?? ''}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: (mine ? Colors.white : Colors.black).withAlpha(18),
          borderRadius: BorderRadius.circular(8),
          border: BorderDirectional(
            start: BorderSide(color: base.withAlpha(180), width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              who,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                color: base,
              ),
            ),
            Text(
              t.isEmpty ? l10n.translate('chatHint') : t,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                color: mine ? Colors.white70 : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _receipt(Map m) {
    final read = m['read'] == true;
    final delivered = m['delivered'] == true;
    if (read) {
      return const Icon(Icons.done_all, size: 15, color: ChatStyle.blue);
    }
    if (delivered) {
      return Icon(Icons.done_all, size: 15, color: Colors.white.withAlpha(220));
    }
    return Icon(Icons.done, size: 15, color: Colors.white.withAlpha(200));
  }

  Widget _albumGrid(BuildContext context, Map m, bool mine) {
    final media = ((m['media'] as List?) ?? const []).whereType<Map>().toList();
    if (media.isEmpty) return const SizedBox.shrink();
    final show = media.length > 4 ? media.take(3).toList() : media;
    final more = media.length > 4 ? media.length - 3 : 0;
    return SizedBox(
      width: 244,
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
        children: [
          for (var i = 0; i < show.length; i++) _albumTile(media, show[i], i),
          if (more > 0)
            GestureDetector(
              onTap: () => widget.onOpenAlbum(media, 3),
              child: Container(
                decoration: BoxDecoration(
                  color: mine ? Colors.white : ChatStyle.pinkPale,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  '+$more',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: ChatStyle.red,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _albumTile(List media, Map item, int index) {
    final url = '${item['url'] ?? ''}';
    final isVideo = '${item['kind']}' == 'video';
    return GestureDetector(
      onTap: () => widget.onOpenAlbum(media, index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isVideo)
              Stack(
                fit: StackFit.expand,
                children: [
                  if ('${item['thumbnail'] ?? ''}'.isNotEmpty)
                    SecureImage(
                      url: () {
                        final t = '${item['thumbnail']}';
                        return t.startsWith('uploads/') ? '/$t' : t;
                      }(),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: Colors.black87),
                    )
                  else
                    Container(color: Colors.black87),
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ],
              )
            else
              SecureImage(
                url: url.startsWith('uploads/') ? '/$url' : url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(color: Colors.black12),
              ),
          ],
        ),
      ),
    );
  }

  String _fmtSec(double s) {
    final total = s.round();
    return '${(total ~/ 60).toString().padLeft(2, '0')}:'
        '${(total % 60).toString().padLeft(2, '0')}';
  }

  String _time(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final l = d.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }
}

class _VoiceWave extends StatefulWidget {
  final double progress;
  final bool mine;
  final ValueChanged<double> onSeekFraction;
  const _VoiceWave({
    required this.progress,
    required this.mine,
    required this.onSeekFraction,
  });
  @override
  State<_VoiceWave> createState() => _VoiceWaveState();
}

class _VoiceWaveState extends State<_VoiceWave> {
  static final List<double> _heights = List<double>.generate(
    28,
    (i) => 7 + ((i * 37) % 17).toDouble(),
  );
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = (_drag ?? widget.progress).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (ctx, c) {
        void seek(Offset pos) {
          // RTL: the timeline starts on the RIGHT, so leftwards = forward.
          final f = (1 - pos.dx / c.maxWidth).clamp(0.0, 1.0);
          widget.onSeekFraction(f);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seek(d.localPosition),
          onHorizontalDragUpdate: (d) {
            setState(
              () =>
                  _drag = (1 - d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0),
            );
          },
          onHorizontalDragEnd: (_) {
            if (_drag != null) widget.onSeekFraction(_drag!);
            setState(() => _drag = null);
          },
          child: SizedBox(
            height: 28,
            child: Row(
              children: [
                for (var i = 0; i < _heights.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: 2.5,
                          height: _heights[i],
                          decoration: BoxDecoration(
                            color: (i / _heights.length) <= p
                                ? (widget.mine ? Colors.white : ChatStyle.red)
                                : (widget.mine
                                      ? Colors.white.withAlpha(80)
                                      : ChatStyle.pinkSoft),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AlbumViewerPage extends StatefulWidget {
  final List<Map<String, dynamic>> media;
  final int initialIndex;
  final void Function(Map m) onSave;
  final void Function(List media) onSaveAll;
  final void Function(String url) onOpenVideo;
  const _AlbumViewerPage({
    required this.media,
    required this.initialIndex,
    required this.onSave,
    required this.onSaveAll,
    required this.onOpenVideo,
  });
  @override
  State<_AlbumViewerPage> createState() => _AlbumViewerPageState();
}

class _AlbumViewerPageState extends State<_AlbumViewerPage> {
  late final PageController _pc = PageController(
    initialPage: widget.initialIndex,
  );
  late int _i = widget.initialIndex;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.media[_i];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '${_i + 1}/${widget.media.length}',
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 15,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: () async {
              final l10n = AppLocalizations.of(context);
              if (widget.media.length <= 1) {
                widget.onSave(current);
                return;
              }
              final allImages = widget.media.every(
                (m) => '${m['kind']}' == 'image',
              );
              final allVideos = widget.media.every(
                (m) => '${m['kind']}' == 'video',
              );
              final allLabel = allImages
                  ? 'chatSaveAllImages'
                  : (allVideos ? 'chatSaveAllVideos' : 'chatSaveAll');
              final choice = await showDialog<String>(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: Text(
                    l10n.translate('chatDownloadTitle'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  children: [
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, 'current'),
                      child: Text(
                        l10n.translate('chatSaveCurrent'),
                        style: const TextStyle(fontFamily: 'Cairo'),
                      ),
                    ),
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, 'all'),
                      child: Text(
                        l10n.translate(allLabel),
                        style: const TextStyle(fontFamily: 'Cairo'),
                      ),
                    ),
                  ],
                ),
              );
              if (choice == 'current') widget.onSave(current);
              if (choice == 'all') widget.onSaveAll(widget.media);
            },
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pc,
        reverse: true,
        onPageChanged: (i) => setState(() => _i = i),
        itemCount: widget.media.length,
        itemBuilder: (_, i) {
          final m = widget.media[i];
          final url = '${m['url'] ?? ''}';
          final full = url.startsWith('uploads/') ? '/$url' : url;
          if ('${m['kind']}' == 'video') {
            return Center(
              child: IconButton(
                iconSize: 64,
                icon: const Icon(Icons.play_circle_fill, color: Colors.white),
                onPressed: () => widget.onOpenVideo(url),
              ),
            );
          }
          return InteractiveViewer(
            child: Center(
              child: SecureImage(
                url: full,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white,
                  size: 42,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SwipeReply extends StatefulWidget {
  final Widget child;
  final Widget leftBackground;
  final Widget rightBackground;
  final VoidCallback onReply;
  const _SwipeReply({
    required this.child,
    required this.leftBackground,
    required this.rightBackground,
    required this.onReply,
  });

  @override
  State<_SwipeReply> createState() => _SwipeReplyState();
}

class _SwipeReplyState extends State<_SwipeReply> {
  static const double _max = 72;
  double _dx = 0;
  bool _dragging = false;

  void _reset() {
    if (!mounted) return;
    setState(() {
      _dragging = false;
      _dx = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final showLeft = _dx > 0;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: (d) => setState(() {
        _dx = (_dx + d.delta.dx).clamp(-_max, _max);
      }),
      onHorizontalDragEnd: (_) {
        final reply = _dx.abs() >= 34;
        _reset();
        if (reply) widget.onReply();
      },
      onHorizontalDragCancel: _reset,
      child: Stack(
        children: [
          if (_dx != 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: (_dx.abs() / 40).clamp(0.0, 1.0),
                  child: showLeft
                      ? widget.leftBackground
                      : widget.rightBackground,
                ),
              ),
            ),
          AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _InlineVideoPreview extends StatefulWidget {
  final String? path;
  const _InlineVideoPreview({this.path});

  @override
  State<_InlineVideoPreview> createState() => _InlineVideoPreviewState();
}

class _InlineVideoPreviewState extends State<_InlineVideoPreview> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final path = widget.path;
    if (path == null || path.isEmpty) {
      _failed = true;
      return;
    }
    final c = path.startsWith('content://')
        ? VideoPlayerController.contentUri(Uri.parse(path))
        : VideoPlayerController.file(File(path));
    _c = c;
    _init(c);
  }

  Future<void> _init(VideoPlayerController c) async {
    try {
      await c.initialize();
      await c.setLooping(false);
      await c.seekTo(Duration.zero);
      if (!mounted) return;
      setState(() => _ready = true);
      await c.play();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_failed) {
      return Container(
        height: 180,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Text(
            'تعذّر تشغيل هذا الفيديو',
            style: TextStyle(fontFamily: 'Cairo', color: Colors.white),
          ),
        ),
      );
    }
    if (!_ready || c == null) {
      return Container(
        height: 180,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    final ar = c.value.aspectRatio;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: ar.isFinite && ar > 0 ? ar : 16 / 9,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (_, value, __) => value.isPlaying
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(
                        Icons.play_circle_fill,
                        color: Colors.white,
                        size: 58,
                      ),
                      onPressed: () => c.play(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaViewerPage extends StatefulWidget {
  final String? imageUrl;
  final String? videoUrl;
  final String? videoFile;
  final Map<String, String> headers;
  final Future<String?>? accessToken;
  final VoidCallback? onSave;
  const _MediaViewerPage({
    this.imageUrl,
    this.videoUrl,
    this.videoFile,
    this.headers = const {},
    this.accessToken,
    this.onSave,
  });
  @override
  State<_MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<_MediaViewerPage> {
  VideoPlayerController? _c;

  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  void _createController() {
    _failed = false;
    final v = widget.videoUrl;
    final local = widget.videoFile;
    VideoPlayerController? c;
    if (local != null) {
      c = local.startsWith('content://')
          ? VideoPlayerController.contentUri(Uri.parse(local))
          : VideoPlayerController.file(File(local));
    } else if (v != null) {
      c = VideoPlayerController.networkUrl(
        Uri.parse(v),
        httpHeaders: widget.headers,
      );
    }
    if (c != null) {
      _c = c;
      _start(c);
    } else {
      _failed = true;
    }
  }

  Future<void> _start(VideoPlayerController c) async {
    try {
      await initializeChatVideoController(
        c,
        accessToken: widget.accessToken,
        isActive: () => mounted && _c == c,
      );
      if (!mounted || _c != c) return;
      await c.setLooping(false);
      await c.play();
    } catch (_) {
      if (mounted && _c == c) setState(() => _failed = true);
    }
  }

  void _retry() {
    final old = _c;
    setState(_createController);
    old?.dispose();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:'
      '${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final isImage = widget.imageUrl != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          isImage ? 'صورة' : 'فيديو',
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            color: Colors.white,
          ),
        ),
        actions: [
          if (widget.onSave != null)
            IconButton(
              tooltip: 'save',
              icon: const Icon(Icons.download_outlined),
              onPressed: widget.onSave,
            ),
        ],
      ),
      body: isImage
          ? InteractiveViewer(
              child: Center(
                child: SecureImage(
                  url: widget.imageUrl!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
              ),
            )
          : _video(),
    );
  }

  Widget _video() {
    final c = _c;
    if (c == null) return const SizedBox.shrink();
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ChatVideoSurface(
              controller: c,
              failed: _failed,
              onRetry: _retry,
            ),
          ),
        ),
        Directionality(
          textDirection: TextDirection.ltr,
          child: VideoProgressIndicator(
            c,
            allowScrubbing: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            colors: const VideoProgressColors(
              playedColor: Colors.white,
              bufferedColor: Colors.white38,
              backgroundColor: Colors.white24,
            ),
          ),
        ),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: c,
          builder: (_, value, __) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    if (value.isPlaying) {
                      c.pause();
                    } else {
                      if (value.position >= value.duration) {
                        c.seekTo(Duration.zero);
                      }
                      c.play();
                    }
                  },
                ),
                Text(
                  _fmt(value.position),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                Text(
                  _fmt(value.duration),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
      ],
    );
  }
}

class _InvoicePickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  const _InvoicePickerSheet({required this.rows});
  @override
  State<_InvoicePickerSheet> createState() => _InvoicePickerSheetState();
}

class _InvoicePickerSheetState extends State<_InvoicePickerSheet> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rows = widget.rows
        .where(
          (r) =>
              _q.isEmpty ||
              '${r['number'] ?? ''}'.toLowerCase().contains(_q.toLowerCase()),
        )
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        14,
        16,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.translate('chatInvoicePick'),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          FyonaTextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: l10n.translate('chatSearchInvoice'),
              hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      l10n.translate('chatNoInvoices'),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        color: Colors.grey,
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      return Material(
                        color: Colors.transparent,
                        child: ListTile(
                          leading: const Icon(
                            Icons.receipt_long_outlined,
                            color: DebtStyle.red,
                          ),
                          title: Text(
                            '${r['number'] ?? ''}',
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            '${r['date'] ?? ''} · '
                            '${debtAmount(r['total'])} ${debtCurrencyLabel('${r['currency'] ?? ''}')}',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, r),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
