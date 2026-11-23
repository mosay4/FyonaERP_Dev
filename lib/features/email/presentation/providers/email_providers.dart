import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/email_models.dart';
import '../../di/email_providers.dart';

final emailLogListProvider = FutureProvider<List<EmailLog>>((ref) async {
  final service = ref.watch(emailServiceProvider);
  return service.getLogs();
});

final emailSettingsProvider = FutureProvider<EmailSettings?>((ref) async {
  final service = ref.watch(emailServiceProvider);
  try {
    return await service.getSettings();
  } catch (_) {
    return null;
  }
});
