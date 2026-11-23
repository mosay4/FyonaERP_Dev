import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_provider.dart';
import '../domain/services/email_template_service.dart';

final emailTemplateServiceProvider = Provider<EmailTemplateService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return EmailTemplateService(apiClient: apiClient);
});
