import 'dart:convert';

import '../../../../core/storage/secure_storage.dart' show SecureStorageService;
import '../local_directory/directory_scope.dart';

const businessCashRelayEnabled = bool.fromEnvironment(
  'FYONA_BUSINESS_CASH_RELAY_QA',
);

typedef BusinessRelayIdentity = ({String accessToken, String sessionId});

/// Used only to match an existing local binding. The server verifies the JWT
/// and session independently. Expiry does not erase a local outbox.
Future<BusinessRelayIdentity?> readBusinessRelayIdentity(
  SecureStorageService secure,
  String account,
) async {
  try {
    final token = await secure.getToken();
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (claims is! Map ||
        claims['type'] != 'access' ||
        claims['sub'] != account) {
      return null;
    }
    final sid = claims['sid'];
    if (sid is String && sid == sid.toLowerCase() && isDirectoryId(sid)) {
      return (accessToken: token, sessionId: sid);
    }
  } catch (_) {
    // Never use a guessed ID or look at a different account's vault entry.
  }
  return null;
}

Future<String?> readBusinessCashSession(
  SecureStorageService secure,
  String account,
) async => (await readBusinessRelayIdentity(secure, account))?.sessionId;
