part of 'directory_database.dart';

const _partyShares = 'business_local_party_shares';

Future<void> _createBusinessPartyShares(DatabaseExecutor db) => db.execute('''
  CREATE TABLE $_partyShares (
    branch_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    party_id TEXT NOT NULL,
    party_key TEXT NOT NULL UNIQUE,
    status_json TEXT,
    snapshot_hash TEXT,
    PRIMARY KEY (branch_id, kind, party_id),
    FOREIGN KEY (branch_id, kind, party_id)
      REFERENCES ${DirectoryDatabase._table} (branch_id, kind, id)
  )
''');

extension BusinessPartyShares on BusinessLedger {
  Future<String> trackShare(
    BusinessLedgerAccess access,
    DirectoryPartyReference party,
  ) {
    final branch = _branch(access, BusinessLedgerAction.sharePartyDebt);
    party.requireScope(access.directory, write: true);
    return _directory._transaction((txn) async {
      if (await _syncFrozen(txn, branch)) {
        throw const DirectoryAccessDenied();
      }
      await _directory._scopedParty(
        txn,
        access.directory,
        party.kind,
        party.id,
      );
      final key = const Uuid().v4();
      await txn.insert(_partyShares, {
        'branch_id': branch,
        'kind': party.kind.name,
        'party_id': party.id,
        'party_key': key,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final rows = await txn.query(
        _partyShares,
        columns: ['party_key'],
        where: 'branch_id = ? AND kind = ? AND party_id = ?',
        whereArgs: [branch, party.kind.name, party.id],
      );
      return rows.single['party_key'] as String;
    }, exclusive: true);
  }

  Future<List<Map<String, Object?>>> trackedShares(
    BusinessLedgerAccess access, {
    DirectoryPartyReference? party,
    bool forTransport = false,
  }) {
    final branch = _branch(access, BusinessLedgerAction.sharePartyDebt);
    party?.requireScope(access.directory);
    return _directory._read((db) async {
      if (forTransport && await _syncFrozen(db, branch)) return [];
      return db.rawQuery(
        '''
      SELECT s.*, d.deleted_us
      FROM $_partyShares s LEFT JOIN ${DirectoryDatabase._deleted} d
        ON d.branch_id = s.branch_id AND d.kind = s.kind AND d.party_id = s.party_id
      WHERE s.branch_id = ?
      ${party == null ? '' : 'AND s.kind = ? AND s.party_id = ?'}
      ORDER BY s.kind, s.party_id
    ''',
        [branch, ?party?.kind.name, ?party?.id],
      );
    });
  }

  Future<bool> saveShareStatus(
    BusinessLedgerAccess access,
    String opaqueKey,
    Map<String, dynamic> status,
    String? snapshotHash,
  ) async {
    final branch = _branch(access, BusinessLedgerAction.sharePartyDebt);
    final json = jsonEncode(status);
    final changed = await _directory._transaction(
      (db) => db.rawUpdate(
        '''
      UPDATE $_partyShares SET status_json = ?, snapshot_hash = ?
      WHERE branch_id = ? AND party_key = ?
        AND (status_json IS NOT ? OR snapshot_hash IS NOT ?)
    ''',
        [json, snapshotHash, branch, opaqueKey, json, snapshotHash],
      ),
    );
    return changed > 0;
  }
}
