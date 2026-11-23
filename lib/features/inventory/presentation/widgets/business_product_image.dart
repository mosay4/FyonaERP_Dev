import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/secure_image.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_database.dart'
    show businessInventoryImagePrefix, businessInventoryImageMaxBytes;

export '../../data/business_inventory_image.dart' show readBusinessProductImage;

const _prefix = businessInventoryImagePrefix;
const _maxBytes = businessInventoryImageMaxBytes;

Uint8List? decodeBusinessProductImage(String? source) {
  if (source == null ||
      !source.startsWith(_prefix) ||
      source.length > _prefix.length + ((_maxBytes + 2) ~/ 3) * 4)
    return null;
  try {
    final bytes = base64Decode(source.substring(_prefix.length));
    return bytes.isEmpty || bytes.length > _maxBytes ? null : bytes;
  } on FormatException {
    return null;
  }
}

/// Device images remain in the encrypted Business catalogue. Never pass a
/// local image or a legacy URL from that catalogue to the network cache.
class BusinessProductImage extends ConsumerWidget {
  const BusinessProductImage({
    super.key,
    this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = url;
    final fallback = placeholder ?? const Icon(Icons.inventory_2_outlined);
    final bytes = decodeBusinessProductImage(source);
    if (bytes != null) {
      final px = (width == null || !width!.isFinite)
          ? null
          : (width! * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
              1,
              4096,
            );
      return Image.memory(
        bytes,
        width: width,
        height: height,
        fit: fit,
        cacheWidth: px,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    if (source?.startsWith(_prefix) == true ||
        ref.watch(businessLocalLedgerScopeProvider) != null)
      return fallback;
    return SecureImage(
      url: source,
      width: width,
      height: height,
      fit: fit,
      placeholder: placeholder,
    );
  }
}
