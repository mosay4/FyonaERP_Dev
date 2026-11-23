import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/offline/offline_guard.dart';
import '../../../shared/models/user_model.dart';
import 'section_access.dart';

/// On-device evidence of access to Personal only. Never used to open Business
/// or to authorize server requests.
class PersonalOfflineAccess {
  const PersonalOfflineAccess(this.server);

  final String server;

  String _key(String userId, String? organizationId) =>
      'personal_access_v1_${jsonEncode([server, userId, organizationId])}';

  Future<void> remember(
    String userId,
    String? organizationId,
    Map<String, dynamic> status,
  ) async {
    final sections = status['sections'];
    if (sections is! Map) return;
    final personal = sections['personal'];
    final prefs = await SharedPreferences.getInstance();
    // Persist a denial too. An old signed-in profile must not override it.
    await prefs.setString(
      _key(userId, organizationId),
      jsonEncode({
        'status': status['status'],
        'sections': {'personal': personal is Map ? personal : null},
      }),
    );
  }

  Future<Map<String, dynamic>?> read(UserModel user, {DateTime? now}) async {
    if (!user.isActive || user.id.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(user.id, user.organizationId));
    if (raw != null) {
      try {
        final snapshot = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        return hasSectionAccess(snapshot, 'personal', now: now)
            ? snapshot
            : null;
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      }
    }

    // In-place upgrades have a stored profile but no section snapshot yet.
    // Only a dated, previously granted Personal/Premium plan or trial counts.
    final trial = user.status == 'trial';
    if (!trial &&
        (user.status != 'active' ||
            !const {'personal', 'premium'}.contains(user.subscriptionPlan))) {
      return null;
    }
    final snapshot = <String, dynamic>{
      'status': trial ? 'trial' : 'active',
      'sections': {
        'personal': {
          'active': true,
          'end_date': trial ? user.trialEndDate : user.subscriptionEndDate,
        },
      },
    };
    return hasSectionAccess(snapshot, 'personal', now: now) ? snapshot : null;
  }
}

Future<Map<String, dynamic>?> resolvePersonalEntry({
  required bool connected,
  required Future<Map<String, dynamic>> Function() live,
  required Future<Map<String, dynamic>?> Function() local,
}) async {
  Future<Map<String, dynamic>?> readLocal() async {
    try {
      return await local();
    } catch (_) {
      return null;
    }
  }

  if (!connected) return readLocal();
  final cached = await readLocal();
  try {
    final request = live();
    // Wi-Fi can be connected without a route to the internet. Do not make a
    // previously authorized user wait for all the HTTP timeouts and retries.
    return cached == null
        ? await request
        : await request.timeout(const Duration(seconds: 3));
  } catch (error) {
    if (error is! TimeoutException && !isConnectivityError(error)) rethrow;
    // Re-read in case another live request saved an updated grant or denial.
    return readLocal();
  }
}
