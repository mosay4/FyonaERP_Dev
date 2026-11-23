part of 'directory_database.dart';

/// Only for the socket-only cutover rehearsal. A banking projection is not a
/// full ledger import, and its receipt cannot authorize writes in the app.
extension BusinessCutoverFixtureBanking on DirectoryDatabase {
  Future<BusinessCutoverReceipt> projectFixtureBanking(
    DirectoryAccess access,
    BusinessCutoverReceipt expected,
  ) {
    BusinessCutoverFixtureArchive(this)._checkFixture(access);
    return _transaction(
      (txn) => _projectBanking(txn, access.branchId, expected),
      exclusive: true,
    );
  }

  static Future<BusinessCutoverReceipt> _projectBanking(
    Transaction txn,
    String branch,
    BusinessCutoverReceipt expected,
  ) async {
    const byBranch = 'branch_id = ?';
    final existing = await BusinessCutoverFixtureArchive._receipt(txn, branch);
    if (existing == null || existing != expected) {
      throw const BusinessCutoverImportRejected();
    }
    final previous = await txn.query(
      _bankProjections,
      where: byBranch,
      whereArgs: [branch],
    );
    if (previous.isNotEmpty) {
      if (previous.single['snapshot_id'] != expected.snapshotId ||
          previous.single['digest'] != expected.digest) {
        throw const BusinessCutoverImportRejected();
      }
      return expected;
    }
    // Import cannot merge into a branch that already has a local writer.
    for (final table in [
      BusinessLedger._accounts,
      BusinessLedger._commands,
      BusinessLedger._policy,
    ]) {
      if ((await txn.query(
        table,
        where: byBranch,
        whereArgs: [branch],
        limit: 1,
      )).isNotEmpty) {
        throw const BusinessCutoverImportRejected();
      }
    }
    final archiveRow = (await txn.query(
      BusinessCutoverFixtureArchive._receipts,
      columns: ['bank_policy'],
      where: byBranch,
      whereArgs: [branch],
    )).single;
    final policy = archiveRow['bank_policy'];
    // A v1 archive did not capture the authoritative overdraft setting.
    if (policy == null) throw const BusinessCutoverImportRejected();
    await txn.insert(BusinessLedger._policy, {
      'branch_id': branch,
      'allow_negative': policy,
    });

    final accounts = [
      for (final row in await BusinessCutoverFixtureArchive._sourceRows(
        txn,
        branch,
        'bank_accounts',
      ))
        _accountProjection(row, branch),
    ];
    final accountIds = accounts.map((row) => row['id']).toSet();
    final legs = [
      for (final row in await BusinessCutoverFixtureArchive._sourceRows(
        txn,
        branch,
        'bank_transactions',
      ))
        _legProjection(row, branch, accountIds),
    ];
    final batch = txn.batch();
    for (final account in accounts) {
      batch.insert(BusinessLedger._accounts, account);
    }
    for (final leg in legs) {
      final id = leg['command_id'];
      batch.insert(BusinessLedger._commands, {
        'branch_id': branch,
        'id': id,
        // Reserve the original identity without re-executing the movement.
        'fingerprint': 'cutover:${expected.digest}',
        'result': jsonEncode({'id': id}),
      });
      batch.insert(BusinessLedger._legs, leg);
    }
    await batch.commit(noResult: true);
    await _verifyBankProjection(
      txn,
      BusinessLedger._accounts,
      branch,
      'id',
      accounts,
    );
    await _verifyBankProjection(
      txn,
      BusinessLedger._legs,
      branch,
      'command_id',
      legs,
    );
    await txn.insert(_bankProjections, {
      'branch_id': branch,
      'snapshot_id': expected.snapshotId,
      'digest': expected.digest,
    });
    return expected;
  }

  static Map<String, Object?> _accountProjection(
    Map<String, Object?> row,
    String branch,
  ) {
    // Confirmed links are shared bank metadata and need a separate handoff.
    if (row['branch_id'] != branch || row['bank_group_key'] != null) {
      throw const BusinessCutoverImportRejected();
    }
    return {
      'branch_id': branch,
      'id': _fixtureId(row['id']),
      'bank_name': _fixtureText(row['bank_name']),
      'account_name': _fixtureText(row['account_name']),
      'account_number': _fixtureText(row['account_number']),
      'account_type': _fixtureText(row['account_type']),
      'iban': _fixtureOptionalText(row['iban']),
      'currency': _fixtureCurrency(row['currency']),
      'balance_minor': _fixtureMinor(row['balance']),
      'created_us': _fixtureTime(row['created_at']),
      'is_active': _fixtureBool(row['is_active']) ? 1 : 0,
      'closed_us': _fixtureBool(row['is_deleted'])
          ? _fixtureTime(row['deleted_at'])
          : null,
    };
  }

  static Map<String, Object?> _legProjection(
    Map<String, Object?> row,
    String branch,
    Set<Object?> accounts,
  ) {
    final accountId = _fixtureId(row['bank_account_id']);
    final amount = _fixtureMinor(row['amount']);
    final kind = _fixtureText(row['tx_type']);
    final sign = switch (kind) {
      'opening_balance' ||
      'deposit' ||
      'transfer_in' ||
      'transfer_reversal_in' ||
      'reconciliation_increase' => 1,
      'withdrawal' ||
      'transfer_out' ||
      'transfer_reversal_out' ||
      'reconciliation_decrease' => -1,
      _ => 0,
    };
    if (!accounts.contains(accountId) || amount <= 0 || sign == 0) {
      throw const BusinessCutoverImportRejected();
    }
    return {
      'branch_id': branch,
      'account_id': accountId,
      'command_id': _fixtureId(row['id']),
      'delta_minor': sign * amount,
      'balance_minor': _fixtureMinor(row['running_balance']),
      'kind': kind,
      'reference': _fixtureOptionalText(row['reference']),
      'description': _fixtureOptionalText(row['description']) ?? '',
      'currency': _fixtureCurrency(row['currency']),
      'created_us': _fixtureTime(row['date']),
      'legacy': 1,
      'hidden': _fixtureBool(row['is_deleted']) ? 1 : 0,
    };
  }

  static Future<void> _verifyBankProjection(
    Transaction txn,
    String table,
    String branch,
    String id,
    List<Map<String, Object?>> expected,
  ) async {
    final actual = await txn.query(
      table,
      columns: expected.isEmpty ? ['branch_id'] : expected.first.keys.toList(),
      where: 'branch_id = ?',
      whereArgs: [branch],
      orderBy: id,
    );
    if (actual.length != expected.length) {
      throw const BusinessCutoverImportRejected();
    }
    for (var i = 0; i < actual.length; i++) {
      if (expected[i].entries.any(
        (field) => actual[i][field.key] != field.value,
      )) {
        throw const BusinessCutoverImportRejected();
      }
    }
  }
}
