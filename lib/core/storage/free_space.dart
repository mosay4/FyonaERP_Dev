import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart' as win;

/// Free space on the volume of a folder, before work that writes a lot
/// (a large restore). `null` = this platform could not tell: the work then
/// goes ahead, and SQLite still fails safely (one transaction) if the disk
/// fills up.
class FreeSpace {
  /// Tests replace the probe.
  static Future<int?> Function(String path)? probe;

  static const _channel = MethodChannel('com.fyona.erp/storage_space');

  static Future<int?> of(String path) async {
    final p = probe;
    if (p != null) return p(path);
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        return (await _channel.invokeMethod<num>('freeBytes', {'path': path}))?.toInt();
      }
      if (Platform.isWindows) return _windows(path);
      final r = await Process.run('df', ['-Pk', path]);
      if (r.exitCode != 0) return null;
      final lines = '${r.stdout}'.trim().split('\n');
      final cols = lines.last.trim().split(RegExp(r'\s+'));
      final kb = cols.length >= 4 ? int.tryParse(cols[3]) : null;
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }

  static int? _windows(String path) {
    final name = path.toNativeUtf16();
    final free = calloc<Uint64>();
    try {
      return win.GetDiskFreeSpaceEx(name, free, nullptr, nullptr) == 0 ? null : free.value;
    } finally {
      calloc.free(name);
      calloc.free(free);
    }
  }

  /// Throws [NotEnoughSpace] when the volume of [path] is known to have
  /// less than [needed] bytes free.
  static Future<void> require(String path, int needed) async {
    final free = await of(path);
    if (free != null && free < needed) throw NotEnoughSpace(needed, free);
  }
}

/// The device lacks room for the operation; nothing was changed.
class NotEnoughSpace implements Exception {
  const NotEnoughSpace(this.needed, this.free);
  final int needed;
  final int free;

  /// Megabytes still to free (rounded up), for the message.
  int get missingMb => ((needed - free) / (1024 * 1024)).ceil();
  @override
  String toString() => 'NotEnoughSpace(needed $needed, free $free)';
}

/// Room always left on top of an estimate (journal, temp files, the OS).
const freeSpaceMargin = 128 * 1024 * 1024;
