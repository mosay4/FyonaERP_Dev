import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/session_notifier.dart';
import 'package:fyona_flutter/core/network/token_refresh_interceptor.dart';
import 'package:fyona_flutter/core/security/device_identity.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_api.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_models.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_service.dart';
import 'package:fyona_flutter/features/auth/auth2/widgets/phone_field.dart';

import '../support/auth2_fakes.dart';

/// Scripted HTTP layer for the interceptor test.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions o) handler;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    seen.add(o);
    return handler(o);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fyona.erp/device_identity');

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    DeviceKeyIdentity.current = NativeDeviceKeyIdentity();
    SessionNotifier.onDeviceRevoked = null;
    SessionNotifier.onExpired = null;
  });

  test('proof string is exactly the contract format', () {
    expect(
      DeviceKeyIdentity.proofMessage(nonce: 'n1', deviceId: 'd1', purpose: 'refresh'),
      'fyona-device-proof|n1|d1|refresh',
    );
  });

  group('native identity (channel contract)', () {
    late bool created;
    late List<MethodCall> calls;

    setUp(() {
      created = true;
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'ensure':
            final r = {'created': created, 'public_key': 'MFkwEwYH', 'strongbox': false};
            created = false;
            return r;
          case 'sign':
            return 'MEUCIQ-${(call.arguments as Map)['message']}';
          case 'deviceInfo':
            return {'name': 'Pixel 9', 'model': 'GKWS6', 'os': 'Android', 'os_version': '15'};
        }
        return null;
      });
    });

    test('new key → new stable device id; later launches keep it', () async {
      final first = NativeDeviceKeyIdentity();
      final id = await first.deviceId();
      expect(id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(DeviceKeyIdentity.cachedDeviceId, id);
      final second = NativeDeviceKeyIdentity();
      expect(await second.deviceId(), id, reason: 'same key → same X-Device-Id');
      expect(await second.publicKey(), 'MFkwEwYH');
      final sig = await second.signProof(nonce: 'abc', purpose: 'login');
      expect(sig, 'MEUCIQ-fyona-device-proof|abc|$id|login');
      final info = await second.deviceInfo();
      expect(info.name, 'Pixel 9');
      expect(info.osVersion, '15');
    });

    test('a re-created key pair gets a new device id', () async {
      final id1 = await NativeDeviceKeyIdentity().deviceId();
      created = true; // key wiped (restore / reinstall) → regenerated
      final id2 = await NativeDeviceKeyIdentity().deviceId();
      expect(id2, isNot(id1));
    });

    test('descriptor carries the public key and hardware facts', () async {
      final d = await NativeDeviceKeyIdentity().descriptor();
      final j = d.toJson();
      expect(j['public_key'], 'MFkwEwYH');
      expect(j['model'], 'GKWS6');
      expect(j['os'], 'Android');
      expect(j.keys, containsAll(['id', 'name', 'os_version', 'app_version']));
    });
  });

  test('Auth2Service.proof fetches a nonce and signs it', () async {
    final api = FakeAuth2Api();
    final identity = FakeDeviceKeyIdentity();
    final p = await Auth2Service(api, identity).proof(ProofPurpose.approvalCode);
    expect(p.nonce, 'nonce-1');
    expect(identity.signed.single, 'fyona-device-proof|nonce-1|device-test-0001|approval_code');
    expect(p.signature, FakeDeviceKeyIdentity.fakeSignature(identity.signed.single));
  });

  test('login / social result parsing', () {
    expect(parseLoginResult({'needs_phone': true, 'social_session': 's'}), isA<Auth2NeedsPhone>());
    final v = parseLoginResult({
      'needs_verification': true,
      'verification_id': 'v1',
      'options': ['device', 'whatsapp'],
      'primary_device': {'name': 'Galaxy', 'model': 'S24'},
    });
    expect(v, isA<Auth2NeedsVerification>());
    expect((v as Auth2NeedsVerification).verification.primaryDevice!.label, 'Galaxy · S24');
    final a = parseLoginResult({
      'access_token': 't',
      'refresh_token': 'r',
      'user': {'id': 'u', 'organization_id': 'o'},
      'device': {'device_id': 'd', 'is_primary': true, 'trusted': true},
    });
    expect((a as Auth2Authenticated).isPrimary, isTrue);
  });

  test('error body → localized text (server text first)', () {
    final e = Auth2Exception.fromBody({
      'detail': {'code': 'rate_limited', 'message_ar': 'انتظر', 'message_en': 'Wait', 'retry_after': 30}
    }, 429);
    expect(e.code, 'rate_limited');
    expect(e.retryAfter, 30);
  });

  test('phone normalisation to E.164', () {
    final ye = countryByCode('YE');
    expect(PhoneNumberParser.e164(ye, '077 123 4567'), '+967771234567');
    expect(PhoneNumberParser.e164(ye, '٧٧١٢٣٤٥٦٧'), '+967771234567');
    expect(PhoneNumberParser.isValid(ye, '12'), isFalse);
    final split = PhoneNumberParser.splitInternational('+966 50 123 4567')!;
    expect(split.$1.countryCode, 'SA');
    expect(split.$2, '501234567');
    expect(kAllCountries.length, greaterThan(200));
  });

  test('public auth2 paths never trigger a token refresh', () {
    expect(isPublicAuth2Path('/auth2/login'), isTrue);
    expect(isPublicAuth2Path('/auth2/otp/status'), isTrue);
    expect(isPublicAuth2Path('/auth2/devices'), isFalse);
    expect(isPublicAuth2Path('/auth2/approvals/pending'), isFalse);
    expect(isDeviceRevokedBody({'detail': {'code': 'device_revoked'}}), isTrue);
    expect(isDeviceRevokedBody({'detail': 'expired'}), isFalse);
  });

  group('token refresh bound to the device key', () {
    late SecureStorageService storage;
    setUp(() async {
      storage = SecureStorageService();
      await storage.saveToken('old-access');
      await storage.saveRefreshToken('refresh-1');
      DeviceKeyIdentity.current = FakeDeviceKeyIdentity();
    });

    Dio makeDio(_Adapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'http://fake.local/api/v1'));
      dio.httpClientAdapter = adapter;
      dio.interceptors.add(TokenRefreshInterceptor(secureStorage: storage, dio: dio));
      return dio;
    }

    test('401 → nonce → signed /auth2/refresh → retried request', () async {
      Map<String, dynamic>? refreshBody;
      final adapter = _Adapter((o) {
        if (o.path == '/auth2/device/nonce') return _json(200, {'nonce': 'N-7', 'expires_in': 60});
        if (o.path == '/auth2/refresh') {
          refreshBody = Map<String, dynamic>.from(o.data as Map);
          return _json(200, {'access_token': 'new-access', 'refresh_token': 'refresh-2'});
        }
        if (o.headers['Authorization'] == 'Bearer new-access') return _json(200, {'ok': true});
        return _json(401, {'detail': 'expired'});
      });
      final r = await makeDio(adapter).get('/me');
      expect(r.data, {'ok': true});
      expect(refreshBody!['device_id'], 'device-test-0001');
      expect(refreshBody!['nonce'], 'N-7');
      expect(refreshBody!['signature'],
          FakeDeviceKeyIdentity.fakeSignature('fyona-device-proof|N-7|device-test-0001|refresh'));
      expect(await storage.getRefreshToken(), 'refresh-2');
    });

    test('device_revoked signs out cleanly (revoked callback, tokens gone)', () async {
      var revoked = 0;
      var expired = 0;
      SessionNotifier.onDeviceRevoked = () => revoked++;
      SessionNotifier.onExpired = () => expired++;
      final adapter = _Adapter((o) {
        if (o.path == '/auth2/device/nonce') return _json(200, {'nonce': 'N-8'});
        if (o.path == '/auth2/refresh') {
          return _json(401, {'detail': {'code': 'device_revoked', 'message_en': 'revoked'}});
        }
        return _json(401, {'detail': 'expired'});
      });
      await expectLater(makeDio(adapter).get('/me'), throwsA(isA<DioException>()));
      expect(revoked, 1);
      expect(expired, 0);
      expect(await storage.getToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
    });

    test('an old server without auth2 falls back to /auth/refresh', () async {
      final adapter = _Adapter((o) {
        if (o.path == '/auth2/device/nonce') return _json(404, {'detail': 'Not Found'});
        if (o.path == '/auth/refresh') return _json(200, {'access_token': 'legacy-access'});
        if (o.headers['Authorization'] == 'Bearer legacy-access') return _json(200, {'ok': 1});
        return _json(401, {'detail': 'expired'});
      });
      final r = await makeDio(adapter).get('/me');
      expect(r.data, {'ok': 1});
      expect(adapter.seen.map((o) => o.path), contains('/auth/refresh'));
    });
  });
}
