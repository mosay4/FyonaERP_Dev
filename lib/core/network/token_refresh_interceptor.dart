import 'package:dio/dio.dart';
import '../storage/secure_storage.dart';
import 'session_notifier.dart';

class TokenRefreshInterceptor extends Interceptor {
  final SecureStorageService _secureStorage;
  final Dio _dio;
  bool _isRefreshing = false;
  final List<_PendingRequest> _pendingRequests = [];

  TokenRefreshInterceptor({
    required this._secureStorage,
    required this._dio,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode != 401) {
      return handler.next(err);
    }

    final path = err.requestOptions.path;
    if (path.contains('/auth/logout') || path.contains('/auth/refresh')) {
      return handler.next(err);
    }
    if (err.requestOptions.extra['__refresh_retried'] == true) {
      return handler.next(err);
    }

    if (_isRefreshing) {
      _pendingRequests.add(_PendingRequest(
        requestOptions: err.requestOptions,
        handler: handler,
      ));
      return;
    }

    _isRefreshing = true;
    try {
      final refreshToken = await _secureStorage.getRefreshToken();
      if (refreshToken == null) {
        await _clearAndExpire();
        return handler.next(err);
      }

      final response = await _dio.post(
        '/auth/refresh',
        data: {'refresh_token': refreshToken},
        options: Options(headers: {'Authorization': null}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final newToken = (data['access_token'] ?? data['token']) as String?;
        final newRefreshToken = data['refresh_token'] as String?;

        if (newToken != null) {
          await _secureStorage.saveToken(newToken);
        }
        if (newRefreshToken != null) {
          await _secureStorage.saveRefreshToken(newRefreshToken);
        }

        _retryPendingRequests(newToken ?? '');
        err.requestOptions.extra['__refresh_retried'] = true;
        err.requestOptions.headers['Authorization'] = 'Bearer $newToken';
        final retryResponse = await _dio.fetch(err.requestOptions);
        handler.resolve(retryResponse);
      } else if (isDefinitiveRefreshRejection(response.statusCode)) {
        await _clearAndExpire();
        handler.next(err);
      } else {
        handler.next(err);
      }
    } on DioException catch (e) {
      // Only the server saying "this session is gone" (revoked from the
      // sessions page, expired refresh token) ends the session. A weak or
      // missing network, a timeout or a server restart (5xx) never logs the
      // user out: the tokens stay and the request fails like offline.
      if (isDefinitiveRefreshRejection(e.response?.statusCode)) {
        await _clearAndExpire();
      }
      handler.next(err);
    } catch (_) {
      handler.next(err);
    } finally {
      _isRefreshing = false;
      _pendingRequests.clear();
    }
  }

  Future<void> _clearAndExpire() async {
    // Clear auth tokens + cached user ONLY. Theme, locale, biometric
    // snapshot and saved credentials are kept so the session can be
    // re-entered (biometric/passcode gate) instead of forcing a full
    // email+password login.
    await _secureStorage.deleteToken();
    await _secureStorage.deleteRefreshToken();
    await _secureStorage.deleteUserData();
    SessionNotifier.onExpired?.call();
  }

  void _retryPendingRequests(String newToken) {
    for (final pending in _pendingRequests) {
      pending.requestOptions.extra['__refresh_retried'] = true;
      pending.requestOptions.headers['Authorization'] = 'Bearer $newToken';
      _dio.fetch(pending.requestOptions).then(
        (r) => pending.handler.resolve(r),
        onError: (e) => pending.handler.next(e as DioException),
      );
    }
    _pendingRequests.clear();
  }
}

class _PendingRequest {
  final RequestOptions requestOptions;
  final ErrorInterceptorHandler handler;

  _PendingRequest({
    required this.requestOptions,
    required this.handler,
  });
}

/// The refresh endpoint rejected the refresh token itself (revoked/expired
/// session). Network errors, timeouts and 5xx are NOT a rejection.
bool isDefinitiveRefreshRejection(int? status) =>
    status == 400 || status == 401 || status == 403;
