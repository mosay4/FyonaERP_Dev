import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../network/api_client.dart';
import '../interfaces/all_services.dart';

class FileStorageServiceImpl implements FileStorageService {
  final ApiClient? apiClient;

  FileStorageServiceImpl({this.apiClient});

  @override
  Future<Map<String, dynamic>> uploadFile(String path, Uint8List bytes, {String? folder}) async {
    if (apiClient != null) {
      try {
        final formData = FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: path.split('/').last),
          'folder': ?folder,
        });
        final response = await apiClient!.post('/api/files/upload', data: formData);
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('fileUploadFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<Uint8List?> downloadFile(int fileId) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.dio.get('/api/files/$fileId/download', options: Options(responseType: ResponseType.bytes));
        return response.data as Uint8List;
      } catch (e) {
        throw Exception(AppLocalizations.t('fileDownloadFailed', {'error': e.toString()}));
      }
    }
    return null;
  }

  @override
  Future<bool> deleteFile(int fileId) async {
    if (apiClient != null) {
      try {
        await apiClient!.delete('/api/files/$fileId');
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('fileDeleteFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<List<Map<String, dynamic>>> listFiles({String? folder, int page = 1}) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/files', queryParameters: {'folder': ?folder, 'page': page});
        return (response.data as List).whereType<Map<String, dynamic>>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('fileListFailed', {'error': e.toString()}));
      }
    }
    return [
      {'id': 1, 'name': 'شعار الشركة.png', 'size': 245760, 'type': 'image/png', 'folder': 'images', 'uploaded_at': '2025-06-01', 'uploaded_by': 'المدير'},
      {'id': 2, 'name': 'تقرير المبيعات Q2.xlsx', 'size': 1048576, 'type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'folder': 'reports', 'uploaded_at': '2025-07-01', 'uploaded_by': 'محاسب'},
      {'id': 3, 'name': 'كشف حساب البنك.pdf', 'size': 524288, 'type': 'application/pdf', 'folder': 'financial', 'uploaded_at': '2025-07-05', 'uploaded_by': 'المدير المالي'},
      {'id': 4, 'name': 'دليل المستخدم.pdf', 'size': 2097152, 'type': 'application/pdf', 'folder': 'docs', 'uploaded_at': '2025-06-15', 'uploaded_by': 'النظام'},
    ];
  }

  @override
  Future<Map<String, dynamic>> getFileStats() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/files/stats');
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('fileStatsFailed', {'error': e.toString()}));
      }
    }
    return {'total_files': 4, 'total_size': 3915776, 'by_type': {'images': 1, 'documents': 2, 'spreadsheets': 1}};
  }
}
