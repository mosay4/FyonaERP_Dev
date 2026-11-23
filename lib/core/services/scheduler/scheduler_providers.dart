import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../interfaces/all_services.dart';
import 'scheduler_service.dart';

final schedulerServiceProvider = Provider<SchedulerService>((ref) {
  return SchedulerServiceImpl(apiClient: null);
});
