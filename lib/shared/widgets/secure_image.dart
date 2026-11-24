import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/services/media/chat_media_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/config/app_config.dart';
import '../../core/network/dio_provider.dart';

/// Keep server version query parameters; never append a rebuild timestamp.
String secureImageCacheKey(String url) => url.trim();

/// Loads images from protected `/uploads/...` endpoints using the app's
/// authenticated [Dio] instance (bearer token attached automatically).
///
/// Public `http(s)` URLs fall back to [Image.network] without auth headers,
/// and local file paths fall back to [Image.file].
class SecureImage extends ConsumerStatefulWidget {
  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? placeholder;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  const SecureImage({
    super.key,
    this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorBuilder,
  });

  @override
  ConsumerState<SecureImage> createState() => _SecureImageState();
}

class _SecureImageState extends ConsumerState<SecureImage> {
  Uint8List? _bytes;
  Object? _error;
  bool _loading = false;

  /// Tiny in-memory cache keyed by URL so the same protected image (e.g. a
  /// home banner) loads ONCE over the network and is reused across rebuilds,
  /// widget instances and screen refreshes — no repeated slow downloads and no
  /// "image disappears then slowly reappears" flicker.
  static final Map<String, Uint8List> _cache = {};
  static final Set<String> _inFlight = {};
  static bool _diskCleanupDone = false;

  /// Stable disk file for a URL (FNV-1a hex). The banner `?v=` stamp is part
  /// of the URL, so an admin image change naturally maps to a fresh file.
  static String _diskKey(String url) {
    var h = 0x811C9DC5;
    for (var i = 0; i < url.length; i++) {
      h ^= url.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// The same image whatever its `?v=` stamp: the last version seen is kept
  /// under this key too, so a picture still shows offline when the saved
  /// address carries no (or another) version.
  static String _latestKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return url;
    final rest = {
      for (final e in uri.queryParameters.entries)
        if (e.key != 'v') e.key: e.value,
    };
    return uri
        .replace(queryParameters: rest.isEmpty ? null : rest)
        .toString()
        .replaceFirst(RegExp(r'\?$'), '');
  }

  static Future<File?> _latestFile(String url) async {
    if (ChatMediaStore.isChatMedia(url)) return null;
    try {
      final dir = await getTemporaryDirectory();
      return File('${dir.path}/secure_img/latest_${_diskKey(_latestKey(url))}.bin');
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _diskFile(String url) async {
    // Chat attachments live in the permanent device store (the server
    // deletes them once delivered), never in the 30-day temp mirror.
    if (ChatMediaStore.isChatMedia(url)) {
      try {
        await ChatMediaStore.file(url); // creates the folder
        return File(await ChatMediaStore.pathFor(url));
      } catch (_) {
        return null;
      }
    }
    try {
      final dir = await getTemporaryDirectory();
      return File('${dir.path}/secure_img/${_diskKey(url)}.bin');
    } catch (_) {
      return null;
    }
  }

  /// Drops cached image files older than 30 days (once per launch) so the
  /// on-disk mirror stays bounded.
  static void _cleanupDiskCache() {
    if (_diskCleanupDone) return;
    _diskCleanupDone = true;
    Future(() async {
      try {
        final dir = await getTemporaryDirectory();
        final folder = Directory('${dir.path}/secure_img');
        if (!await folder.exists()) return;
        final cutoff = DateTime.now().subtract(const Duration(days: 30));
        await for (final e in folder.list()) {
          try {
            if (e is File && (await e.lastModified()).isBefore(cutoff)) {
              await e.delete();
            }
          } catch (_) {}
        }
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SecureImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  /// Returns the auth-protected URL to fetch, or null when the source is a
  /// public URL or a local file path.
  String? _secureUrl() {
    final url = widget.url;
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('/uploads/')) return '${AppConfig.apiHostUrl}$url';
    if (url.startsWith('http://') || url.startsWith('https://')) {
      final baseHost = Uri.parse(AppConfig.apiBaseUrl).host;
      final uri = Uri.tryParse(url);
      if (uri != null && uri.host == baseHost) return url;
    }
    return null;
  }

  Future<void> _load() async {
    final secureUrl = _secureUrl();
    if (secureUrl == null) {
      setState(() {
        _bytes = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    _cleanupDiskCache();
    // Serve straight from cache when we already have the bytes for this URL.
    final cached = _cache[secureUrl];
    if (cached != null) {
      setState(() {
        _bytes = cached;
        _error = null;
        _loading = false;
      });
      return;
    }
    // Another widget is already downloading this URL: wait for it instead of
    // firing a duplicate request (and never recurse — that overflows).
    if (_inFlight.contains(secureUrl)) {
      for (var i = 0; i < 100 && _inFlight.contains(secureUrl); i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (!mounted || secureUrl != _secureUrl()) return;
      }
      final hit = _cache[secureUrl];
      if (!mounted || secureUrl != _secureUrl()) return;
      setState(() {
        _bytes = hit;
        _error = hit == null ? Exception('load failed') : null;
        _loading = false;
      });
      return;
    }
    _inFlight.add(secureUrl);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 1) On-disk mirror (survives restarts → offline-first images).
      try {
        final file = await _diskFile(secureUrl);
        if (file != null && await file.exists()) {
          final diskBytes = await file.readAsBytes();
          if (diskBytes.isNotEmpty) {
            _cache[secureUrl] = diskBytes;
            // Keep the version-free copy current for offline reads.
            unawaited(() async {
              try {
                final latest = await _latestFile(secureUrl);
                if (latest != null && !await latest.exists()) {
                  await latest.writeAsBytes(diskBytes, flush: true);
                }
              } catch (_) {}
            }());
            _inFlight.remove(secureUrl);
            if (!mounted || secureUrl != _secureUrl()) return;
            setState(() {
              _bytes = diskBytes;
              _error = null;
              _loading = false;
            });
            return;
          }
        }
      } catch (_) {}
      // 2) Network (authenticated), then mirror to memory + disk.
      final dio = ref.read(dioProvider);
      final resp = await dio.get<List<int>>(
        secureUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = resp.data;
      if (!mounted || secureUrl != _secureUrl()) {
        _inFlight.remove(secureUrl);
        return;
      }
      final bytes = data is List<int> ? Uint8List.fromList(data) : null;
      if (bytes != null) {
        _cache[secureUrl] = bytes;
        try {
          final file = await _diskFile(secureUrl);
          if (file != null) {
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes, flush: true);
          }
          final latest = await _latestFile(secureUrl);
          if (latest != null) await latest.writeAsBytes(bytes, flush: true);
        } catch (_) {}
      }
      setState(() {
        _bytes = bytes;
        _error = bytes == null ? Exception('empty response') : null;
        _loading = false;
      });
    } catch (e) {
      // Offline (or the server is down): the last copy of this picture.
      try {
        final latest = await _latestFile(secureUrl);
        if (latest != null && await latest.exists()) {
          final bytes = await latest.readAsBytes();
          if (bytes.isNotEmpty) {
            _cache[secureUrl] = bytes;
            _inFlight.remove(secureUrl);
            if (!mounted || secureUrl != _secureUrl()) return;
            setState(() {
              _bytes = bytes;
              _error = null;
              _loading = false;
            });
            return;
          }
        }
      } catch (_) {}
      if (!mounted || secureUrl != _secureUrl()) {
        _inFlight.remove(secureUrl);
        return;
      }
      setState(() {
        _error = e;
        _bytes = null;
        _loading = false;
      });
    }
    _inFlight.remove(secureUrl);
  }

  Widget _err(BuildContext context, Object error, StackTrace? stackTrace) {
    if (widget.errorBuilder != null) {
      return widget.errorBuilder!(context, error, stackTrace);
    }
    return widget.placeholder ??
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          alignment: widget.alignment,
          child: const Icon(Icons.broken_image, color: Colors.grey),
        );
  }

  Widget _placeholder(BuildContext context) {
    return widget.placeholder ??
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          alignment: widget.alignment,
          child: const SizedBox.shrink(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    if (url == null || url.isEmpty) return _err(context, Exception('empty'), null);

    final secureUrl = _secureUrl();
    if (secureUrl == null) {
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return Image(
          image: CachedNetworkImageProvider(url, cacheKey: secureImageCacheKey(url)),
          gaplessPlayback: true,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          alignment: widget.alignment,
          errorBuilder: _err,
        );
      }
      final file = File(url);
      try {
        if (file.existsSync()) {
          return Image.file(
            file,
            gaplessPlayback: true,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            alignment: widget.alignment,
            errorBuilder: _err,
          );
        }
      } catch (_) {}
      return _err(context, Exception('file not found'), null);
    }

    if (_loading && _bytes == null) return _placeholder(context);
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        gaplessPlayback: true,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        alignment: widget.alignment,
        errorBuilder: _err,
      );
    }
    return _err(context, _error ?? Exception('load failed'), null);
  }
}
