import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../shared/providers/current_user_provider.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../personal/data/merchant_api.dart';
import '../../data/invoice_design_models.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import '../../../core_business/data/project_settings_api.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';

/// Business invoice-design presets (paper + thermal + returns). Separate from
/// Personal. The merchant's registered phone is used as the default company
/// phone (changeable later from the editor).
class InvoiceDesignNotifier
    extends StateNotifier<Map<String, InvoiceDesignPreset>> {
  InvoiceDesignNotifier(this._ref) : super(const {}) {
    load();
  }

  final Ref _ref;

  static const _ids = [
    'paper',
    'thermal',
    'thermal58',
    'return_paper',
    'return_thermal',
    'return_thermal58',
  ];
  String get _scopeKey =>
      BranchScope.allMode ? 'all' : (BranchScope.branchId ?? 'main');
  String _key(String id) =>
      'biz_invoice_design_${BranchScope.organizationId ?? _ref.read(currentUserProvider)?.organizationId ?? 'local'}_$id';
  String _mainKey(String id) => 'biz_invoice_design_main_$id';
  String _legacyKey(String id) => 'biz_invoice_design_$id';

  String get _phone =>
      BranchScope.organizationId != null &&
          BranchScope.organizationId !=
              _ref.read(currentUserProvider)?.organizationId
      ? ''
      : _ref.read(currentUserProvider)?.phone ?? '';

  InvoiceDesignPreset _withPhone(InvoiceDesignPreset p) {
    final ph = _phone.trim();
    if (ph.isEmpty) return p;
    if (p.companyPhone.trim().isEmpty ||
        p.companyPhone == InvoiceDesignPreset.companyPhonePlaceholder) {
      return p.copyWith(companyPhone: ph);
    }
    return p;
  }

  Future<void> load() async {
    final scope = _scopeKey;
    final p = await SharedPreferences.getInstance();
    Map shared = const {};
    try {
      shared =
          (await _ref.read(projectSettingsProvider.future))['invoice_design']
              as Map? ??
          const {};
    } catch (_) {}
    final map = <String, InvoiceDesignPreset>{};
    for (final id in _ids) {
      if (shared[id] is Map) {
        map[id] = InvoiceDesignPreset.fromJson(
          Map<String, dynamic>.from(shared[id]),
        );
        continue;
      }
      final own =
          BranchScope.organizationId == null ||
          BranchScope.organizationId ==
              _ref.read(currentUserProvider)?.organizationId;
      final raw =
          p.getString(_key(id)) ??
          (own
              ? (_scopeKey == 'main'
                    ? p.getString(_legacyKey(id))
                    : p.getString(_mainKey(id)))
              : null);
      if (raw != null && raw.isNotEmpty) {
        try {
          map[id] = _withPhone(
            InvoiceDesignPreset.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            ),
          );
          continue;
        } catch (_) {}
      }
      map[id] = InvoiceDesignPreset.defaults(id, phone: _phone);
    }
    if (!mounted || scope != _scopeKey) return;
    state = map;
    // Best-effort: sync the current paper design so a linked party sees the
    // merchant's real A4 artwork (403 for personal accounts → ignored).
    // Loading never pushes device-local identity/design into another company.
  }

  InvoiceDesignPreset getPreset(String templateId) => _withPhone(
    state[templateId] ??
        InvoiceDesignPreset.defaults(templateId, phone: _phone),
  );

  Future<void> savePreset(InvoiceDesignPreset preset) async {
    await _ref.read(projectSettingsApiProvider).save({
      'invoice_design': {preset.templateId: preset.toJson()},
    });
    _ref.invalidate(projectSettingsProvider);
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(preset.templateId), jsonEncode(preset.toJson()));
    state = {...state, preset.templateId: preset};
    // Sync to the server so a LINKED customer/supplier sees the exact same A4
    // design (logo, colours, signature, stamp, footer). Best-effort: a failed
    // upload must never block saving locally.
  }

  Future<void> resetToDefaults(String templateId) async {
    final preset = InvoiceDesignPreset.defaults(templateId, phone: _phone);
    await savePreset(preset);
  }
}

final invoiceDesignProvider =
    StateNotifierProvider<
      InvoiceDesignNotifier,
      Map<String, InvoiceDesignPreset>
    >((ref) {
      final n = InvoiceDesignNotifier(ref);
      ref.listen(branchEpochProvider, (_, __) => n.load());
      ref.listen(projectSettingsProvider, (_, next) {
        if (next.hasValue) n.load();
      });
      return n;
    });

final invoiceDesignDirtyProvider = StateProvider<bool>((ref) => false);

/// Scoped, restore-only artwork for an opening invoice. Never read the
/// unscoped legacy preference or trigger the connected editor's request.
final localInvoiceDesignProvider = FutureProvider.autoDispose
    .family<Map<String, InvoiceDesignPreset>, DirectoryAccess>((ref, scope) async {
  final prefs = await SharedPreferences.getInstance();
  if (!sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider))) {
    throw const DirectoryAccessDenied();
  }
  final result = <String, InvoiceDesignPreset>{};
  for (final id in InvoiceDesignNotifier._ids) {
    final raw = prefs.getString('biz_invoice_design_${scope.workspace.organizationId}_$id');
    if (raw == null || raw.isEmpty) continue;
    try {
      result[id] = InvoiceDesignPreset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      continue;
    } on TypeError {
      continue;
    }
  }
  return result;
});

/// Set by the design editor while mounted. Lets the bottom navigation offer
/// the same «حفظ وخروج» action without the editor's local state leaking.
Future<void> Function()? invoiceDesignSaveAndExitCallback;
