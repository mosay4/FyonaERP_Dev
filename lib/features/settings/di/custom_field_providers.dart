import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_provider.dart';
import '../domain/services/custom_field_service.dart';

final customFieldServiceProvider = Provider<CustomFieldService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return CustomFieldService(apiClient: apiClient);
});
