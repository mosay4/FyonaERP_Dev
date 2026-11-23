import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/current_user_provider.dart';
import '../../../features/branches/data/branch_api.dart';
import '../../../features/branches/data/branch_scope.dart';
import 'enabled_currencies_service.dart'
    show defaultCurrenciesForCountry, defaultEnabledCurrencies;
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import '../../../features/core_business/data/project_settings_api.dart';
import '../../../features/business_banks/presentation/providers/local_business_banking.dart';
import '../../../features/core_business/data/local_directory/directory_scope.dart';
import '../../../features/core_business/presentation/providers/business_ledger_session.dart';

/// Business-section currency preferences — fully separate from Personal.
///
/// Personal keeps `enabled_currencies_<uid>`; Business uses
/// `enabled_currencies_biz_<uid>`. Same country defaults (home currencies +
/// USD), same fresh-only semantics: phone signup seeds both scopes, profile
/// edits each scope independently, and one section can never clobber the
/// other's set.
String _branchScope() => BranchScope.branchId ?? 'main';

String _bizKey(String userId, {String? branch}) {
  final scope = userId.trim().isEmpty ? 'global' : userId;
  final b = branch ?? _branchScope();
  return 'enabled_currencies_biz_${scope}_$b';
}

String _legacyBizKey(String userId) {
  final scope = userId.trim().isEmpty ? 'global' : userId;
  return 'enabled_currencies_biz_$scope';
}

/// Seeds the Business set from the phone country — ONLY when the user never
/// customized it. Safe to call on every phone save.
Future<void> ensureBizCountryDefaults(String iso, [String userId = '']) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getStringList(_bizKey(userId)) != null) return;
    await saveBizEnabledCurrencies(
      defaultCurrenciesForCountry(iso).toSet(),
      userId,
    );
  } catch (_) {}
}

Future<Set<String>> loadBizEnabledCurrencies([String userId = '']) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    var saved = prefs.getStringList(_bizKey(userId));
    if (_branchScope() != 'main') {
      saved ??= prefs.getStringList(_bizKey(userId, branch: 'main'));
    }
    saved ??= prefs.getStringList(_legacyBizKey(userId));
    if (saved != null && saved.isNotEmpty) return saved.toSet();
  } catch (_) {}
  return defaultEnabledCurrencies.toSet();
}

Future<void> saveBizEnabledCurrencies(
  Set<String> currencies, [
  String userId = '',
]) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_bizKey(userId), currencies.toList());
  } catch (_) {}
}

Future<List<String>> filterBizEnabled(
  List<String> codes, [
  String userId = '',
]) async {
  final enabled = await loadBizEnabledCurrencies(userId);
  return codes.where(enabled.contains).toList();
}

Future<bool> isBizCurrencyEnabled(String code, [String userId = '']) async {
  final enabled = await loadBizEnabledCurrencies(userId);
  return enabled.contains(code);
}

final bizEnabledCurrenciesProvider = FutureProvider.autoDispose<Set<String>>((
  ref,
) async {
  final userId = ref.watch(currentUserIdProvider);
  ref.watch(branchEpochProvider);
  final localBank = ref.watch(localBusinessBankingProvider);
  if (localBank != null) {
    ref.watch(businessBankRevisionProvider);
    final currencies = await localBank.cashCurrencies();
    if (currencies.isNotEmpty) return currencies;
    // A newly enrolled ledger has no accounts yet. The original bank form
    // must still allow choosing a currency for the first account. Restore
    // Business currency choices only; do not create cash on a read, touch
    // Personal settings or import any former balances.
    final defaults = await loadBizEnabledCurrencies(userId);
    if (!localBank.isCurrent) throw const DirectoryAccessDenied();
    return defaults;
  }
  final local = await loadBizEnabledCurrencies(userId);
  try {
    final shared = await ref.watch(projectSettingsProvider.future);
    final codes = shared['enabled_currencies'];
    if (codes is List && codes.isNotEmpty)
      return codes.map((c) => '$c').toSet();
  } catch (_) {}
  if (BranchScope.allMode || BranchScope.branchId == null) return local;
  try {
    final api = ref.read(branchApiProvider);
    final remote = await api.currencies();
    if (remote.isNotEmpty) {
      final set = remote.toSet();
      await saveBizEnabledCurrencies(set, userId);
      return set;
    }
    // First run after upgrading: migrate the on-device customization to the
    // account so a reinstall restores it.
    // Reading preferences must never upload an employee's local settings.
  } catch (_) {}
  return local;
});
