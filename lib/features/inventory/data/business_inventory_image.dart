import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core_business/data/local_directory/directory_database.dart'
    show businessInventoryImageWriteMaxBytes, encodeBusinessInventoryImage;

/// Only called with an image explicitly selected through the OS picker.
Future<String> readBusinessProductImage(String path) async {
  final file = File(path);
  const maxBytes = businessInventoryImageWriteMaxBytes;
  if (await file.length() > maxBytes) {
    throw const FormatException('Inventory image is too large');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final part in file.openRead(0, maxBytes + 1)) {
    bytes.add(part);
  }
  final raw = bytes.takeBytes();
  final encoded = encodeBusinessInventoryImage(raw);
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
  return encoded;
}
