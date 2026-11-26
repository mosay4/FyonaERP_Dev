import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../network/api_interceptors.dart' show DeviceIdentity;

/// Hardware facts shown to the account owner (devices page, approval popup).
class DeviceHardwareInfo {
  final String name;
  final String model;
  final String os;
  final String osVersion;

  const DeviceHardwareInfo({
    required this.name,
    required this.model,
    required this.os,
    required this.osVersion,
  });

  factory DeviceHardwareInfo.fromMap(Map<dynamic, dynamic> map) =>
      DeviceHardwareInfo(
        name: (map['name'] ?? '').toString(),
        model: (map['model'] ?? '').toString(),
        os: (map['os'] ?? '').toString(),
        osVersion: (map['os_version'] ?? '').toString(),
      );
}

/// The `device` object every auth2 call carries (docs/AUTH_PLAN.md).
class DeviceDescriptor {
  final String id;
  final String publicKey;
  final String name;
  final String model;
  final String os;
  final String osVersion;
  final String appVersion;

  const DeviceDescriptor({
    required this.id,
    required this.publicKey,
    required this.name,
    required this.model,
    required this.os,
    required this.osVersion,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'public_key': publicKey,
        'name': name,
        'model': model,
        'os': os,
        'os_version': osVersion,
        'app_version': appVersion,
      };
}

/// Per-install device identity: a non-exportable ECDSA P-256 key pair in the
/// Android Keystore (StrongBox / TEE) or the iOS Secure Enclave / Keychain,
/// plus a stable random `X-Device-Id`. Login/refresh proofs are signatures
/// over a server nonce — never IP, network or location.
abstract class DeviceKeyIdentity {
  /// Last resolved device id, read synchronously by the HTTP interceptor
  /// (`X-Device-Id`). Null until the first [deviceId] call completes.
  static String? cachedDeviceId;

  /// Process-wide instance (the token-refresh interceptor has no Ref).
  /// Tests replace it with [FakeDeviceKeyIdentity].
  static DeviceKeyIdentity current = NativeDeviceKeyIdentity();

  /// The exact UTF-8 string signed for a proof (contract v2).
  static String proofMessage({
    required String nonce,
    required String deviceId,
    required String purpose,
  }) =>
      'fyona-device-proof|$nonce|$deviceId|$purpose';

  Future<String> deviceId();

  /// Base64 SubjectPublicKeyInfo DER.
  Future<String> publicKey();

  /// Base64 DER ECDSA signature (SHA-256) over the UTF-8 bytes of [message].
  Future<String> sign(String message);

  Future<DeviceHardwareInfo> deviceInfo();

  /// Signs the contract proof string for [nonce]/[purpose].
  Future<String> signProof({required String nonce, required String purpose}) async {
    final id = await deviceId();
    return sign(proofMessage(nonce: nonce, deviceId: id, purpose: purpose));
  }

  Future<DeviceDescriptor> descriptor() async {
    final id = await deviceId();
    final pk = await publicKey();
    final info = await deviceInfo();
    return DeviceDescriptor(
      id: id,
      publicKey: pk,
      name: info.name,
      model: info.model,
      os: info.os,
      osVersion: info.osVersion,
      appVersion: DeviceIdentity.appVersion ?? '',
    );
  }
}

/// Platform implementation over `com.fyona.erp/device_identity`
/// (MainActivity.kt → DeviceKeyChannel, AppDelegate.swift → FyonaDeviceIdentity).
class NativeDeviceKeyIdentity extends DeviceKeyIdentity {
  NativeDeviceKeyIdentity({
    MethodChannel? channel,
    FlutterSecureStorage? storage,
  })  : _channel = channel ?? const MethodChannel('com.fyona.erp/device_identity'),
        _storage = storage ?? const FlutterSecureStorage();

  static const storageKey = 'fyona_device_id_v2';

  final MethodChannel _channel;
  final FlutterSecureStorage _storage;
  Future<String>? _id;
  String? _publicKey;
  DeviceHardwareInfo? _info;

  @override
  Future<String> deviceId() => _id ??= _resolveId().catchError((Object e) {
        _id = null;
        throw e;
      });

  Future<String> _resolveId() async {
    final ensured = await _channel.invokeMapMethod<String, dynamic>('ensure');
    final created = ensured?['created'] == true;
    final pk = ensured?['public_key']?.toString();
    if (pk != null && pk.isNotEmpty) _publicKey = pk;
    var id = await _storage.read(key: storageKey);
    // A brand-new key pair is a brand-new device for the server: never
    // reuse an id that was bound to a previous (lost) key.
    if (created || id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _storage.write(key: storageKey, value: id);
    }
    DeviceKeyIdentity.cachedDeviceId = id;
    return id;
  }

  @override
  Future<String> publicKey() async {
    await deviceId();
    final cached = _publicKey;
    if (cached != null && cached.isNotEmpty) return cached;
    final pk = await _channel.invokeMethod<String>('publicKey');
    if (pk == null || pk.isEmpty) {
      throw PlatformException(code: 'device_key', message: 'no public key');
    }
    return _publicKey = pk;
  }

  @override
  Future<String> sign(String message) async {
    await deviceId();
    final sig = await _channel.invokeMethod<String>('sign', {'message': message});
    if (sig == null || sig.isEmpty) {
      throw PlatformException(code: 'device_key', message: 'no signature');
    }
    return sig;
  }

  @override
  Future<DeviceHardwareInfo> deviceInfo() async {
    final cached = _info;
    if (cached != null) return cached;
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('deviceInfo');
      if (map != null) return _info = DeviceHardwareInfo.fromMap(map);
    } catch (_) {}
    return _info = DeviceHardwareInfo(
      name: DeviceIdentity.name,
      model: DeviceIdentity.model ?? DeviceIdentity.name,
      os: _osName(),
      osVersion: '',
    );
  }

  static String _osName() {
    try {
      if (Platform.isIOS) return 'iOS';
      if (Platform.isAndroid) return 'Android';
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }
}

/// Deterministic in-memory identity for widget/unit tests. Its "signature"
/// is `base64("sig:" + message)` so tests can assert exactly what was signed.
class FakeDeviceKeyIdentity extends DeviceKeyIdentity {
  FakeDeviceKeyIdentity({
    this.id = 'device-test-0001',
    this.name = 'Test Phone',
    this.model = 'TP-1',
    this.os = 'Android',
    this.osVersion = '15',
  });

  final String id;
  final String name;
  final String model;
  final String os;
  final String osVersion;
  final List<String> signed = [];

  static String fakeSignature(String message) =>
      base64.encode(utf8.encode('sig:$message'));

  @override
  Future<String> deviceId() async {
    DeviceKeyIdentity.cachedDeviceId = id;
    return id;
  }

  @override
  Future<String> publicKey() async => base64.encode(utf8.encode('pk:$id'));

  @override
  Future<String> sign(String message) async {
    signed.add(message);
    return fakeSignature(message);
  }

  @override
  Future<DeviceHardwareInfo> deviceInfo() async => DeviceHardwareInfo(
        name: name,
        model: model,
        os: os,
        osVersion: osVersion,
      );
}

final deviceKeyIdentityProvider =
    Provider<DeviceKeyIdentity>((ref) => DeviceKeyIdentity.current);
