import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart' show dioProvider;
import '../../../core/services/connectivity_service.dart';
import '../../../core/utils/server_image_url.dart';
import 'branch_api.dart';

/// Branch pictures live on the device.
///
/// Every picture the account's branches use (the owner's and an employee's
/// workspace alike) is copied once into the app's own storage, keyed by the
/// branch. Screens read only that copy, so a picture shows with or without
/// internet, right after a restart. When the owner changes a picture, the new
/// version arrives through sync and replaces the copy; nothing is read from
/// the network while a screen is drawn.
abstract final class BranchPictures {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/branch_pictures');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _indexFile() async =>
      File('${(await _dir()).path}/index.json');

  /// branch id → {sig: source signature, file: stored file name}
  static Future<Map<String, Map<String, String>>> _index() async {
    try {
      final file = await _indexFile();
      if (!await file.exists()) return {};
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return {};
      return {
        for (final entry in data.entries)
          if (entry.value is Map)
            '${entry.key}': {
              for (final v in (entry.value as Map).entries)
                '${v.key}': '${v.value}',
            },
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveIndex(Map<String, Map<String, String>> index) async {
    final file = await _indexFile();
    await file.writeAsString(jsonEncode(index), flush: true);
  }

  /// Branch id → absolute path of its picture on this device.
  static Future<Map<String, String>> paths() async {
    try {
      final dir = await _dir();
      final out = <String, String>{};
      for (final entry in (await _index()).entries) {
        final name = entry.value['file'];
        if (name == null) continue;
        final file = File('${dir.path}/$name');
        if (await file.exists()) out[entry.key] = file.path;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String _hash(String value) {
    var h = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static bool _isApiHost(String url) {
    final uri = Uri.tryParse(url);
    final api = Uri.tryParse(AppConfig.apiBaseUrl);
    return uri != null && api != null && uri.host == api.host;
  }

  static bool _busy = false;

  /// Copy every branch picture that changed into the device store. Returns
  /// true when at least one picture was added or replaced.
  static Future<bool> sync(
    Dio dio,
    Iterable<Map<String, dynamic>> rows, {
    Dio? public,
  }) async {
    if (_busy) return false;
    _busy = true;
    try {
      final dir = await _dir();
      final index = await _index();
      var changed = false;
      for (final row in rows) {
        final id = '${row['id'] ?? ''}'.trim();
        final raw = '${row['image'] ?? ''}'.trim();
        if (id.isEmpty || raw.isEmpty || raw == 'null') continue;
        try {
          List<int>? bytes;
          String signature;
          if (raw.startsWith('local://')) {
            final file = File(raw.substring('local://'.length));
            if (!await file.exists()) continue;
            signature =
                'local:${file.path}:${(await file.lastModified()).millisecondsSinceEpoch}';
            if (index[id]?['sig'] == signature) continue;
            bytes = await file.readAsBytes();
          } else {
            final url = versionedServerImageUrl(
              raw,
              row['image_version']?.toString(),
            );
            if (url == null) continue;
            signature = url;
            if (index[id]?['sig'] == signature) continue;
            // The session's client only for FYONA's own server.
            final client = _isApiHost(url) ? dio : (public ?? Dio());
            final response = await client.get<List<int>>(
              url,
              options: Options(responseType: ResponseType.bytes),
            );
            bytes = response.data;
          }
          if (bytes == null || bytes.isEmpty) continue;
          // A new file name per version: no stale picture from image caches.
          final name = '${_safe(id)}_${_hash(signature)}.img';
          await File('${dir.path}/$name').writeAsBytes(bytes, flush: true);
          final old = index[id]?['file'];
          if (old != null && old != name) {
            try {
              await File('${dir.path}/$old').delete();
            } catch (_) {}
          }
          index[id] = {'sig': signature, 'file': name};
          changed = true;
        } catch (_) {
          // Offline or a missing picture: the stored copy stays.
        }
      }
      if (changed) await _saveIndex(index);
      return changed;
    } finally {
      _busy = false;
    }
  }
}

final branchPictureRevisionProvider = StateProvider<int>((_) => 0);

/// Branch id → picture file on this device.
final branchPicturePathsProvider = FutureProvider<Map<String, String>>((ref) {
  ref.watch(branchPictureRevisionProvider);
  return BranchPictures.paths();
});

/// Keeps the device copies current from the branch lists this device already
/// has (owner list with pictures set here, and the access list an employee
/// receives). Watch it where branches are shown.
final branchPictureSyncProvider = Provider<void>((ref) {
  // Only lists already saved on this device are read here (never a request
  // of its own); the copies are refreshed whenever those lists change.
  Future<void> run() async {
    final api = ref.read(branchApiProvider);
    final rows = <String, Map<String, dynamic>>{};
    try {
      for (final company in await api.cachedAccess() ?? const []) {
        for (final branch in (company['branches'] as List? ?? const [])) {
          if (branch is Map) {
            rows['${branch['id']}'] = Map<String, dynamic>.from(branch);
          }
        }
      }
    } catch (_) {}
    // The owner's own list wins (it carries pictures set on this device).
    try {
      for (final row in await api.savedList()) {
        final id = '${row['id']}';
        final image = '${row['image'] ?? ''}'.trim();
        if (image.isEmpty && rows.containsKey(id)) continue;
        rows[id] = {...?rows[id], ...row};
      }
    } catch (_) {}
    if (rows.isEmpty) return;
    final changed = await BranchPictures.sync(
      ref.read(dioProvider),
      rows.values,
    );
    if (changed) ref.read(branchPictureRevisionProvider.notifier).state++;
  }

  if (ref.exists(branchMenuAccessProvider)) {
    ref.listen(branchMenuAccessProvider, (_, _) => unawaited(run()));
  }
  if (ref.exists(branchAccessProvider)) {
    ref.listen(branchAccessProvider, (_, _) => unawaited(run()));
  }
  if (ref.exists(savedBranchListProvider)) {
    ref.listen(savedBranchListProvider, (_, _) => unawaited(run()));
  }
  // Back online: bring any changed picture (downloads only new versions).
  final subscription = ref
      .read(connectivityServiceProvider)
      .onConnectivityChanged
      .listen((online) {
        if (online) unawaited(run());
      });
  ref.onDispose(subscription.cancel);
  unawaited(run());
});

/// A branch picture from the device store (instant, offline too); [fallback]
/// when this branch has none on the device yet.
class BranchPicture extends ConsumerWidget {
  const BranchPicture({
    super.key,
    required this.branchId,
    required this.size,
    required this.fallback,
    this.radius,
  });

  final String? branchId;
  final double size;
  final Widget fallback;

  /// null → a circle.
  final double? radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(branchPictureSyncProvider);
    final path = branchId == null
        ? null
        : ref.watch(branchPicturePathsProvider).valueOrNull?[branchId];
    if (path == null) return fallback;
    final image = Image.file(
      File(path),
      key: ValueKey(path),
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
    return SizedBox(
      width: size,
      height: size,
      child: radius == null
          ? ClipOval(child: image)
          : ClipRRect(
              borderRadius: BorderRadius.circular(radius!),
              child: image,
            ),
    );
  }

  /// Whether a device copy exists (for callers that choose a layout).
  static bool has(WidgetRef ref, String? branchId) =>
      branchId != null &&
      ref.watch(branchPicturePathsProvider).valueOrNull?.containsKey(
            branchId,
          ) ==
          true;
}
