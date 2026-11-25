import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end protection of what the Personal relay carries.
///
/// The relay stores and forwards opaque bytes. Every operation and snapshot
/// is sealed on the device with the user's *data key* (ChaCha20-Poly1305,
/// 256-bit). The data key never leaves the user's devices in clear: a new
/// device sends its X25519 public key (`key_request`), any device that holds
/// the data key answers with a `key_grant` — the key ring sealed with a key
/// agreed by X25519 + HKDF-SHA256 between the two devices. The server only
/// ever sees public keys and ciphertext.
///
/// Residual risk (documented, not solved here): devices grant the key to any
/// replica the relay presents as the same user's. A passive or honest server
/// learns nothing; an actively malicious server (or a stolen login) could
/// register a fake replica, send a key_request and be granted the key. A
/// device-approval / safety-code step is the follow-up.
final class PersonalRelayCrypto {
  PersonalRelayCrypto._();

  static final _aead = Chacha20.poly1305Aead();
  static final _x25519 = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _magic = ascii.encode('FPR1');
  static const _kidBytes = 8;
  static const _nonceBytes = 12;
  static const _macBytes = 16;

  static Uint8List randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  /// A new data key and its id (hex).
  static ({String kid, Uint8List key}) newDataKey() =>
      (kid: _hex(randomBytes(_kidBytes)), key: randomBytes(32));

  static Uint8List _aad(String context) =>
      Uint8List.fromList(utf8.encode('fyona-personal-relay/v1|$context'));

  static bool isEnvelope(List<int> bytes) =>
      bytes.length >= 4 + _kidBytes + _nonceBytes + _macBytes &&
      bytes[0] == _magic[0] &&
      bytes[1] == _magic[1] &&
      bytes[2] == _magic[2] &&
      bytes[3] == _magic[3];

  /// The data-key id an envelope was sealed with.
  static String? envelopeKid(List<int> bytes) =>
      isEnvelope(bytes) ? _hex(bytes.sublist(4, 4 + _kidBytes)) : null;

  /// Seals [plain] for [context] (the operation id, or the snapshot target):
  /// a payload moved to another operation id/target no longer opens.
  static Future<Uint8List> seal({
    required String kid,
    required List<int> key,
    required List<int> plain,
    required String context,
  }) async {
    final nonce = randomBytes(_nonceBytes);
    final box = await _aead.encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: _aad(context),
    );
    return Uint8List.fromList([
      ..._magic,
      ..._unhex(kid),
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Opens an envelope with the matching key of [keyring] (kid → key).
  /// Returns null when this device does not hold that key yet. Throws
  /// [SecretBoxAuthenticationError] when the bytes were changed.
  static Future<Uint8List?> open({
    required List<int> bytes,
    required Map<String, List<int>> keyring,
    required String context,
  }) async {
    final kid = envelopeKid(bytes);
    if (kid == null) throw const FormatException('not an envelope');
    final key = keyring[kid];
    if (key == null) return null;
    final body = bytes.sublist(4 + _kidBytes);
    final nonce = body.sublist(0, _nonceBytes);
    final cipher = body.sublist(_nonceBytes, body.length - _macBytes);
    final mac = body.sublist(body.length - _macBytes);
    final plain = await _aead.decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(key),
      aad: _aad(context),
    );
    return Uint8List.fromList(plain);
  }

  // ── device key agreement ─────────────────────────────────────────────────

  /// A new X25519 device key pair (private seed, public key).
  static Future<({Uint8List priv, Uint8List pub})> newDeviceKeys() async {
    final seed = randomBytes(32);
    return (priv: seed, pub: await devicePublic(seed));
  }

  static Future<Uint8List> devicePublic(List<int> priv) async {
    final pair = await _x25519.newKeyPairFromSeed(priv);
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  static Future<SecretKey> _kek({
    required List<int> myPriv,
    required List<int> otherPub,
    required List<int> granterPub,
    required List<int> requesterPub,
    required String requester,
  }) async {
    final pair = await _x25519.newKeyPairFromSeed(myPriv);
    final shared = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(otherPub, type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: [...granterPub, ...requesterPub],
      info: utf8.encode('fyona-personal-relay-kek/v1|$requester'),
    );
  }

  /// The message a device sends to obtain the user's data keys.
  static Map<String, Object?> keyRequest({
    required String replica,
    required List<int> pub,
  }) => {
    'fpr': 'key_request',
    'v': 1,
    'replica': replica,
    'pub': base64Encode(pub),
  };

  /// Answers a key_request: [keyring] sealed for the requesting device only.
  static Future<Map<String, Object?>> keyGrant({
    required String to,
    required List<int> toPub,
    required List<int> myPriv,
    required List<int> myPub,
    required Map<String, List<int>> keyring,
  }) async {
    final kek = await _kek(
      myPriv: myPriv,
      otherPub: toPub,
      granterPub: myPub,
      requesterPub: toPub,
      requester: to,
    );
    final nonce = randomBytes(_nonceBytes);
    final plain = utf8.encode(
      jsonEncode({
        for (final e in keyring.entries) e.key: base64Encode(e.value),
      }),
    );
    final box = await _aead.encrypt(
      plain,
      secretKey: kek,
      nonce: nonce,
      aad: _aad('grant:$to'),
    );
    return {
      'fpr': 'key_grant',
      'v': 1,
      'to': to,
      'from_pub': base64Encode(myPub),
      'to_pub': base64Encode(toPub),
      'n': base64Encode(nonce),
      'c': base64Encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  /// Opens a key_grant addressed to this device. Null when it is for
  /// another device (or another key pair of this one).
  static Future<Map<String, Uint8List>?> openGrant({
    required Map grant,
    required String me,
    required List<int> myPriv,
    required List<int> myPub,
  }) async {
    if (grant['to'] != me) return null;
    final toPub = base64Decode('${grant['to_pub']}');
    if (!_same(toPub, myPub)) return null;
    final fromPub = base64Decode('${grant['from_pub']}');
    final kek = await _kek(
      myPriv: myPriv,
      otherPub: fromPub,
      granterPub: fromPub,
      requesterPub: myPub,
      requester: me,
    );
    final all = base64Decode('${grant['c']}');
    final plain = await _aead.decrypt(
      SecretBox(
        all.sublist(0, all.length - _macBytes),
        nonce: base64Decode('${grant['n']}'),
        mac: Mac(all.sublist(all.length - _macBytes)),
      ),
      secretKey: kek,
      aad: _aad('grant:$me'),
    );
    final map = jsonDecode(utf8.decode(plain)) as Map;
    return {
      for (final e in map.entries)
        if (RegExp(r'^[0-9a-f]{16}$').hasMatch('${e.key}'))
          '${e.key}': base64Decode('${e.value}'),
    }..removeWhere((_, v) => v.length != 32);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  static String _hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _unhex(String h) => [
    for (var i = 0; i + 1 < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ];
}
