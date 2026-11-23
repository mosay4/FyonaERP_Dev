import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../interfaces/all_services.dart';
import 'organization_service.dart';

final organizationServiceProvider = Provider<OrganizationService>((ref) {
  return OrganizationServiceImpl(apiClient: null);
});
