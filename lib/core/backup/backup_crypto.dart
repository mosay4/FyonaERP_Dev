import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thrown when a backup file was altered, truncated, reordered or belongs to
/// another backup — nothing from it may be used.
class BackupTampered implements Exception {
  const BackupTampered(this.reason);
  final String reason;
  @override
  String toString() => 'BackupTampered($reason)';
}

/// FYONA backup container v2 (one file = one part of a backup).
///
/// ```
/// "FYBK" | ver(1)=2 | fileId(16) | frame*
/// frame = len(u32, cipher+tag) | nonce(12) | cipher | tag(16)
/// AAD   = "fybk2" | fileId | frameIndex(u32) | last(u8)
/// ```
/// Each frame holds ≤ 1 MiB of (already compressed) plaintext and is sealed
/// with ChaCha20-Poly1305 under the backup key. The AAD binds every frame to
/// its file and position, and marks the final one, so dropping, reordering,
/// swapping or truncating anything is detected before data is used.
abstract final class BackupContainer {
  static const magic = [0x46, 0x59, 0x42, 0x4B]; // FYBK
  static const version = 2;
  static const frameSize = 1 << 20;
  static final _aead = Chacha20.poly1305Aead();
  static final _rng = Random.secure();

  static Uint8List _random(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  static Uint8List _aad(List<int> fileId, int index, bool last) {
    final b = BytesBuilder()
      ..add(utf8.encode('fybk2'))
      ..add(fileId)
      ..add([(index >> 24) & 0xFF, (index >> 16) & 0xFF, (index >> 8) & 0xFF, index & 0xFF])
      ..addByte(last ? 1 : 0);
    return b.toBytes();
  }

  /// Seals [plain] into a container.
  static Future<Uint8List> seal(Uint8List plain, SecretKey key) async {
    final fileId = _random(16);
    final out = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(version)
      ..add(fileId);
    final frames = plain.isEmpty ? 1 : (plain.length + frameSize - 1) ~/ frameSize;
    for (var i = 0; i < frames; i++) {
      final start = i * frameSize;
      final end = min(start + frameSize, plain.length);
      final nonce = _random(12);
      final box = await _aead.encrypt(
        Uint8List.sublistView(plain, start, end),
        secretKey: key,
        nonce: nonce,
        aad: _aad(fileId, i, i == frames - 1),
      );
      final len = box.cipherText.length + box.mac.bytes.length;
      out
        ..add([(len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF])
        ..add(nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes);
    }
    return out.toBytes();
  }

  /// Opens a container; throws [BackupTampered] on ANY inconsistency.
  static Future<Uint8List> open(Uint8List data, SecretKey key) async {
    if (data.length < 21) throw const BackupTampered('short');
    for (var i = 0; i < 4; i++) {
      if (data[i] != magic[i]) throw const BackupTampered('magic');
    }
    if (data[4] != version) throw const BackupTampered('version');
    final fileId = Uint8List.sublistView(data, 5, 21);
    final out = BytesBuilder(copy: false);
    var pos = 21;
    var index = 0;
    var sawLast = false;
    while (pos < data.length) {
      if (sawLast) throw const BackupTampered('data after last frame');
      if (pos + 4 + 12 + 16 > data.length) throw const BackupTampered('truncated frame');
      final len = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
      pos += 4;
      final nonce = Uint8List.sublistView(data, pos, pos + 12);
      pos += 12;
      if (len < 16 || pos + len > data.length) throw const BackupTampered('frame length');
      final cipher = Uint8List.sublistView(data, pos, pos + len - 16);
      final mac = Mac(Uint8List.sublistView(data, pos + len - 16, pos + len));
      pos += len;
      final last = pos == data.length;
      try {
        out.add(await _aead.decrypt(SecretBox(cipher, nonce: nonce, mac: mac),
            secretKey: key, aad: _aad(fileId, index, last)));
      } on SecretBoxAuthenticationError {
        throw BackupTampered(last ? 'last frame (truncated or altered)' : 'frame $index altered');
      }
      sawLast = last;
      index++;
    }
    if (!sawLast) throw const BackupTampered('no final frame');
    return out.toBytes();
  }
}

/// The backup key and its recovery.
///
/// The 256-bit key is random and kept in the device keystore by the caller.
/// For a lost / new device it is wrapped with a recovery code shown once to
/// the owner (and/or a password): Argon2id → ChaCha20-Poly1305. The wrapped
/// key travels with the backups; without the code it is useless, and the
/// FYONA server never sees the key or the code.
abstract final class BackupKeys {
  static final _aead = Chacha20.poly1305Aead();
  static final _rng = Random.secure();
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford

  static Future<SecretKey> newKey() async => _aead.newSecretKey();

  static Future<Uint8List> keyBytes(SecretKey k) async => Uint8List.fromList(await k.extractBytes());

  static SecretKey keyFrom(List<int> bytes) => SecretKey(List<int>.unmodifiable(bytes));

  /// 24 symbols (120 bits), shown as XXXX-XXXX-XXXX-XXXX-XXXX-XXXX.
  static String newRecoveryCode() {
    final s = List.generate(24, (_) => _alphabet[_rng.nextInt(32)]).join();
    return [for (var i = 0; i < 24; i += 4) s.substring(i, i + 4)].join('-');
  }

  static String normalize(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '').replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');

  static Argon2id _kdf({int memory = 19456, int iterations = 2}) =>
      Argon2id(memory: memory, parallelism: 1, iterations: iterations, hashLength: 32);

  /// The key wrapped by [secret] (recovery code or password), as JSON.
  static Future<Map<String, dynamic>> wrap(SecretKey key, String secret,
      {String kind = 'recovery', int memory = 19456, int iterations = 2}) async {
    final salt = List.generate(16, (_) => _rng.nextInt(256));
    final kek = await _kdf(memory: memory, iterations: iterations)
        .deriveKey(secretKey: SecretKey(utf8.encode(kind == 'recovery' ? normalize(secret) : secret)), nonce: salt);
    final nonce = List.generate(12, (_) => _rng.nextInt(256));
    final box = await _aead.encrypt(await key.extractBytes(), secretKey: kek, nonce: nonce,
        aad: utf8.encode('fyona-backup-key/v1|$kind'));
    return {
      'v': 1, 'kind': kind, 'kdf': 'argon2id', 'm': memory, 't': iterations, 'p': 1,
      'salt': base64Encode(salt), 'nonce': base64Encode(nonce),
      'ct': base64Encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  /// The key from its wrapped form; null when [secret] is wrong.
  static Future<SecretKey?> unwrap(Map<String, dynamic> w, String secret) async {
    try {
      final kind = '${w['kind']}';
      final kek = await _kdf(memory: (w['m'] as num).toInt(), iterations: (w['t'] as num).toInt()).deriveKey(
          secretKey: SecretKey(utf8.encode(kind == 'recovery' ? normalize(secret) : secret)),
          nonce: base64Decode('${w['salt']}'));
      final ct = base64Decode('${w['ct']}');
      final plain = await _aead.decrypt(
          SecretBox(ct.sublist(0, ct.length - 16), nonce: base64Decode('${w['nonce']}'), mac: Mac(ct.sublist(ct.length - 16))),
          secretKey: kek,
          aad: utf8.encode('fyona-backup-key/v1|$kind'));
      return keyFrom(plain);
    } catch (_) {
      return null;
    }
  }
}
