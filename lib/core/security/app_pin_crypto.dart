import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// App-lock PIN cryptography (5 digits, device-bound).
///
/// The PIN itself is never stored: only `salt:hash` (SHA-256) is persisted
/// in secure storage, and verification is a pure local computation — it
/// works fully offline.
String generateAppPinSalt([int length = 16]) {
  final random = Random.secure();
  final bytes = List<int>.generate(length, (_) => random.nextInt(256));
  return base64Url.encode(bytes);
}

String hashAppPin(String pin, String salt) {
  return sha256.convert(utf8.encode('$salt:$pin')).toString();
}

/// Stored record format produced by [packAppPin].
String packAppPin(String pin) {
  final salt = generateAppPinSalt();
  return '$salt:${hashAppPin(pin, salt)}';
}

bool verifyAppPinRecord(String pin, String? record) {
  try {
    if (record == null || record.isEmpty) return false;
    final parts = record.split(':');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      return false;
    }
    return hashAppPin(pin, parts[0]) == parts[1];
  } catch (_) {
    return false;
  }
}

bool isValidAppPinFormat(String pin) => RegExp(r'^\d{5}$').hasMatch(pin);
