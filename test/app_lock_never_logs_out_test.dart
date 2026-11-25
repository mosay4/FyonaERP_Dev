import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/session_notifier.dart';
import 'package:fyona_flutter/core/network/session_timeout_provider.dart';
import 'package:fyona_flutter/features/auth/data/datasources/auth_local_data_source.dart';
import 'package:fyona_flutter/core/network/token_refresh_interceptor.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart';

class _Storage implements SecureStorageService {
  String? token = 'old', refresh = 'r1';
  bool userCleared = false;
  @override
  Future<String?> getRefreshToken() async => refresh;
  @override
  Future<void> saveToken(String t) async => token = t;
  @override
  Future<void> saveRefreshToken(String t) async => refresh = t;
  @override
  Future<void> deleteToken() async => token = null;
  @override
  Future<void> deleteRefreshToken() async => refresh = null;
  @override
  Future<void> deleteUserData() async => userCleared = true;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Answers /auth/refresh with [refresh] and everything else with 401.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.refresh);
  final Future<ResponseBody> Function() refresh;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<List<int>>? _, Future<void>? __) {
    if (o.path.contains('/auth/refresh')) return refresh();
    return Future.value(ResponseBody.fromString('{}', 401,
        headers: {Headers.contentTypeHeader: ['application/json']}));
  }

  @override
  void close({bool force = false}) {}
}

Future<(bool expired, _Storage storage)> _run(Future<ResponseBody> Function() refresh) async {
  var expired = false;
  SessionNotifier.onExpired = () => expired = true;
  final storage = _Storage();
  final refreshDio = Dio()..httpClientAdapter = _Adapter(refresh);
  final api = Dio()..httpClientAdapter = _Adapter(refresh);
  api.interceptors.add(TokenRefreshInterceptor(secureStorage: storage, dio: refreshDio));
  try {
    await api.get('/personal/accounts');
  } catch (_) {}
  return (expired, storage);
}

void main() {
  lockMain();
  tearDown(() => SessionNotifier.onExpired = null);

  test('a weak network / timeout during refresh never signs the user out', () async {
    final (expired, storage) = await _run(() => Future.error(DioException(
        requestOptions: RequestOptions(path: '/auth/refresh'),
        type: DioExceptionType.connectionTimeout)));
    expect(expired, isFalse);
    expect(storage.refresh, 'r1');
    expect(storage.userCleared, isFalse);
  });

  test('a server restart (502/503) during refresh never signs the user out', () async {
    for (final code in [500, 502, 503, 504, 429]) {
      final (expired, storage) = await _run(() async => ResponseBody.fromString('{}', code));
      expect(expired, isFalse, reason: 'status $code');
      expect(storage.refresh, 'r1');
    }
  });

  test('only a revoked session (removed device / dead refresh token) ends it', () async {
    final (expired, storage) = await _run(() async => ResponseBody.fromString(
        '{"detail":"revoked"}', 401,
        headers: {Headers.contentTypeHeader: ['application/json']}));
    expect(expired, isTrue);
    expect(storage.refresh, isNull);
  });

  test('rejection codes', () {
    expect(isDefinitiveRefreshRejection(401), isTrue);
    expect(isDefinitiveRefreshRejection(403), isTrue);
    expect(isDefinitiveRefreshRejection(null), isFalse);
    expect(isDefinitiveRefreshRejection(503), isFalse);
  });
}

class _Local implements AuthLocalDataSource {
  _Local({this.duration, this.pin});
  final Duration? duration;
  final String? pin;
  @override
  Future<Duration?> getSessionTimeoutDuration() async => duration;
  @override
  Future<String?> getAppPin() async => pin;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void lockMain() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fingerprint login on → the app opens behind the in-app lock', () async {
    final n = SessionTimeoutNotifier(_Local());
    expect(await n.lockForStartup(biometric: true), isTrue);
    expect(n.state.locked, isTrue);
    n.unlock(); // fingerprint matched → straight in, no PIN step
    expect(n.state.locked, isFalse);
    n.dispose();
  });

  test('timeout + PIN set → locked at start; no protection → open', () async {
    final a = SessionTimeoutNotifier(_Local(duration: const Duration(minutes: 15), pin: 'x'));
    expect(await a.lockForStartup(biometric: false), isTrue);
    a.dispose();
    final b = SessionTimeoutNotifier(_Local(duration: const Duration(minutes: 15)));
    expect(await b.lockForStartup(biometric: false), isFalse);
    expect(b.state.locked, isFalse);
    b.dispose();
  });
}
