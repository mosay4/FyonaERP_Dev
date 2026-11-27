import 'package:dio/dio.dart';
import '../security/device_identity.dart';
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
    if (path.contains('/auth/logout') ||
        path.contains('/auth/refresh') ||
        isPublicAuth2Path(path)) {
      return handler.next(err);
    }
    if (err.requestOptions.extra['__refresh_retried'] == true) {
      return handler.next(err);
    }

    if (_isRefreshing) {
      _pendingRequests.add(_PendingRequest(
        requestOptions: err.requestOptions,
        handler: handler,
        error: err,
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

      final response =
          await _refresh(refreshToken).timeout(const Duration(seconds: 15));

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
      if (isDeviceRevokedBody(e.response?.data)) {
        // The device itself was revoked: clean sign-out to the login page.
        await _clearAndRevoke();
      } else if (isDefinitiveRefreshRejection(e.response?.statusCode)) {
        await _clearAndExpire();
      }
      handler.next(err);
    } catch (_) {
      handler.next(err);
    } finally {
      _isRefreshing = false;
      // Requests that waited for a refresh that did not succeed fail like
      // their own 401 (they used to be dropped and never completed).
      final waiting = List<_PendingRequest>.of(_pendingRequests);
      _pendingRequests.clear();
      for (final p in waiting) {
        p.handler.next(p.error);
      }
    }
  }

  /// auth2 refresh bound to the device key: fresh nonce -> signature over
  /// `fyona-device-proof|{nonce}|{device_id}|refresh`. Falls back to the
  /// legacy `/auth/refresh` only when the server has no auth2 route yet
  /// (404/405) or this platform has no device key (tests / desktop).
  Future<Response> _refresh(String refreshToken) async {
    final noAuth = Options(headers: {'Authorization': null});
    String? deviceId;
    String? nonce;
    String? signature;
    try {
      final identity = DeviceKeyIdentity.current;
      deviceId = await identity.deviceId();
      final n = await _dio.post(
        '/auth2/device/nonce',
        data: {'device_id': deviceId},
        options: noAuth,
      );
      final body = n.data;
      final map = body is Map && body['data'] is Map ? body['data'] as Map : body;
      nonce = map is Map ? map['nonce']?.toString() : null;
      if (nonce != null && nonce.isNotEmpty) {
        signature = await identity.signProof(nonce: nonce, purpose: 'refresh');
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != 404 && code != 405) rethrow;
    } catch (_) {
      // No device key on this platform: legacy refresh below.
    }
    if (deviceId != null && nonce != null && signature != null) {
      try {
        return await _dio.post(
          '/auth2/refresh',
          data: {
            'refresh_token': refreshToken,
            'device_id': deviceId,
            'nonce': nonce,
            'signature': signature,
          },
          options: noAuth,
        );
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        // A session signed in through the password login is not bound to
        // this device key: the server answers `device_not_trusted`. That is
        // not "signed out" — renew it through the classic refresh below.
        if (code != 404 && code != 405 && !isUnboundSessionBody(e.response?.data)) {
          rethrow;
        }
      }
    }
    return _dio.post(
      '/auth/refresh',
      data: {'refresh_token': refreshToken},
      options: noAuth,
    );
  }

  Future<void> _clearAndRevoke() async {
    await _secureStorage.deleteToken();
    await _secureStorage.deleteRefreshToken();
    await _secureStorage.deleteUserData();
    final revoked = SessionNotifier.onDeviceRevoked;
    if (revoked != null) {
      revoked();
    } else {
      SessionNotifier.onExpired?.call();
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
  final DioException error;

  _PendingRequest({
    required this.requestOptions,
    required this.handler,
    required this.error,
  });
}

/// The refresh endpoint rejected the refresh token itself (revoked/expired
/// session). Network errors, timeouts and 5xx are NOT a rejection.
bool isDefinitiveRefreshRejection(int? status) =>
    status == 400 || status == 401 || status == 403;

/// Server body `{detail:{code:'device_revoked'}}` (auth2).
bool isDeviceRevokedBody(dynamic body) {
  if (body is! Map) return false;
  final detail = body['detail'];
  if (detail is Map) return detail['code']?.toString() == 'device_revoked';
  return body['code']?.toString() == 'device_revoked';
}

/// Server body `{detail:{code:'device_not_trusted'}}`: the refresh token is
/// valid but belongs to a session that is not bound to this device key.
bool isUnboundSessionBody(dynamic body) {
  if (body is! Map) return false;
  final detail = body['detail'];
  if (detail is Map) return detail['code']?.toString() == 'device_not_trusted';
  return body['code']?.toString() == 'device_not_trusted';
}

/// auth2 routes that never carry a session (a 401 there is a wrong
/// password / code, not an expired access token).
bool isPublicAuth2Path(String path) {
  const public = [
    '/auth2/login',
    '/auth2/register',
    '/auth2/otp',
    '/auth2/social',
    '/auth2/password',
    '/auth2/device/nonce',
    '/auth2/refresh',
  ];
  return public.any(path.contains);
}
