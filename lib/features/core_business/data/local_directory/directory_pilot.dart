import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import '../../../../core/config/directory_pilot_build.dart';
import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../../core/network/api_client.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../subscription/domain/section_access.dart';
import '../local_ledger/business_relay_identity.dart';
import 'directory_database.dart';
import 'directory_party.dart';
import 'directory_scope.dart';
import 'directory_secure_storage.dart';

final directoryPilotAccessProvider = Provider<DirectoryAccess?>((ref) {
  if (!DirectoryPilotBuild.enabled) return null;
  ref.watch(branchEpochProvider);
  final auth = ref.watch(authProvider);
  final user = auth.user;
  if (!auth.isAuthenticated ||
      user == null ||
      !user.hasPhone ||
      !user.isActive ||
      user.role != 'owner') {
    return null;
  }
  return resolveDirectoryPilot(
    server: ref.watch(serverBaseUrlProvider),
    accountId: user.id,
    organizationId: user.organizationId,
    selectedOrganizationId: BranchScope.organizationId,
    selectedBranchId: BranchScope.branchId,
    selectedToken: BranchScope.token,
    readOnly: BranchScope.readOnly,
  );
});

/// The token is the existing app context received from /branches/select.
/// Checking its claims here binds that context to our one lab account, not
/// to arbitrary prefs or deep links. This does not replace API verification.
DirectoryAccess? resolveDirectoryPilot({
  required String server,
  required String accountId,
  required String? organizationId,
  required String? selectedOrganizationId,
  required String? selectedBranchId,
  required String? selectedToken,
  required bool readOnly,
}) {
  if (!validDirectoryPilotScope(
        server,
        accountId,
        organizationId,
        selectedBranchId,
      ) ||
      selectedOrganizationId != organizationId ||
      selectedToken == null ||
      readOnly) {
    return null;
  }
  bool financialCutover;
  String? writerSession;
  DateTime? transferExpiry;
  Map<String, String>? transferBranches;
  String? cashLinkId;
  try {
    final parts = selectedToken.split('.');
    if (parts.length != 3) return null;
    final data = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (data is! Map ||
        data['typ'] != 'branch_scope' ||
        data['mode'] != 'branch' ||
        data['sub'] != accountId ||
        data['org'] != organizationId ||
        data['branch'] != selectedBranchId ||
        (!isSeedScope(accountId, organizationId, selectedBranchId) &&
            data['qa_directory'] != true)) {
      return null;
    }
    financialCutover = data['qa_business_ledger'] == true;
    final link = data['qa_cash_link'];
    if (financialCutover && link is String && isDirectoryId(link))
      cashLinkId = link;
    if (data.containsKey('qa_writer_session')) {
      final sid = data['qa_writer_session'], exp = data['exp'];
      final peers = data['qa_transfer_branches'];
      if (!financialCutover ||
          sid is! String ||
          !isDirectoryId(sid) ||
          exp is! int ||
          exp < 0 ||
          exp > 4102444800 ||
          peers is! Map ||
          peers.length > 2 ||
          !peers.containsKey(selectedBranchId)) {
        return null;
      }
      final names = <String, String>{};
      for (final entry in peers.entries) {
        final id = entry.key, name = entry.value;
        if (id is! String || !isDirectoryId(id) || name is! String) return null;
        names[id] = name;
      }
      writerSession = sid;
      transferExpiry = DateTime.fromMillisecondsSinceEpoch(
        exp * 1000,
        isUtc: true,
      );
      transferBranches = names;
    }
  } on FormatException {
    return null;
  }
  return DirectoryAccess(
    workspace: DirectoryWorkspace(
      server: server,
      accountId: accountId,
      organizationId: organizationId!,
    ),
    branchId: selectedBranchId!,
    readable: DirectoryPartyKind.values.toSet(),
    writable: DirectoryPartyKind.values.toSet(),
    financialCutover: financialCutover,
    writerSession: writerSession,
    transferExpiry: transferExpiry,
    transferBranches: transferBranches,
    cashLinkId: cashLinkId,
  );
}

bool isSeedScope(String account, String? org, String? branch) =>
    account == DirectoryPilotBuild.accountId &&
    org == DirectoryPilotBuild.organizationId &&
    branch == DirectoryPilotBuild.branchId;

bool validDirectoryPilotScope(
  String server,
  String account,
  String? org,
  String? branch,
) =>
    DirectoryPilotBuild.enabled &&
    server == DirectoryPilotBuild.baseUrl &&
    org != null &&
    branch != null &&
    isDirectoryId(account) &&
    isDirectoryId(org) &&
    isDirectoryId(branch) &&
    (DirectoryPilotBuild.signupEnabled || isSeedScope(account, org, branch));

bool sameDirectoryScope(DirectoryAccess? a, DirectoryAccess? b) =>
    a?.workspace.storageId == b?.workspace.storageId &&
    a?.branchId == b?.branchId;

final directoryPilotStoreProvider = Provider<DirectoryPilotStore>((ref) {
  final store = DirectoryPilotStore(
    root: businessDirectoryRoot,
    keys: const SecureDirectoryKeys(),
    writerSession: (account) =>
        readBusinessCashSession(ref.read(secureStorageProvider), account),
  );
  ref.onDispose(store.close);
  ref.listen(directoryPilotAccessProvider, (before, after) {
    if (before != null && !sameDirectoryScope(before, after)) store.close();
  });
  return store;
});

/// Update the existing list's search results after editing the party details.
final directoryPartyRevisionProvider = StateProvider.autoDispose
    .family<int, DirectoryPartyKind>((ref, kind) => 0);

/// No released directory-only grant selects the financial writer. Both the
/// build opt-in and the branch cutover grant are required. Never fall back to
/// another writer for a command accepted by this source.
final businessLocalLedgerScopeProvider = Provider<DirectoryAccess?>((ref) {
  if (!const bool.fromEnvironment('FYONA_BUSINESS_LEDGER_QA')) return null;
  final scope = ref.watch(directoryPilotAccessProvider);
  return scope?.financialCutover == true ? scope : null;
});

/// The only Phase 1 UI repository. No production import and no fallback to
/// HTTP. A missing key, missing grant or failed write never creates a server row.
final class DirectoryPilotStore {
  DirectoryPilotStore({
    required Future<Directory> Function() root,
    required DirectoryKeyStore keys,
    Future<String?> Function(String account)? writerSession,
  }) : _root = root,
       _keys = keys,
       _writerSession = writerSession;

  static const _fixtureId = 'fadea5e1-fc09-4d1e-aac2-3cb16ccdf255';
  final Future<Directory> Function() _root;
  final DirectoryKeyStore _keys;
  final Future<String?> Function(String)? _writerSession;
  final Lock _lock = Lock();
  DirectoryDatabase? _db;

  Future<void> close() => _lock.synchronized(() async {
    await _db?.close();
    _db = null;
  });

  String _grantKey(DirectoryAccess scope) =>
      'grant-v1-${scope.workspace.storageId}-${scope.branchId}';

  /// Save the last *live* Business entitlement, including a denial, without
  /// changing Personal access or extending the date assigned by the server.
  Future<void> remember(
    DirectoryAccess scope,
    Map<String, dynamic> status,
  ) => _lock.synchronized(() async {
    try {
      final sections = status['sections'];
      final raw = sections is Map ? sections['business'] : null;
      final entry = raw is Map
          ? {'active': raw['active'] == true, 'end_date': raw['end_date']}
          : null;
      await _keys.write(
        _grantKey(scope),
        jsonEncode({
          'status': status['status'],
          'is_trial': status['is_trial'] == true,
          'business_setup_completed':
              status['business_setup_completed'] == true,
          'sections': {'business': entry},
        }),
      );
    } catch (_) {
      // A vault error is not a grant, and must not break working online routes.
    }
  });

  Future<Map<String, dynamic>?> entry(DirectoryAccess scope) async {
    try {
      final encoded = await _keys.read(_grantKey(scope));
      if (encoded == null) return null;
      final snapshot = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      if (!const {'active', 'trial'}.contains(snapshot['status']) ||
          !hasSectionAccess(snapshot, 'business') ||
          (snapshot['is_trial'] != true &&
              snapshot['business_setup_completed'] != true)) {
        return null;
      }
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<List<DirectoryParty>> search(
    DirectoryAccess scope,
    DirectoryPartyKind kind,
    String query,
  ) => _lock.synchronized(() async {
    final db = await _open(scope);
    return db.search(scope, kind, query);
  });

  Future<DirectoryParty> find(
    DirectoryAccess scope,
    DirectoryPartyKind kind,
    String id,
  ) => _lock.synchronized(() async {
    final db = await _open(scope);
    return db.find(scope, kind, id);
  });

  /// Device-to-device sync of this workspace. Keep each call short: the
  /// network round trips happen outside, between calls.
  Future<T> withSync<T>(
    DirectoryAccess scope,
    Future<T> Function(DirectoryDatabase db) action,
  ) => _lock.synchronized(() async => action(await _open(scope)));

  Future<T> withLedger<T>(
    BusinessLedgerAccess access,
    DirectoryAccess? Function() current,
    Future<T> Function(BusinessLedger ledger) action,
  ) => _lock.synchronized(() async {
    final expected = access.directory;
    void check() {
      final selected = current();
      if (!expected.financialCutover ||
          selected == null ||
          !selected.financialCutover ||
          !sameDirectoryScope(expected, selected))
        throw const DirectoryAccessDenied();
    }

    check();
    final db = await _open(expected);
    check();
    return action(db.ledger);
  });

  Future<void> update(
    DirectoryAccess scope,
    DirectoryPartyKind kind,
    String id, {
    String? name,
    String? phone,
    bool Function()? stillAllowed,
  }) => _lock.synchronized(() async {
    if (stillAllowed?.call() == false) throw const DirectoryAccessDenied();
    final db = await _open(scope);
    if (stillAllowed?.call() == false) throw const DirectoryAccessDenied();
    await db.update(scope, kind, id, name: name, phone: phone);
  });

  Future<List<Map<String, dynamic>>> groups(
    DirectoryAccess scope,
    DirectoryPartyReference party,
  ) => _lock.synchronized(() async {
    party.requireScope(scope);
    final db = await _open(scope);
    return db.groups(scope, party.kind, party.id);
  });

  Future<void> createGroup(
    DirectoryAccess scope,
    DirectoryPartyReference party,
    String name, {
    String? commandId,
  }) => _lock.synchronized(() async {
    party.requireScope(scope, write: true);
    final db = await _open(scope);
    await db.createGroup(
      scope,
      party.kind,
      party.id,
      name,
      commandId: commandId,
    );
  });

  Future<void> renameGroup(
    DirectoryAccess scope,
    DirectoryPartyReference party,
    String groupId,
    String name,
  ) => _lock.synchronized(() async {
    party.requireScope(scope, write: true);
    final db = await _open(scope);
    await db.renameGroup(scope, party.kind, party.id, groupId, name);
  });

  Future<DirectoryParty> add(
    DirectoryAccess scope,
    DirectoryPartyKind kind, {
    required String name,
    String? phone,
    String? id,
    bool Function()? stillAllowed,
  }) => _lock.synchronized(() async {
    if (stillAllowed?.call() == false) throw const DirectoryAccessDenied();
    final db = await _open(scope);
    if (stillAllowed?.call() == false) throw const DirectoryAccessDenied();
    return db.create(scope, kind, name: name, phone: phone, id: id);
  });

  Future<DirectoryDatabase> _open(DirectoryAccess scope) async {
    if (!validDirectoryPilotScope(
      scope.workspace.server,
      scope.workspace.accountId,
      scope.workspace.organizationId,
      scope.branchId,
    )) {
      throw const DirectoryAccessDenied();
    }
    if (await entry(scope) == null) throw const DirectoryAccessDenied();
    if (scope.writerSession != null &&
        await _writerSession?.call(scope.workspace.accountId) !=
            scope.writerSession) {
      throw const DirectoryAccessDenied();
    }
    if (_db?.workspace.storageId == scope.workspace.storageId) return _db!;
    await _db?.close();
    _db = null;
    final opened = await DirectoryDatabase.open(
      root: await _root(),
      workspace: scope.workspace,
      keys: _keys,
    );
    try {
      // Demo directory cards are not starting balances or restorable facts of
      // a new financial ledger. Do not populate a fresh recovery destination.
      // Existing cards (including edited demo cards) are never discarded.
      if (!scope.financialCutover &&
          isSeedScope(
            scope.workspace.accountId,
            scope.workspace.organizationId,
            scope.branchId,
          ) &&
          !await opened.hasFixture(scope, _fixtureId)) {
        await opened.importFixture(
          scope,
          _fixtures(scope),
          snapshotId: _fixtureId,
        );
      }
      _db = opened;
      return opened;
    } catch (_) {
      await opened.close();
      rethrow;
    }
  }

  List<DirectoryParty> _fixtures(DirectoryAccess scope) => [
    DirectoryParty(
      id: 'def27a01-e02c-4fba-b38b-ee69209a2cea',
      kind: DirectoryPartyKind.customer,
      organizationId: scope.workspace.organizationId,
      branchId: scope.branchId,
      name: 'عميل تجريبي',
      createdAt: DateTime.utc(2026, 1, 1),
    ),
    DirectoryParty(
      id: 'def27a01-e02c-4fba-b38b-ee69209a2ceb',
      kind: DirectoryPartyKind.supplier,
      organizationId: scope.workspace.organizationId,
      branchId: scope.branchId,
      name: 'مورد تجريبي',
      createdAt: DateTime.utc(2026, 1, 1),
    ),
  ];
}
