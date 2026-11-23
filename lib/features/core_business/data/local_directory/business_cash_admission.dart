part of 'directory_database.dart';

const _cashLinkPrepares = 'business_cash_link_preparations';

Future<void> _createCashLinkPrepares(DatabaseExecutor db) => db.execute('''
  CREATE TABLE $_cashLinkPrepares (
    branch_id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    currency TEXT NOT NULL,
    digest TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary', 'replica')),
    state TEXT NOT NULL CHECK (state IN ('pending', 'ready', 'canceled'))
  )
''');

Future<Map<String, Object?>?> _cashLinkRow(
  DatabaseExecutor db,
  String branch,
) async => (await db.query(
  _cashLinkPrepares,
  where: 'branch_id=?',
  whereArgs: [branch],
)).singleOrNull;

Future<void> _requireCashSlotNotReserved(
  DatabaseExecutor db,
  String branch,
  String bank,
  String currency,
) async {
  if (!_isLedgerCash(bank)) return;
  final pending = await _cashLinkRow(db, branch);
  if (pending?['state'] == 'pending' && pending?['currency'] == currency) {
    throw const BusinessLedgerError(
      BusinessLedgerProblem.sharedCashRequiresArbitration,
    );
  }
}

/// The counted till of this device, taken from its own latest completed
/// «المطابقة». Nothing is invented: the counted amount must still equal the
/// account balance and the account must be unchanged since that count.
Future<Map<String, Object>?> _measuredTill(
  BusinessLedger ledger,
  DatabaseExecutor db,
  String branch,
) async {
  final records = await db.query(
    _reconciliationRecords,
    where: "branch_id=? AND rtype='bank' AND status='checked'",
    whereArgs: [branch],
    orderBy: 'created_us DESC, id DESC',
    limit: 1,
  );
  for (final count in records) {
    final lines = _reconciliationPayload(count)['lines'] as List;
    final stamps = jsonDecode(count['snapshot'] as String) as Map;
    final found = <Map<String, Object>>[];
    for (final line in lines.whereType<Map>()) {
      if (line['status'] != 'match') continue;
      final accountId = line['account_id'] as String;
      final Map<String, Object?>? account;
      try {
        account = await ledger._account(db, branch, accountId);
      } catch (_) {
        continue;
      }
      if (account == null) continue;
      final balance = BusinessMoney.minor('${line['actual']}');
      if (!_isLedgerCash(account['bank_name'] as String? ?? '') ||
          account['currency'] != line['currency'] ||
          account['balance_minor'] != balance ||
          stamps[accountId] != await _bankStamp(db, branch, account)) {
        continue;
      }
      found.add({
        'account_id': accountId,
        'currency': line['currency'] as String,
        'balance_minor': balance,
        'check_ref': count['ref_code'] as String,
      });
    }
    if (found.length == 1) return found.single;
  }
  return null;
}

/// An authorization bound to this vault session and this already reconciled
/// resource. Nothing in this frame is a financial instruction to legacy REST.
final class BusinessCashLink {
  BusinessCashLink._(
    this.id,
    this.accountId,
    this.currency,
    this.balanceMinor,
    this.sessionId,
    this.primary,
    this.checkRef,
    this.state,
    this.checkpoint,
  );

  factory BusinessCashLink.parse(
    Map<String, Object?> data,
    DirectoryAccess scope,
    String session,
  ) {
    final id = data['id'],
        account = data['account_id'],
        currency = data['currency'],
        minor = data['balance_minor'],
        state = data['state'],
        role = data['role'],
        ref = data['check_ref'],
        raw = data['checkpoint'];
    final Map? checkpoint = raw is Map ? raw : null;
    if (id is! String ||
        id != scope.cashLinkId ||
        data['organization_id'] != scope.workspace.organizationId ||
        data['actor_id'] != scope.workspace.accountId ||
        data['branch_id'] != scope.branchId ||
        data['session_id'] != session ||
        state is! String ||
        !const {'pending', 'ready', 'canceled'}.contains(state) ||
        !const {'primary', 'replica'}.contains(role) ||
        (account == null &&
            (currency != null ||
                minor != null ||
                checkpoint != null ||
                state != 'pending')) ||
        (account != null &&
            (account is! String ||
                !isDirectoryId(account) ||
                account != account.toLowerCase() ||
                currency is! String ||
                businessCurrency(currency) != currency ||
                minor is! int ||
                minor < 0 ||
                minor > BusinessMoney.maxMinor ||
                checkpoint == null ||
                checkpoint['sequence'] is! int ||
                (checkpoint['sequence'] as int) < 0 ||
                checkpoint['digest'] !=
                    _digest(
                      scope,
                      account as String,
                      currency as String,
                      minor as int,
                      checkpoint['sequence'] as int,
                    )))) {
      throw const DirectoryAccessDenied();
    }
    if (role == 'primary' &&
        account != null &&
        (ref is! String ||
            !RegExp(r'^RCN-[0-9]{8}-[A-F0-9]{8}$').hasMatch(ref))) {
      throw const DirectoryAccessDenied();
    }
    if (role == 'replica' && ref != null) throw const DirectoryAccessDenied();
    return BusinessCashLink._(
      id,
      account as String?,
      currency as String?,
      minor as int?,
      session,
      role == 'primary',
      ref as String?,
      state,
      checkpoint == null
          ? null
          : (
              sequence: checkpoint['sequence'] as int,
              digest: checkpoint['digest'] as String,
            ),
    );
  }

  static String _digest(
    DirectoryAccess scope,
    String account,
    String currency,
    int amount, [
    int sequence = 0,
  ]) => _reconDigest([
    'fyona.cash.checkpoint.v2',
    scope.workspace.organizationId,
    scope.branchId,
    sequence,
    [
      [account, currency, amount, false],
    ],
  ]);

  /// This device counted the cash itself. The facts come from its own
  /// reconciliation, never from a request body or a shared total.
  BusinessCashLink _measured(DirectoryAccess scope, Map<String, Object> facts) {
    final account = facts['account_id'] as String,
        currency = facts['currency'] as String,
        amount = facts['balance_minor'] as int;
    return BusinessCashLink._(
      id,
      account,
      currency,
      amount,
      sessionId,
      true,
      facts['check_ref'] as String,
      state,
      (sequence: 0, digest: _digest(scope, account, currency, amount)),
    );
  }

  BusinessCashLink _identified(DirectoryAccess scope, String account) =>
      BusinessCashLink._(
        id,
        account,
        currency!,
        balanceMinor!,
        sessionId,
        primary,
        checkRef,
        state,
        (
          sequence: 0,
          digest: _digest(scope, account, currency!, balanceMinor!),
        ),
      );

  final String id, sessionId, state;
  final String? currency, checkRef, accountId;
  final int? balanceMinor;
  final bool primary;
  final BusinessCashCheckpoint? checkpoint;

  /// The reservation receipt. A reporting till holder also sends the counted
  /// facts so the authority can hand the very same numbers to other devices.
  Map<String, Object?>? get receipt => accountId == null
      ? null
      : {
          'id': id,
          'account_id': accountId,
          'digest': checkpoint!.digest,
          if (primary && currency != null) ...{
            'currency': currency,
            'balance_minor': balanceMinor,
            'check_ref': checkRef,
          },
        };

  bool _matches(Map<String, Object?>? record) =>
      record?['plan_id'] == id &&
      record?['session_id'] == sessionId &&
      (accountId == null || record?['account_id'] == accountId) &&
      (currency == null || record?['currency'] == currency) &&
      (checkpoint == null || record?['digest'] == checkpoint!.digest) &&
      record?['role'] == (primary ? 'primary' : 'replica');
}

extension BusinessCashAdmission on BusinessCashSync {
  /// Returns only after the local reservation, cancellation or binding commits.
  /// No network or arbitrary balance import ever runs inside this transaction.
  Future<Map<String, Object?>?> reconcileLink(
    BusinessLedgerAccess access,
    BusinessCashLink link, {
    required bool Function() allowed,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    void check() {
      if (!allowed() ||
          access.directory.cashLinkId != link.id ||
          access.cashSessionId != link.sessionId)
        throw const DirectoryAccessDenied();
    }

    Future<void> requirePrivateReplicaSlot(Transaction txn) async {
      final existing = await txn.rawQuery(
        '''
        SELECT id FROM ${BusinessLedger._accounts}
        WHERE branch_id=? AND (id=? OR (currency=? AND trim(bank_name) IN (?, ?, ?)))
        LIMIT 1
      ''',
        [branch, link.accountId, link.currency, ..._ledgerCashNames],
      );
      if (existing.isNotEmpty) throw const DirectoryAccessDenied();
    }

    Future<void> installConfig(Transaction txn, String account) =>
        txn.insert(BusinessCashSync._accounts, {
          'branch_id': branch,
          'account_id': account,
          'grant_version': 1,
          'allow_negative': 0,
        });

    return _db._transaction((txn) async {
      check();
      final existing = await _cashLinkRow(txn, branch);
      if (existing != null && !link._matches(existing)) {
        throw const DirectoryAccessDenied();
      }
      if (await _isRecoveredLedger(txn, branch))
        throw const DirectoryAccessDenied();
      if (link.state == 'canceled') {
        if (existing?['state'] != 'pending') return null;
        if (await _binding(txn, branch) != null)
          throw const DirectoryAccessDenied();
        if (link.primary) {
          await txn.delete(
            BusinessCashSync._accounts,
            where: 'branch_id=? AND account_id=?',
            whereArgs: [branch, existing!['account_id']],
          );
        }
        await txn.update(
          _cashLinkPrepares,
          {'state': 'canceled'},
          where: 'branch_id=?',
          whereArgs: [branch],
        );
      } else if (link.state == 'pending') {
        if (existing != null) {
          if (existing['state'] != 'pending')
            throw const DirectoryAccessDenied();
          if (link.primary && link.accountId == null) {
            // The earlier report was lost in transit: this device still holds
            // the same counted till, so it reports those facts again.
            final again = await _measuredTill(_ledger, txn, branch);
            if (again != null) {
              return link._measured(access.directory, again).receipt;
            }
          }
          return {
            'id': link.id,
            'account_id': existing['account_id'],
            'digest': existing['digest'],
            if (link.primary && link.currency != null) ...{
              'currency': link.currency,
              'balance_minor': link.balanceMinor,
              'check_ref': link.checkRef,
            },
          };
        }
        if (await _binding(txn, branch) != null ||
            (await txn.query(
              BusinessCashSync._accounts,
              where: 'branch_id=?',
              whereArgs: [branch],
              limit: 1,
            )).isNotEmpty)
          throw const DirectoryAccessDenied();
        if (link.accountId == null) {
          // Nothing counted on this device yet: wait for the till holder
          // instead of inventing an opening fact.
          final measured = await _measuredTill(_ledger, txn, branch);
          if (measured == null) return null;
          final reporting = link._measured(access.directory, measured);
          await installConfig(txn, reporting.accountId!);
          await txn.insert(_cashLinkPrepares, {
            'branch_id': branch,
            'plan_id': reporting.id,
            'session_id': reporting.sessionId,
            'account_id': reporting.accountId,
            'currency': reporting.currency,
            'digest': reporting.checkpoint!.digest,
            'role': 'primary',
            'state': 'pending',
          });
          check();
          return reporting.receipt;
        }
        BusinessCashLink identified = link;
        if (link.primary) {
          final count = (await txn.query(
            _reconciliationRecords,
            where:
                "branch_id=? AND rtype='bank' AND status='checked' AND ref_code=?",
            whereArgs: [branch, link.checkRef],
          )).singleOrNull;
          if (count == null) throw const DirectoryAccessDenied();
          final lines = _reconciliationPayload(count)['lines'] as List;
          final stamps = jsonDecode(count['snapshot'] as String) as Map;
          final matching = lines
              .whereType<Map>()
              .where(
                (r) =>
                    r['currency'] == link.currency &&
                    r['status'] == 'match' &&
                    BusinessMoney.minor('${r['actual']}') == link.balanceMinor,
              )
              .toList();
          if (matching.length != 1) throw const DirectoryAccessDenied();
          final accountId = matching.single['account_id'] as String;
          final account = await _ledger._account(txn, branch, accountId);
          if ((link.accountId != null && link.accountId != accountId) ||
              !_isLedgerCash(account['bank_name'] as String) ||
              account['currency'] != link.currency ||
              account['balance_minor'] != link.balanceMinor ||
              stamps[accountId] != await _bankStamp(txn, branch, account)) {
            throw const DirectoryAccessDenied();
          }
          identified = link._identified(access.directory, accountId);
          // This configuration blocks all local writes to the measured cash
          // until the reservations have been admitted.
          await installConfig(txn, accountId);
        } else {
          await requirePrivateReplicaSlot(txn);
        }
        await txn.insert(_cashLinkPrepares, {
          'branch_id': branch,
          'plan_id': identified.id,
          'session_id': identified.sessionId,
          'account_id': identified.accountId,
          'currency': identified.currency,
          'digest': identified.checkpoint!.digest,
          'role': identified.primary ? 'primary' : 'replica',
          'state': 'pending',
        });
        check();
        return identified.receipt;
      } else {
        if (existing?['state'] == 'ready') return null;
        if (existing?['state'] != 'pending')
          throw const DirectoryAccessDenied();
        if (!link.primary) {
          await requirePrivateReplicaSlot(txn);
          final now = DateTime.now().toUtc();
          final marker = const Uuid().v5(link.id, 'fyona.cash.link.opening.v1');
          await txn.insert(BusinessLedger._accounts, {
            'branch_id': branch,
            'id': link.accountId,
            'currency': link.currency,
            'bank_name': 'كاش',
            'account_name': 'حساب الكاش',
            'account_number': 'CASH',
            'account_type': 'checking',
            'balance_minor': link.balanceMinor,
            'created_us': now.microsecondsSinceEpoch,
          });
          await installConfig(txn, link.accountId!);
          await BusinessCashSync._writeMarker(txn, branch, marker, [
            'cash_checkpoint',
            link.id,
          ]);
          if (link.balanceMinor != 0) {
            await _ledger._leg(
              txn,
              branch,
              marker,
              link.accountId!,
              now,
              kind: 'opening_balance',
              delta: link.balanceMinor!,
              balance: link.balanceMinor!,
              description: 'رصيد افتتاحي',
            );
          }
        }
        await _bindInside(
          txn,
          access,
          branch,
          link.sessionId,
          link.checkpoint!,
          true,
        );
        await txn.update(
          _cashLinkPrepares,
          {'state': 'ready'},
          where: 'branch_id=?',
          whereArgs: [branch],
        );
      }
      check();
      return null;
    }, exclusive: true);
  }
}
