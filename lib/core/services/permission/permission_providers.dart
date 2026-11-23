import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../interfaces/all_services.dart';
import 'permission_service.dart';

final permissionServiceProvider = Provider<PermissionService>((ref) {
  return PermissionServiceImpl(apiClient: null);
});
