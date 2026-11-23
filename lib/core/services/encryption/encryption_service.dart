import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../network/api_client.dart';
import '../interfaces/all_services.dart';

class EncryptionServiceImpl implements EncryptionService {
  final ApiClient? apiClient;

  EncryptionServiceImpl({this.apiClient});

  @override
  String encrypt(String plainText) {
    final bytes = utf8.encode(plainText);
    return base64Encode(bytes);
  }

  @override
  String decrypt(String cipherText) {
    final bytes = base64Decode(cipherText);
    return utf8.decode(bytes);
  }

  @override
  String encryptField(String value, String fieldName) {
    final combined = '$fieldName:$value';
    return encrypt(combined);
  }

  @override
  String decryptField(String encrypted, String fieldName) {
    final decrypted = decrypt(encrypted);
    final parts = decrypted.split(':');
    if (parts.length >= 2 && parts.first == fieldName) {
      return parts.sublist(1).join(':');
    }
    return decrypted.replaceFirst('$fieldName:', '');
  }

  @override
  String hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  @override
  bool verifyPassword(String password, String hash) {
    return hashPassword(password) == hash;
  }
}
