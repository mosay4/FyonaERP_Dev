import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'quota_service.dart';

final quotaServiceProvider = Provider<QuotaServiceImpl>((ref) {
  return QuotaServiceImpl(apiClient: null);
});
