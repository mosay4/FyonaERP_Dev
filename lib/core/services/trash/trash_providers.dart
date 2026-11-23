import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'trash_service.dart';

final trashServiceProvider = Provider<TrashServiceImpl>((ref) {
  return TrashServiceImpl(apiClient: null);
});
