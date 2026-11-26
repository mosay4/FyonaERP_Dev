import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/providers.dart';
import '../network/api_client.dart';
import 'media_store.dart';
import 'media_sync.dart';

/// FYONA server endpoints for media (presigned R2 URLs). Business calls go to
/// `/business-storage` (branch token + live membership checked there),
/// Personal and chat to `/storage`.
class ApiMediaRemote implements MediaRemote {
  ApiMediaRemote(this._api);
  final ApiClient _api;

  String _base(MediaSection s) => s == MediaSection.business ? '/business-storage' : '/storage';

  Map<String, dynamic> _scope(MediaSection s, String? linkId) => s == MediaSection.business
      ? const {}
      : {'section': s == MediaSection.chat ? 'chat' : 'personal', if (linkId != null) 'link_id': linkId};

  Map<String, dynamic> _data(Object? body) {
    final m = body is Map ? body : const {};
    final d = m['data'];
    return d is Map ? Map<String, dynamic>.from(d) : const {};
  }

  @override
  Future<Map<String, dynamic>> uploadUrl(MediaSection section, String sha,
      {required int size, required String mime, String? linkId}) async {
    final r = await _api.post<Map<String, dynamic>>('${_base(section)}/upload-url', data: {
      ..._scope(section, linkId), 'area': 'm', 'sha256': sha, 'size': size, 'content_type': mime,
    });
    return _data(r.data);
  }

  @override
  Future<void> commit(MediaSection section, String sha, {required int size, String? linkId}) async {
    await _api.post<Map<String, dynamic>>('${_base(section)}/commit', data: {
      ..._scope(section, linkId), 'area': 'm', 'sha256': sha, 'size': size,
    });
  }

  @override
  Future<String> downloadUrl(MediaSection section, String sha, {String? linkId}) async {
    final r = await _api.post<Map<String, dynamic>>('${_base(section)}/download-url', data: {
      ..._scope(section, linkId), 'area': 'm', 'sha256': sha,
    });
    return '${_data(r.data)['url']}';
  }
}

final mediaStoreProvider = FutureProvider<MediaStore>((ref) => MediaStore.instance());

/// Device ⇄ cloud media mover (one per app scope).
final mediaSyncProvider = FutureProvider<MediaSync>((ref) async {
  final store = await ref.watch(mediaStoreProvider.future);
  return MediaSync(store: store, remote: ApiMediaRemote(ref.watch(apiClientProvider)));
});

/// Shows a `media:<sha256>` image: from this device when present, else
/// downloaded once (verified) from the cloud. Offline + missing → [fallback].
class MediaImage extends ConsumerStatefulWidget {
  const MediaImage({
    super.key,
    required this.mediaRef,
    required this.section,
    this.linkId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.fallback,
  });

  final String mediaRef;
  final MediaSection section;
  final String? linkId;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? fallback;

  @override
  ConsumerState<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends ConsumerState<MediaImage> {
  File? _file;
  bool _tried = false;

  @override
  void didUpdateWidget(covariant MediaImage old) {
    super.didUpdateWidget(old);
    if (old.mediaRef != widget.mediaRef) {
      _file = null;
      _tried = false;
    }
  }

  Future<void> _load() async {
    if (_tried) return;
    _tried = true;
    final store = await ref.read(mediaStoreProvider.future);
    var file = store.fileOf(widget.mediaRef);
    if (file == null) {
      final sync = await ref.read(mediaSyncProvider.future);
      file = await sync.ensureLocal(widget.mediaRef, widget.section,
          linkId: widget.linkId, mime: 'image/jpeg');
    }
    if (mounted && file != null) setState(() => _file = file);
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.fallback ?? const Icon(Icons.image_outlined);
    final file = _file;
    if (file == null) {
      unawaited(_load());
      return SizedBox(width: widget.width, height: widget.height, child: Center(child: fallback));
    }
    final w = widget.width;
    final px = (w == null || !w.isFinite)
        ? null
        : (w * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 4096);
    return Image.file(file,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: px,
        errorBuilder: (_, _, _) => fallback);
  }
}

/// Drains the media upload queue in the background: whenever something is
/// queued, and every 2 minutes (retries back off inside [MediaSync]).
/// Uploads never block the user's work; offline they simply wait.
final mediaUploaderProvider = Provider<void>((ref) {
  Timer? timer;
  StreamSubscription<void>? sub;
  Future<void> run() async {
    try {
      final sync = await ref.read(mediaSyncProvider.future);
      await sync.drain();
    } catch (_) {}
  }

  sub = MediaSync.kicks.listen((_) => unawaited(run()));
  timer = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(run()));
  unawaited(run());
  ref.onDispose(() {
    timer?.cancel();
    sub?.cancel();
  });
});
