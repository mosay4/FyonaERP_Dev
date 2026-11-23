import 'package:dio/dio.dart';

class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int maxRetries;
  final List<int> retryableStatuses;

  RetryInterceptor({
    required this.dio,
    this.maxRetries = 1,
    // NOTE: 429 is deliberately NOT retried. Rate-limit windows (60s) far
    // outlast the 1s retry delay, so an immediate retry can only fail again
    // while doubling load — it turned transient throttling (e.g. two
    // devices sharing one account) into persistent error screens.
    this.retryableStatuses = const [408, 500, 502, 503],
  });

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (!_shouldRetry(err)) {
      return handler.next(err);
    }

    final retryCount = err.requestOptions.extra['retryCount'] as int? ?? 0;
    if (retryCount >= maxRetries) {
      return handler.next(err);
    }

    await Future.delayed(const Duration(seconds: 1));

    try {
      final options = err.requestOptions.copyWith(
        extra: {...err.requestOptions.extra, 'retryCount': retryCount + 1},
      );
      final response = await dio.fetch(options);
      handler.resolve(response);
    } catch (e) {
      handler.next(err);
    }
  }

  bool _shouldRetry(DioException err) {
    // Timeouts are NOT retried: a request that reached the server just needs
    // its full (generous) timeout window; retrying after a timeout would only
    // double the wait before reporting "انتهت مهلة الطلب".
    if (err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionTimeout) {
      return false;
    }
    if (err.response != null &&
        retryableStatuses.contains(err.response!.statusCode)) {
      return true;
    }
    return false;
  }
}
