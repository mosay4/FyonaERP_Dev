import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../interfaces/all_services.dart';
import 'file_service.dart';

final fileStorageServiceProvider = Provider<FileStorageService>((ref) {
  return FileStorageServiceImpl(apiClient: null);
});
