import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_provider.dart';
import '../domain/services/email_service_impl.dart';
import '../../../core/services/interfaces/all_services.dart';

final emailServiceProvider = Provider<EmailServiceImpl>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return EmailServiceImpl(apiClient: apiClient);
});

final emailServiceInterfaceProvider = Provider<EmailService>((ref) {
  return ref.watch(emailServiceProvider);
});
