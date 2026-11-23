import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/secure_image.dart';

class EmployeeAvatar extends StatelessWidget {
  static final Map<String, Uint8List> _decoded = {};
  const EmployeeAvatar({super.key, this.photo, this.size = 56});
  final String? photo;
  final double size;

  @override
  Widget build(BuildContext context) {
    final value = (photo ?? '').trim();
    Uint8List? bytes;
    if (value.startsWith('data:image') && value.contains(',')) {
      try {
        bytes = _decoded[value];
        if (bytes == null) {
          bytes = base64Decode(value.split(',').last);
          if (_decoded.length >= 64) _decoded.remove(_decoded.keys.first);
          _decoded[value] = bytes;
        }
      } catch (_) {}
    }
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(18),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.person_rounded,
        size: size * .58,
        color: AppColors.primary,
      ),
    );
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(
          bytes,
          gaplessPlayback: true,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      );
    }
    if (value.isNotEmpty) {
      final url = value.startsWith('http')
          ? value
          : value.startsWith('/')
          ? '${AppConfig.apiHostUrl}$value'
          : '${AppConfig.apiHostUrl}/$value';
      return ClipOval(
        child: SecureImage(
          url: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      );
    }
    return fallback;
  }
}
