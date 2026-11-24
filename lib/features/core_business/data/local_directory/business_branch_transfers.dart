part of 'directory_database.dart';

// Cross-branch transfers on the local store. Both branches' rows live in the
// same database, so each side of a transfer is one row of the same command and
// both sides commit together or not at all. Nothing here calls any connected
// writer, and a branch missing from this store is never guessed at.
const _branchTransfers = 'business_branch_transfers';
const _branchTransferLines = 'business_branch_transfer_lines';

Future<void> _createBusinessBranchTransfers(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_branchTransfers (
      branch_id TEXT NOT NULL,
      id TEXT NOT NULL,
      side TEXT NOT NULL CHECK (side IN ('out', 'in')),
      kind TEXT NOT NULL CHECK (kind IN ('financial', 'inventory')),
      peer_branch TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('done', 'reversed')),
      reversal_of TEXT,
      account_id TEXT,
      amount_minor INTEGER,
      currency TEXT,
      notes TEXT,
      created_us INTEGER NOT NULL,
      reversed_us INTEGER,
      PRIMARY KEY (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_branchTransferLines (
      branch_id TEXT NOT NULL,
      transfer_id TEXT NOT NULL,
      item_index INTEGER NOT NULL,
      product_id TEXT NOT NULL,
      unit_id TEXT,
      quantity_micro INTEGER NOT NULL CHECK (quantity_micro > 0),
      kind TEXT NOT NULL CHECK (kind IN ('issue', 'receipt')),
      allocations TEXT NOT NULL,
      PRIMARY KEY (branch_id, transfer_id, item_index),
      FOREIGN KEY (branch_id, transfer_id)
        REFERENCES $_branchTransfers (branch_id, id)
    )
  ''');
}

/// One stock line of a transfer, in the source unit. The device store keeps
/// quantities to 0.000001 and refuses anything that would need rounding.
final class BusinessStockTransferLine {
  const BusinessStockTransferLine({
    required this.fromProduct,
    required this.quantityMicro,
    this.toProduct,
    this.fromUnit,
    this.toUnit,
    this.conversionFactor4,
  });

  final String fromProduct;
  final String? toProduct;
  final String? fromUnit;
  final String? toUnit;
  final int quantityMicro;
  final int? conversionFactor4;
}

extension BusinessBranchTransfers on BusinessLedger {
  bool _validBranchPair(String acting, String fromBranch, String toBranch) =>
      fromBranch != toBranch &&
      isDirectoryId(fromBranch) &&
      isDirectoryId(toBranch) &&
      (acting == fromBranch || acting == toBranch);

  Future<void> _requireLocalBranch(
    DatabaseExecutor db,
    String branch, {
    DirectoryAccess? authorized,
  }) async {
    if (authorized?.financialCutover == true &&
        authorized!.transferBranches.containsKey(branch))
      return;
    for (final table in [
      _commerceBranches,
      _commerceProducts,
      BusinessLedger._accounts,
    ]) {
      final known = await db.query(
        table,
        columns: ['branch_id'],
        where: 'branch_id = ?',
        whereArgs: [branch],
        limit: 1,
      );
      if (known.isNotEmpty) return;
    }
    // This branch's records are not on this device; touching it here would
    // split its data between two places.
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
  }

  Future<void> _requirePeerPresence(
    DatabaseExecutor db,
    String fromBranch,
    String toBranch,
    DirectoryAccess authorized,
  ) async {
    for (final branch in [fromBranch, toBranch]) {
      if (authorized.writerSession != null &&
          !authorized.transferBranches.containsKey(branch)) {
        throw const DirectoryAccessDenied();
      }
      await _requireLocalBranch(db, branch, authorized: authorized);
    }
  }

  /// Moves money between two branches' accounts in one transaction. A shared
  /// till is never moved directly; it settles through the cash arbitration.
  Future<Map<String, Object?>> transferBetweenBranches(
    BusinessLedgerAccess access, {
    required String commandId,
    required String fromBranch,
    required String toBranch,
    required String fromAccountId,
    required String toAccountId,
    required int amountMinor,
    BusinessRate? rate,
    String? notes,
    bool Function()? allowed,
    Map<String, Object?>? actor,
  }) async {
    final acting = _branch(access, BusinessLedgerAction.transfer);
    if (!_validBranchPair(acting, fromBranch, toBranch)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
    }
    if (fromAccountId == toAccountId) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
    }
    BusinessLedger._amount(amountMinor);
    final note = DirectoryDatabase._optional(notes);
    return _commit(
      acting,
      commandId,
      [
        'branch_transfer',
        fromBranch,
        toBranch,
        fromAccountId,
        toAccountId,
        amountMinor,
        rate?.from,
        rate?.to,
        rate?.decimal,
        note,
      ],
      (txn, now) async {
        await _requirePeerPresence(txn, fromBranch, toBranch, access.directory);
        final source = await _account(txn, fromBranch, fromAccountId);
        final target = await _account(txn, toBranch, toAccountId);
        await cashSync._requirePrivate(txn, fromBranch, fromAccountId);
        await cashSync._requirePrivate(txn, toBranch, toAccountId);
        final from = source['currency'] as String;
        final to = target['currency'] as String;
        final credit = BusinessLedger._convert(
          amountMinor,
          from,
          to,
          rate,
          halfEven: false,
        );
        BusinessLedger._amount(credit);
        final debitBalance = BusinessLedger._balance(source, -amountMinor);
        if (debitBalance < 0) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.insufficientBalance,
          );
        }
        final creditBalance = BusinessLedger._balance(target, credit);
        final shown = note == null || note.isEmpty ? 'تحويل بين الفروع' : note;
        await _post(
          txn,
          fromBranch,
          commandId,
          fromAccountId,
          now,
          kind: 'transfer_out',
          delta: -amountMinor,
          next: debitBalance,
          description: 'تحويل إلى ${target['account_name']}: $shown',
          rate: rate,
        );
        await _post(
          txn,
          toBranch,
          commandId,
          toAccountId,
          now,
          kind: 'transfer_in',
          delta: credit,
          next: creditBalance,
          description: 'تحويل من ${source['account_name']}: $shown',
          rate: rate,
        );
        for (final (branch, side, account, amount, currency) in [
          (fromBranch, 'out', fromAccountId, -amountMinor, from),
          (toBranch, 'in', toAccountId, credit, to),
        ]) {
          await txn.insert(_branchTransfers, {
            'branch_id': branch,
            'id': commandId,
            'side': side,
            'kind': 'financial',
            'peer_branch': branch == fromBranch ? toBranch : fromBranch,
            'status': 'done',
            'reversal_of': null,
            'account_id': account,
            'amount_minor': amount,
            'currency': currency,
            'notes': note,
            'created_us': now.microsecondsSinceEpoch,
          });
        }
        return {
          'id': commandId,
          'kind': 'financial',
          'from_branch': fromBranch,
          'to_branch': toBranch,
          'amount_minor': -amountMinor,
          'credit_minor': credit,
          'from_currency': from,
          'to_currency': to,
          'notes': note,
          'rate': from == to ? null : rate?.decimal,
          'actor': ?actor,
        };
      },
      allowed: allowed,
      mirrorBranches: [fromBranch, toBranch],
    );
  }

  Future<Map<String, Object?>> _transferRow(
    DatabaseExecutor db,
    String branch,
    String id,
  ) async {
    final rows = await db.query(
      _branchTransfers,
      where: 'branch_id = ? AND id = ?',
      whereArgs: [branch, id],
    );
    return rows.isEmpty ? {} : Map<String, Object?>.from(rows.single);
  }

  /// Undoes a transfer: money comes back exactly as it left, and a stock
  /// transfer returns the very slices it took. A slice already consumed at
  /// the destination cannot be recalled.
  Future<Map<String, Object?>> reverseBranchTransfer(
    BusinessLedgerAccess access, {
    required String commandId,
    required String transferId,
    bool Function()? allowed,
    Set<String>? peers,
    Set<String>? kinds,
  }) async {
    final acting = _branch(access, BusinessLedgerAction.transfer);
    if (!isDirectoryId(transferId) || transferId == commandId) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
    }
    final peer = await _directory._read((db) async {
      final row = await db.query(
        _branchTransfers,
        columns: ['peer_branch'],
        where: 'branch_id = ? AND id = ?',
        whereArgs: [acting, transferId],
      );
      return row.isEmpty ? null : row.single['peer_branch'] as String;
    });
    return _commit(
      acting,
      commandId,
      ['branch_transfer_reversal', transferId],
      (txn, now) async {
        final mine = await _transferRow(txn, acting, transferId);
        if (mine.isEmpty ||
            mine['status'] != 'done' ||
            mine['reversal_of'] != null ||
            (peers != null && !peers.contains(mine['peer_branch'])) ||
            (kinds != null && !kinds.contains(mine['kind']))) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.invalidTransfer,
          );
        }
        final peer = mine['peer_branch'] as String;
        final other = await _transferRow(txn, peer, transferId);
        if (other.isEmpty ||
            other['status'] != 'done' ||
            other['peer_branch'] != acting) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.invalidTransfer,
          );
        }
        final fromBranch = mine['side'] == 'out' ? acting : peer;
        final toBranch = mine['side'] == 'out' ? peer : acting;
        final note = mine['notes'] as String?;
        final out = mine['side'] == 'out' ? mine : other;
        final inn = mine['side'] == 'out' ? other : mine;
        if (mine['kind'] == 'financial') {
          final source = await _account(
            txn,
            fromBranch,
            out['account_id'] as String,
          );
          final target = await _account(
            txn,
            toBranch,
            inn['account_id'] as String,
          );
          await cashSync._requirePrivate(
            txn,
            fromBranch,
            out['account_id'] as String,
          );
          await cashSync._requirePrivate(
            txn,
            toBranch,
            inn['account_id'] as String,
          );
          final back = -(out['amount_minor'] as int);
          final take = inn['amount_minor'] as int;
          final targetBalance = BusinessLedger._balance(target, -take);
          if (targetBalance < 0) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.insufficientBalance,
            );
          }
          await _post(
            txn,
            fromBranch,
            commandId,
            out['account_id'] as String,
            now,
            kind: 'transfer_reversal_in',
            delta: back,
            next: BusinessLedger._balance(source, back),
            description: 'إلغاء تحويل من ${target['account_name']}',
          );
          await _post(
            txn,
            toBranch,
            commandId,
            inn['account_id'] as String,
            now,
            kind: 'transfer_reversal_out',
            delta: -take,
            next: targetBalance,
            description: 'إلغاء تحويل إلى ${source['account_name']}',
          );
        } else {
          await reverseStockSlices(
            txn,
            commandId,
            transferId,
            fromBranch: fromBranch,
            toBranch: toBranch,
            actor: access.directory.workspace.accountId,
            now: now,
          );
        }
        for (final (branch, side) in [(fromBranch, 'out'), (toBranch, 'in')]) {
          await txn.update(
            _branchTransfers,
            {'status': 'reversed', 'reversed_us': now.microsecondsSinceEpoch},
            where: 'branch_id = ? AND id = ?',
            whereArgs: [branch, transferId],
          );
          await txn.insert(_branchTransfers, {
            'branch_id': branch,
            'id': commandId,
            'side': side,
            'kind': mine['kind'],
            'peer_branch': branch == fromBranch ? toBranch : fromBranch,
            'status': 'done',
            'reversal_of': transferId,
            'account_id': mine['kind'] == 'financial'
                ? (side == 'out' ? out['account_id'] : inn['account_id'])
                : null,
            'amount_minor': mine['kind'] == 'financial'
                ? -(side == 'out'
                      ? out['amount_minor'] as int
                      : inn['amount_minor'] as int)
                : null,
            'currency': side == 'out' ? out['currency'] : inn['currency'],
            'notes': note,
            'created_us': now.microsecondsSinceEpoch,
          });
        }
        return {
          'id': commandId,
          'reversal_of': transferId,
          'kind': mine['kind'],
          'from_branch': fromBranch,
          'to_branch': toBranch,
        };
      },
      allowed: allowed,
      mirrorBranches: [if (peer != null) peer],
    );
  }

  /// Transfers of the acting branch, newest first. The peer side is merged
  /// for names and amounts; a branch outside this store never appears.
  Future<List<Map<String, Object?>>> branchTransfers(
    BusinessLedgerAccess access, {
    String? kind,
    Set<String>? peers,
    bool everyBranch = false,
  }) async {
    final current = _branch(access, BusinessLedgerAction.transfer);
    return _directory._read((db) async {
      // The owner sees the organization's transfers from any branch: each
      // transfer once, from its sending side. Others see their branch's.
      final rows = everyBranch
          ? await db.query(
              _branchTransfers,
              where:
                  "side = 'out' AND reversal_of IS NULL"
                  '${kind == null ? '' : ' AND kind = ?'}',
              whereArgs: [if (kind != null) kind],
              orderBy: 'created_us DESC, id',
              limit: 200,
            )
          : await db.query(
              _branchTransfers,
              where:
                  'branch_id = ? AND reversal_of IS NULL'
                  '${kind == null ? '' : ' AND kind = ?'}',
              whereArgs: [current, if (kind != null) kind],
              orderBy: 'created_us DESC, id',
              limit: 100,
            );
      final out = <Map<String, Object?>>[];
      for (final row in rows) {
        final acting = row['branch_id'] as String;
        if (peers != null &&
            (!peers.contains(row['peer_branch']) ||
                (everyBranch && !peers.contains(acting)))) {
          continue;
        }
        final peer = await _transferRow(
          db,
          row['peer_branch'] as String,
          row['id'] as String,
        );
        final mine = Map<String, Object?>.from(row);
        final isOut = mine['side'] == 'out';
        out.add({
          'id': mine['id'],
          'number': mine['id'],
          'kind': mine['kind'],
          'status': mine['status'],
          'can_reverse': mine['status'] == 'done' &&
              (acting == current || mine['peer_branch'] == current),
          'notes': mine['notes'],
          'from_branch': isOut ? acting : mine['peer_branch'],
          'to_branch': isOut ? mine['peer_branch'] : acting,
          'from_branch_name':
              await _branchName(
                db,
                isOut ? acting : mine['peer_branch'] as String,
              ) ??
              access.directory.transferBranches[isOut
                  ? acting
                  : mine['peer_branch']],
          'to_branch_name':
              await _branchName(
                db,
                isOut ? mine['peer_branch'] as String : acting,
              ) ??
              access.directory.transferBranches[isOut
                  ? mine['peer_branch']
                  : acting],
          'amount': _transferMoney(
            isOut ? mine['amount_minor'] : peer['amount_minor'],
          ),
          'currency': isOut ? mine['currency'] : peer['currency'],
          'received_amount': _transferMoney(
            isOut ? peer['amount_minor'] : mine['amount_minor'],
          ),
          'to_currency': isOut ? peer['currency'] : mine['currency'],
          'created_us': mine['created_us'],
          'created_at': _transferDate(mine),
          'reversal_of_id': mine['reversal_of'],
          if (mine['kind'] == 'inventory')
            'items': [
              for (final _ in await db.query(
                _branchTransferLines,
                columns: ['item_index'],
                where: 'branch_id = ? AND transfer_id = ?',
                whereArgs: [acting, mine['id']],
              ))
                const <String, Object?>{},
            ],
          ...await _transferExtras(db, acting, mine, peer),
        });
      }
      return out;
    });
  }

  Future<String?> _branchName(DatabaseExecutor db, String branch) async =>
      (await db.query(
            _commerceBranches,
            columns: ['name'],
            where: 'branch_id = ?',
            whereArgs: [branch],
            limit: 1,
          )).singleOrNull?['name']
          as String?;

  /// The branches this device keeps records for, with their local names.
  Future<Map<String, String>> localBranchNames(
    BusinessLedgerAccess access,
  ) async {
    _branch(access, BusinessLedgerAction.transfer);
    return _directory._read((db) async {
      final out = <String, String>{};
      for (final table in [
        _commerceBranches,
        _commerceProducts,
        BusinessLedger._accounts,
      ]) {
        final rows = await db.query(table, columns: ['branch_id']);
        for (final row in rows) {
          out.putIfAbsent('${row['branch_id']}', () => '');
        }
      }
      for (final row in await db.query(
        _commerceBranches,
        columns: ['branch_id', 'name'],
      )) {
        out['${row['branch_id']}'] = '${row['name']}';
      }
      return out;
    });
  }

  /// One transfer with its stock lines, in the shape the transfers screen
  /// already displays.
  Future<Map<String, Object?>> branchTransferDetail(
    BusinessLedgerAccess access,
    String id, {
    Set<String>? peers,
    bool everyBranch = false,
  }) async {
    final current = _branch(access, BusinessLedgerAction.transfer);
    return _directory._read((db) async {
      var acting = current;
      var mine = await _transferRow(db, acting, id);
      if (mine.isEmpty && everyBranch) {
        // Another branch's transfer, opened by the owner from this branch.
        final sender = (await db.query(
          _branchTransfers,
          where: "id = ? AND side = 'out'",
          whereArgs: [id],
          limit: 1,
        )).singleOrNull;
        if (sender != null &&
            (peers == null || peers.contains(sender['branch_id']))) {
          acting = sender['branch_id'] as String;
          mine = Map<String, Object?>.from(sender);
        }
      }
      if (mine.isEmpty ||
          (peers != null && !peers.contains(mine['peer_branch']))) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
      }
      final peer = await _transferRow(db, mine['peer_branch'] as String, id);
      final rows = await db.query(
        _branchTransferLines,
        where: 'branch_id = ? AND transfer_id = ?',
        whereArgs: [acting, id],
        orderBy: 'item_index',
      );
      final isOut = mine['side'] == 'out';
      final source = isOut ? acting : mine['peer_branch'] as String;
      final target = isOut ? mine['peer_branch'] as String : acting;
      Future<Map<String, Object?>?> productOf(String branch, Object? id) async =>
          (await db.query(
            _commerceProducts,
            columns: ['name', 'image', 'price_minor'],
            where: 'branch_id = ? AND id = ?',
            whereArgs: [branch, id],
            limit: 1,
          )).singleOrNull;
      final items = <Map<String, Object?>>[];
      var totalCost4 = BigInt.zero;
      final currencies = <String>{};
      for (final row in rows) {
        // The issue (source) line describes what left; the receipt line names
        // the product it became at the destination.
        final issue = row['kind'] == 'issue'
            ? row
            : (await db.query(
                _branchTransferLines,
                where: 'branch_id = ? AND transfer_id = ? AND item_index = ?',
                whereArgs: [source, id, row['item_index']],
              )).singleOrNull ?? row;
        final receipt = row['kind'] == 'receipt'
            ? row
            : (await db.query(
                _branchTransferLines,
                where: 'branch_id = ? AND transfer_id = ? AND item_index = ?',
                whereArgs: [target, id, row['item_index']],
              )).singleOrNull;
        // Issue lines are kept in the source branch.
        final issueBranch = issue['kind'] == 'issue' ? source : acting;
        final product = await productOf(issueBranch, issue['product_id']);
        final targetProduct = receipt == null
            ? null
            : await productOf(target, receipt['product_id']);
        final unit = issue['unit_id'] == null
            ? null
            : (await db.query(
                _commerceUnits,
                columns: ['name', 'factor_4'],
                where: 'branch_id = ? AND id = ?',
                whereArgs: [issueBranch, issue['unit_id']],
                limit: 1,
              )).singleOrNull;
        final factor4 = unit?['factor_4'] as int? ?? 10000;
        final baseMicro = issue['quantity_micro'] as int;
        final allocations =
            (jsonDecode(issue['allocations'] as String) as List).whereType<Map>();
        var cost4 = BigInt.zero; // base-unit micro × unit cost (4 places)
        var costed = 0;
        final lineCurrencies = <String>{};
        for (final slice in allocations) {
          final micro = (slice['issue_micro'] ?? slice['quantity_micro']) as int? ?? 0;
          final unitCost = slice['unit_cost_4'] as int?;
          final currency = slice['currency'] as String?;
          if (unitCost == null || currency == null) continue;
          cost4 += BigInt.from(micro) * BigInt.from(unitCost);
          costed += micro;
          lineCurrencies.add(currency);
        }
        currencies.addAll(lineCurrencies);
        totalCost4 += cost4;
        double money(BigInt microTimesCost4) =>
            microTimesCost4.toDouble() / 1000000.0 / 10000.0;
        items.add({
          'product_id': issue['product_id'],
          'from_product_name': product?['name'],
          'from_product_image': product?['image'],
          'to_product_name': targetProduct?['name'],
          // Shown in the unit it was sent in; prices are per base unit (the
          // screen multiplies them by the unit factor).
          'from_quantity': baseMicro / 1000000.0 / (factor4 / 10000.0),
          'quantity': baseMicro / 1000000.0 / (factor4 / 10000.0),
          'unit_name': unit?['name'],
          'conversion_factor': factor4 / 10000.0,
          'unit_cost': costed == 0 ? null : money(cost4) / (costed / 1000000.0),
          'sale_price': ((product?['price_minor'] as int?) ?? 0) / 100.0,
          'total_cost': money(cost4),
          'currency': lineCurrencies.length == 1
              ? lineCurrencies.single
              : lineCurrencies.isEmpty
              ? null
              : 'MIXED',
          'allocations': allocations.toList(),
        });
      }
      return {
        'id': id,
        'number': id,
        'kind': mine['kind'],
        'status': mine['status'],
        'can_reverse': mine['status'] == 'done' &&
            (acting == current || mine['peer_branch'] == current),
        'notes': mine['notes'],
        'from_branch': isOut ? acting : mine['peer_branch'],
        'to_branch': isOut ? mine['peer_branch'] : acting,
        'from_branch_name':
            await _branchName(
              db,
              isOut ? acting : mine['peer_branch'] as String,
            ) ??
            access.directory.transferBranches[isOut
                ? acting
                : mine['peer_branch']],
        'to_branch_name':
            await _branchName(
              db,
              isOut ? mine['peer_branch'] as String : acting,
            ) ??
            access.directory.transferBranches[isOut
                ? mine['peer_branch']
                : acting],
        'amount': _transferMoney(
          isOut ? mine['amount_minor'] : peer['amount_minor'],
        ),
        'currency': isOut ? mine['currency'] : peer['currency'],
        'received_amount': _transferMoney(
          isOut ? peer['amount_minor'] : mine['amount_minor'],
        ),
        'to_currency': isOut ? peer['currency'] : mine['currency'],
        'items': items,
        if (mine['kind'] == 'inventory') ...{
          'total_cost': totalCost4.toDouble() / 1000000.0 / 10000.0,
          if (currencies.isNotEmpty)
            'currency': currencies.length == 1 ? currencies.single : 'MIXED',
        },
        'created_at': _transferDate(mine),
        'reversal_of_id': mine['reversal_of'],
        ...await _transferExtras(db, acting, mine, peer),
      };
    });
  }

  Future<List<Map<String, Object?>>> transferAccounts(
    BusinessLedgerAccess access,
    String branch,
  ) {
    _branch(access, BusinessLedgerAction.transfer);
    return _directory._read(
      (db) async => [
        for (final row in await db.rawQuery(
          '''
        SELECT a.id, a.bank_name, a.account_name, a.currency, a.balance_minor
        FROM ${BusinessLedger._accounts} a
        LEFT JOIN ${BusinessCashSync._accounts} s
          ON s.branch_id=a.branch_id AND s.account_id=a.id
        WHERE a.branch_id=? AND a.is_active=1 AND a.closed_us IS NULL AND s.account_id IS NULL
        ORDER BY a.created_us, a.id
      ''',
          [branch],
        ))
          {
            for (final key in ['id', 'bank_name', 'account_name', 'currency'])
              key: row[key],
            'balance': BusinessMoney.display(row['balance_minor'] as int),
          },
      ],
    );
  }
}

/// Who made the transfer and, for money between two currencies, the rate.
/// Both are read from the command's own saved result (synced with it).
Future<Map<String, Object?>> _transferExtras(
  DatabaseExecutor db,
  String acting,
  Map<String, Object?> mine,
  Map<String, Object?> peer,
) async {
  final command = (await db.query(
    BusinessLedger._commands,
    columns: ['result'],
    where: 'branch_id = ? AND id = ?',
    whereArgs: [acting, mine['id']],
    limit: 1,
  )).singleOrNull;
  Map? result;
  try {
    final decoded = command == null
        ? null
        : jsonDecode(command['result'] as String);
    if (decoded is Map) result = decoded;
  } on FormatException {
    result = null;
  }
  final actor = result?['actor'];
  final isOut = mine['side'] == 'out';
  final from = isOut ? mine['currency'] : peer['currency'];
  final to = isOut ? peer['currency'] : mine['currency'];
  String? rate;
  if (mine['kind'] == 'financial' && from != null && to != null && from != to) {
    rate = result?['rate'] as String?;
    if (rate != null && rate.contains('.')) {
      rate = rate
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    final sent = ((isOut ? mine : peer)['amount_minor'] as int?)?.abs();
    final got = ((isOut ? peer : mine)['amount_minor'] as int?)?.abs();
    if (rate == null && sent != null && got != null && sent > 0) {
      rate = (got / sent)
          .toStringAsFixed(6)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
  }
  return {
    'actor_name': actor is Map ? actor['name'] : null,
    'actor_role': actor is Map ? actor['role'] : null,
    'exchange_rate': rate,
  };
}

String? _transferMoney(Object? minor) =>
    minor is int ? BusinessMoney.display(minor.abs()) : null;

String _transferDate(Map<String, Object?> row) =>
    DateTime.fromMicrosecondsSinceEpoch(
      row['created_us'] as int,
      isUtc: true,
    ).toIso8601String();
