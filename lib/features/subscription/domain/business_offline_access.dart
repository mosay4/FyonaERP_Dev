import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/models/user_model.dart';

/// Last verified Business entitlement; never used for Personal or as a server
/// credential. Keep a rejection as well so it cannot resurrect an older grant.
class BusinessOfflineAccess {
  const BusinessOfflineAccess(this.server);

  final String server;

  String _key(String account, String? organization) =>
      'business_entry_v1_${jsonEncode([server, account, organization])}';

  Future<void> remember(
    String account,
    String? organization,
    Map<String, dynamic> status,
  ) async {
    final sections = status['sections'];
    final business = sections is Map ? sections['business'] : null;
    if (sections is! Map) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(account, organization),
      jsonEncode({
        'status': status['status'],
        'is_trial': status['is_trial'] == true,
        'business_setup_completed': status['business_setup_completed'] == true,
        'sections': {'business': business is Map ? business : null},
      }),
    );
  }

  Future<Map<String, dynamic>?> read(UserModel user) async {
    if (!user.isActive || user.id.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(user.id, user.organizationId));
      final status = raw == null ? null : jsonDecode(raw);
      return status is Map<String, dynamic> ? status : null;
    } catch (_) {
      return null;
    }
  }
}
