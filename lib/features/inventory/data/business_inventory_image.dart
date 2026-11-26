import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/media/media_store.dart';
import '../../../core/media/media_sync.dart';

/// Largest picked photo kept as-is (no recompression: barcodes and small
/// print stay sharp). It is a file in the media store, not a database row.
const businessProductImageMaxBytes = 10 * 1024 * 1024;

/// Only called with an image explicitly selected through the OS picker.
/// Returns the `media:<sha256>` reference and queues the cloud upload.
Future<String> readBusinessProductImage(String path) async {
  final file = File(path);
  const maxBytes = businessProductImageMaxBytes;
  if (await file.length() > maxBytes) {
    throw const FormatException('Inventory image is too large');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final part in file.openRead(0, maxBytes + 1)) {
    bytes.add(part);
  }
  final raw = bytes.takeBytes();
  final mime = _imageMime(raw);
  if (mime == null) throw const FormatException('Unsupported inventory image');
  final buffer = await ui.ImmutableBuffer.fromUint8List(raw);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width > 4096 || descriptor.height > 4096) {
        throw const FormatException('Inventory image dimensions are too large');
      }
      final codec = await descriptor.instantiateCodec(targetWidth: 128);
      try {
        if (codec.frameCount != 1) {
          throw const FormatException(
            'Animated inventory images are not supported',
          );
        }
        (await codec.getNextFrame()).image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
  final store = await MediaStore.instance();
  final ref = await store.put(raw, mime: mime);
  // The photo is saved on the device whatever happens next: queueing the
  // cloud upload is best-effort and never fails the user's edit.
  try {
    await MediaSync.queue(store, ref, MediaSection.business);
  } catch (_) {}
  return ref;
}

String? _imageMime(Uint8List b) {
  bool at(List<int> sig, [int off = 0]) {
    if (b.length < off + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[off + i] != sig[i]) return false;
    }
    return true;
  }

  if (at([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at([0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at([0x52, 0x49, 0x46, 0x46]) && at([0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp';
  if (at([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at([0x66, 0x74, 0x79, 0x70], 4)) return 'image/heic';
  return null;
}
