import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_provider.dart';
import '../domain/services/ai_service.dart';

final aiServiceProvider = Provider<AiService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AiService(apiClient: apiClient, ref: ref);
});
