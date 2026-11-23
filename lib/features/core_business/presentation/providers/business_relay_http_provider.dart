import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_config.dart';

/// Only the QA Business relay/sharing adapters use this client. Do not
/// install the app-wide retry/auth/branch interceptors: a background 401
/// must not clear or refresh saved credentials or reset the selected branch.
final businessRelayHttpProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      followRedirects: false,
      connectTimeout: const Duration(
        seconds: AppConfig.apiConnectTimeoutSeconds,
      ),
      receiveTimeout: const Duration(
        seconds: AppConfig.apiReceiveTimeoutSeconds,
      ),
      sendTimeout: const Duration(seconds: AppConfig.apiTimeoutSeconds),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});
