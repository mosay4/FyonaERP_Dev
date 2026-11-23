import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Saves files (PDF invoices) directly into the device's Downloads/FYONA ERP
/// folder via the native bridge (no share sheet), returning the saved path.
class FileSaveService {
  static const MethodChannel _ch =
      MethodChannel('com.fyona.erp/backup_storage');

  static Future<Map<String, dynamic>> savePdf(
      Uint8List bytes, String fileName) async {
    try {
      final res = await _ch.invokeMethod<dynamic>('saveFileBytes', {
        'fileName': fileName,
        'bytes': bytes,
        'mimeType': 'application/pdf',
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'success': false, 'message': 'تعذّر الحفظ'};
    } catch (e) {
      return {'success': false, 'message': '$e'};
    }
  }
}
