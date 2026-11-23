import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

/// Selected Business branch. Only the matching server-issued token authorizes
/// work in that branch; a local selection by itself is just navigation.
class BranchScope {
  static const _kToken = 'branch_scope_token';
  static const _kId = 'branch_scope_id';
  static const _kName = 'branch_scope_name';
  static const _kAll = 'branch_scope_all';
  static const _kOrg = 'branch_scope_org';
  static const _kMember = 'branch_scope_member';
  static const _kSelection = 'branch_scope_selection_v2';
  static final _writes = Lock();

  static String? token;
  static String? branchId;
  static String? branchName;
  static bool allMode = false;
  static String? organizationId;
  static bool hasMembership = false;
  static String? selectionOwner;

  static bool get awaitingServerSelection =>
      selectionOwner != null &&
      (branchId != null || allMode) &&
      (token == null || token!.isEmpty);

  static (String?, String?, bool, String?) get selection =>
      (organizationId, branchId, allMode, selectionOwner);

  /// Presentation hint only. The backend independently verifies this signed
  /// claim and validates every mutation's explicit branch and permissions.
  static bool get readOnly => allMode;

  static Map<String, dynamic>? tokenClaims(String? value) {
    try {
      final parts = value?.split('.');
      if (parts == null || parts.length != 3) return null;
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return claims is Map<String, dynamic> ? claims : null;
    } on FormatException {
      return null;
    }
  }

  static List<String> get permittedBranchIds {
    final ids = tokenClaims(token)?['branch_ids'];
    return ids is List ? ids.map((value) => '$value').toList() : const [];
  }

  static String accessCacheKey(String owner) => 'branch_access_v2_$owner';
  static String tokenCachePrefix(String owner) => 'branch_tokens_v1_${owner}_';

  static Future<void> forgetNavigationCache(String owner) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(accessCacheKey(owner));
    final prefix = tokenCachePrefix(owner);
    for (final key in sp.getKeys().where((key) => key.startsWith(prefix))) {
      await sp.remove(key);
    }
  }

  static Future<void> load() => _writes.synchronized(() async {
    final sp = await SharedPreferences.getInstance();
    hasMembership = sp.getBool(_kMember) ?? false;
    final saved = sp.getString(_kSelection);
    final data = saved == null ? null : _selectionData(saved);
    if (data != null) {
      token = data['token'] as String?;
      branchId = data['id'] as String?;
      branchName = data['name'] as String?;
      allMode = data['all'] == true;
      organizationId = data['org'] as String?;
      selectionOwner = data['owner'] as String?;
      return;
    }
    // In-place upgrades still have the previous selection on the device.
    token = sp.getString(_kToken);
    branchId = sp.getString(_kId);
    branchName = sp.getString(_kName);
    allMode = sp.getBool(_kAll) ?? false;
    organizationId = sp.getString(_kOrg);
    selectionOwner = null;
  });

  static Map<String, dynamic>? _selectionData(String saved) {
    try {
      final value = jsonDecode(saved);
      if (value is! Map<String, dynamic> ||
          [
            'token',
            'id',
            'name',
            'org',
            'owner',
          ].any((key) => value[key] != null && value[key] is! String)) {
        return null;
      }
      return value;
    } on FormatException {
      return null;
    }
  }

  static Future<void> save({
    required String? token,
    required String? branchId,
    required String? branchName,
    required bool allMode,
    String? organizationId,
    String? selectionOwner,
    bool Function()? stillSelected,
  }) => _writes.synchronized(() async {
    final sp = await SharedPreferences.getInstance();
    if (stillSelected?.call() == false) {
      throw StateError('Branch selection changed before saving');
    }
    final owner =
        selectionOwner ??
        (branchId == BranchScope.branchId &&
                allMode == BranchScope.allMode &&
                organizationId == BranchScope.organizationId
            ? BranchScope.selectionOwner
            : null);
    if (!await sp.setString(
      _kSelection,
      jsonEncode({
        'token': token,
        'id': branchId,
        'name': branchName,
        'all': allMode,
        'org': organizationId,
        'owner': owner,
      }),
    )) {
      throw StateError('Could not save branch selection');
    }
    BranchScope.token = token;
    BranchScope.branchId = branchId;
    BranchScope.branchName = branchName;
    BranchScope.allMode = allMode;
    BranchScope.organizationId = organizationId;
    BranchScope.selectionOwner = owner;
    for (final legacy in [_kToken, _kId, _kName, _kAll, _kOrg]) {
      if (sp.containsKey(legacy)) await sp.remove(legacy);
    }
  });

  static Future<void> setHasMembership(bool value) async {
    hasMembership = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kMember, value);
    } catch (_) {}
  }

  static Future<void> clear() async {
    await setHasMembership(false);
    await save(
      token: null,
      branchId: null,
      branchName: null,
      allMode: false,
      organizationId: null,
    );
  }
}
