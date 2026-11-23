import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tenant_service.dart';

final tenantServiceProvider = Provider<TenantServiceImpl>((ref) {
  return TenantServiceImpl(apiClient: null);
});
