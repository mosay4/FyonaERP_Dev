import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_provider.dart';
import '../domain/services/subscription_service.dart';

final subscriptionServiceProvider = Provider<SubscriptionServiceImpl>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SubscriptionServiceImpl(apiClient: apiClient);
});
