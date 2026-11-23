import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/project_settings_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../business_banks/presentation/providers/local_business_banking.dart';

/// Business-only payment preference: whether to allow paying more than the
/// account balance (overdraft). The confirmation dialog is shown at most ONCE
/// automatically; afterwards the merchant changes it from Profile → Preferences.
class BizPaymentPref {
  final bool allowNegative;
  final bool promptShown;
  const BizPaymentPref({this.allowNegative = false, this.promptShown = false});
  BizPaymentPref copyWith({bool? allowNegative, bool? promptShown}) =>
      BizPaymentPref(
        allowNegative: allowNegative ?? this.allowNegative,
        promptShown: promptShown ?? this.promptShown,
      );
}

class BizPaymentPrefNotifier extends StateNotifier<BizPaymentPref> {
  BizPaymentPrefNotifier([this.ref, this.local])
    : super(const BizPaymentPref());
  final Ref? ref;
  final LocalBusinessBanking? local;
  String get _scope =>
      BranchScope.organizationId ??
      ref?.read(currentUserProvider)?.organizationId ??
      'local';

  Future<void> load() async {
    final bank = local;
    if (bank != null) {
      try {
        final value = await bank.overdraft();
        if (mounted && bank.isCurrent) {
          state = BizPaymentPref(
            allowNegative: value ?? false,
            promptShown: value != null,
          );
        }
      } catch (_) {}
      return;
    }
    final scope = _scope;
    try {
      final p = await SharedPreferences.getInstance();
      final shared = ref == null
          ? <String, dynamic>{}
          : await ref!.read(projectSettingsProvider.future);
      if (scope != _scope || !mounted) return;
      state = BizPaymentPref(
        allowNegative:
            shared['allow_negative'] as bool? ??
            p.getBool('biz_allow_negative_$scope') ??
            false,
        promptShown:
            shared.containsKey('allow_negative') ||
            (p.getBool('biz_negative_prompted_$scope') ?? false),
      );
    } catch (_) {}
  }

  Future<void> setAllowNegative(bool v) async {
    final bank = local;
    if (bank != null) {
      await bank.setOverdraft(v);
      if (mounted && bank.isCurrent) {
        state = state.copyWith(allowNegative: v, promptShown: true);
      }
      return;
    }
    if (ref != null)
      await ref!.read(projectSettingsApiProvider).save({'allow_negative': v});
    if (ref != null) ref!.invalidate(projectSettingsProvider);
    state = state.copyWith(allowNegative: v, promptShown: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('biz_allow_negative_$_scope', v);
      await p.setBool('biz_negative_prompted_$_scope', true);
    } catch (_) {}
  }

  Future<void> markPromptShown() async {
    state = state.copyWith(promptShown: true);
    if (local != null) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('biz_negative_prompted_$_scope', true);
    } catch (_) {}
  }
}

final bizPaymentPrefProvider =
    StateNotifierProvider<BizPaymentPrefNotifier, BizPaymentPref>((ref) {
      final local = ref.watch(localBusinessBankingProvider);
      final notifier = BizPaymentPrefNotifier(ref, local)..load();
      if (local != null) return notifier;
      ref.listen(branchEpochProvider, (_, __) => notifier.load());
      ref.listen(projectSettingsProvider, (_, next) {
        if (next.hasValue) notifier.load();
      });
      return notifier;
    });
