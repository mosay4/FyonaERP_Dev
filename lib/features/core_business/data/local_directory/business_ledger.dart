part of 'directory_database.dart';

enum BusinessLedgerAction {
  readBank,
  readBankHistory,
  createBank,
  manageBank,
  moveMoney,
  readManualMovements,
  readOperations,
  transfer,
  changeNegativePolicy,
  readDebt,
  createDebt,
  settleDebt,
  editDebtInvoice,
  deleteDebtInvoice,
  deleteParty,
  manageDebtGroups,
  syncCash,
  readSaleInvoice,
  readPurchaseInvoice,
  readInvoiceProfit,
  readReturns,
  readInventory,
  readInventoryCost,
  readInventoryProfit,
  adjustStock,
  manageProducts,
  issueDocument,
  confirmReturn,
  authorizeReturnOverdraft,
  sharePartyDebt,
  manageBackup,
  readDebtReport,
  readMoneyReport,
  readSalesReport,
  readOverviewReport,
  readBankReconciliation,
  checkBankReconciliation,
  approveBankReconciliation,
  readInventoryReconciliation,
  checkInventoryReconciliation,
  approveInventoryReconciliation,
  delegateEmployee,
  readEmployeeFinance,
  payEmployeeSalary,
  createEmployeeDebt,
  settleEmployeeDebt,
}

/// Internal grant supplied by the Business repository after cutover and
/// permission checks. Owning a PartyReference does not grant any bank rights.
/// When [employee] is set the call speaks for a delegated employee identity
/// and is confined to that employee's own records and delegated actions.
final class BusinessLedgerAccess {
  BusinessLedgerAccess(this.directory, Set<BusinessLedgerAction> actions, {
    this.cashSessionId,
    this.employee,
  })
    : _actions = Set.unmodifiable(actions);

  final DirectoryAccess directory;
  final Set<BusinessLedgerAction> _actions;
  final String? cashSessionId;
  final BusinessEmployeeDelegation? employee;

  /// Reads only: allowed in the «جميع الفروع» view, which never writes.
  static const readActions = {
    BusinessLedgerAction.readBank,
    BusinessLedgerAction.readBankHistory,
    BusinessLedgerAction.readManualMovements,
    BusinessLedgerAction.readOperations,
    BusinessLedgerAction.readDebt,
    BusinessLedgerAction.readSaleInvoice,
    BusinessLedgerAction.readPurchaseInvoice,
    BusinessLedgerAction.readInvoiceProfit,
    BusinessLedgerAction.readReturns,
    BusinessLedgerAction.readInventory,
    BusinessLedgerAction.readInventoryCost,
    BusinessLedgerAction.readInventoryProfit,
    BusinessLedgerAction.readDebtReport,
    BusinessLedgerAction.readMoneyReport,
    BusinessLedgerAction.readSalesReport,
    BusinessLedgerAction.readOverviewReport,
    BusinessLedgerAction.readBankReconciliation,
    BusinessLedgerAction.readInventoryReconciliation,
    BusinessLedgerAction.readEmployeeFinance,
  };

  bool get onlyReads => readActions.containsAll(_actions);
}

enum BusinessLedgerProblem {
  invalidAmount,
  invalidAccount,
  insufficientBalance,
  currencyMismatch,
  invalidTransfer,
  noDebtInCurrency,
  missingRate,
  invalidInvoice,
  invoiceChanged,
  noChanges,
  commandConflict,
  sharedCashRequiresArbitration,
  duplicateBankAccount,
  cannotDeleteLastCash,
  accountChanged,
  currencyHasPayments,
  invalidProduct,
  duplicateProductCode,
  stockChanged,
  insufficientStock,
  invalidEmployee,
}

final class BusinessLedgerError implements Exception {
  const BusinessLedgerError(this.problem);
  final BusinessLedgerProblem problem;
}

/// Actionable only for a caller authorized to make this overdraft decision.
/// No balance is returned, and no part of the return has been committed.
final class BusinessReturnOverdraft implements Exception {
  const BusinessReturnOverdraft(this.refundMinor);
  final int refundMinor;
}

/// Business-only transaction boundary, on the same encrypted connection as
/// the directory. Neither remote APIs nor the Personal queue are dependencies.
final class BusinessLedger {
  BusinessLedger._(this._directory);
  final DirectoryDatabase _directory;
  late final BusinessCashSync cashSync = BusinessCashSync._(this);

  static const _commands = 'business_ledger_commands';
  static const _accounts = 'business_local_accounts';
  static const _legs = 'business_local_bank_legs';
  static const _debts = 'business_local_debts';
  static const _parts = 'business_local_payment_parts';
  static const _paymentHistory = 'business_debt_payment_history';
  static const _policy = 'business_ledger_policy';

  String _branch(BusinessLedgerAccess access, BusinessLedgerAction action) {
    if (access.directory.workspace.storageId !=
            _directory.workspace.storageId ||
        !access._actions.contains(action)) {
      throw const DirectoryAccessDenied();
    }
    return access.directory.branchId;
  }

  void _partyScope(BusinessLedgerAccess access, DirectoryPartyReference party) {
    party.requireScope(access.directory);
  }

  Future<void> setAllowNegative(BusinessLedgerAccess access, bool value) async {
    final branch = _branch(access, BusinessLedgerAction.changeNegativePolicy);
    await _directory._transaction(
      (txn) => _setNegativePolicy(txn, branch, value),
      exclusive: true,
    );
  }

  Future<void> _setNegativePolicy(
    Transaction txn, String branch, bool value,
  ) async {
    final shared = await txn.query(
      BusinessCashSync._accounts,
      columns: ['account_id'],
      where: 'branch_id = ? AND allow_negative <> ?',
      whereArgs: [branch, value ? 1 : 0],
      limit: 1,
    );
    if (shared.isNotEmpty) {
      throw const BusinessLedgerError(
        BusinessLedgerProblem.sharedCashRequiresArbitration,
      );
    }
    await txn.insert(_policy, {
      'branch_id': branch,
      'allow_negative': value ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool?> savedAllowNegative(BusinessLedgerAccess access) async {
    final branch = _branch(access, BusinessLedgerAction.changeNegativePolicy);
    final rows = await _directory._read(
      (db) => db.query(_policy, where: 'branch_id = ?', whereArgs: [branch]),
    );
    return rows.isEmpty ? null : rows.single['allow_negative'] == 1;
  }

  Future<bool> _allowsNegative(DatabaseExecutor db, String branch) async {
    final rows = await db.query(
      _policy,
      where: 'branch_id = ?',
      whereArgs: [branch],
    );
    return rows.singleOrNull?['allow_negative'] == 1;
  }

  Future<List<Map<String, Object?>>> accounts(BusinessLedgerAccess access) {
    final branch = _branch(access, BusinessLedgerAction.readBank);
    return _directory._read(
      (db) => db.query(
        _accounts,
        where: 'branch_id = ? AND closed_us IS NULL AND is_active = 1',
        whereArgs: [branch],
        orderBy: 'created_us, id',
      ),
    );
  }

  Future<List<Map<String, Object?>>> statement(
    BusinessLedgerAccess access,
    String accountId,
  ) async {
    final branch = _branch(access, BusinessLedgerAction.readBank);
    return _directory._transaction((txn) async {
      await _account(txn, branch, accountId, allowInactive: true);
      return txn.query(
        _legs,
        where: 'branch_id = ? AND account_id = ?',
        whereArgs: [branch, accountId],
        orderBy: 'sequence DESC',
      );
    });
  }

  Future<List<Map<String, dynamic>>> manualMovements(
    BusinessLedgerAccess access, {
    required bool showIncome,
    required bool showExpenses,
    DateTime? from,
    DateTime? to,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.readManualMovements);
    final kinds = [if (showIncome) 'deposit', if (showExpenses) 'withdrawal'];
    if (kinds.isEmpty) return [];
    final markers = List.filled(kinds.length, '?').join(', ');
    // An accepted shared withdrawal may arrive with just an authority marker
    // instead of a device command result. It is still a manual movement.
    final rows = await _directory._read(
      (db) => db.rawQuery(
        '''
      SELECT l.*, a.bank_name
      FROM $_legs l JOIN $_accounts a ON a.branch_id = l.branch_id AND a.id = l.account_id
      JOIN $_commands cmd ON cmd.branch_id = l.branch_id AND cmd.id = l.command_id
      WHERE l.branch_id = ? AND l.kind IN ($markers) AND l.legacy = 0
      AND $_unreferencedBankLeg AND $_visibleBankLeg
       AND (json_type(cmd.result, '\$.balance_minor') = 'integer'
         OR (l.kind = 'withdrawal' AND EXISTS (
           SELECT 1 FROM ${BusinessCashSync._decisions} accepted
           WHERE accepted.branch_id = l.branch_id AND accepted.command_id = l.command_id
             AND accepted.account_id = l.account_id AND accepted.decision = 'accepted'
         )))
      ${from == null ? '' : 'AND l.created_us >= ?'}
      ${to == null ? '' : 'AND l.created_us < ?'}
      ORDER BY l.created_us DESC, l.sequence DESC LIMIT 100
    ''',
        [
          branch,
          ...kinds,
          if (from != null) from.microsecondsSinceEpoch,
          if (to != null) to.microsecondsSinceEpoch,
        ],
      ),
    );
    return [
      for (final row in rows)
        {
          'source_type': row['expense_category'] == null
              ? 'bank_tx'
              : 'expense',
          'source_id': row['command_id'],
          'bank_account_id': row['account_id'],
          'kind': row['kind'] == 'deposit' ? 'income' : 'bank_withdrawal',
          'direction': row['kind'] == 'deposit' ? 'in' : 'out',
          'date': DateTime.fromMicrosecondsSinceEpoch(
            row['created_us'] as int,
            isUtc: true,
          ).toIso8601String(),
          'currency': row['currency'],
          'amount': BusinessMoney.display((row['delta_minor'] as int).abs()),
          'account': row['bank_name'],
          'notes': row['description'],
          'category': row['expense_category'],
          'branch_id': branch,
        },
    ];
  }

  Future<Map<String, Object?>> createAccount(
    BusinessLedgerAccess access, {
    required String commandId,
    required String bankName,
    required String accountName,
    required String accountNumber,
    required String currency,
    String accountType = 'checking',
    String? iban,
    int openingMinor = 0,
    bool managed = false,
  }) {
    final branch = _branch(access, BusinessLedgerAction.createBank);
    final bank = _requiredField(bankName, 200);
    if (managed && bank.runes.length < 2) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    final name = _requiredField(accountName, 200);
    final number = accountNumber.trim();
    if (number.runes.length > 100) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    final type = _requiredField(accountType, 20);
    final cur = businessCurrency(currency);
    final cleanIban = iban?.trim();
    if (cleanIban != null && cleanIban.length > 50) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    _amount(openingMinor, zero: true);

    return _commit(
      branch,
      commandId,
      [
        'account',
        bank,
        name,
        number,
        type,
        cur,
        cleanIban,
        openingMinor,
        if (managed) true,
      ],
      (txn, now) async {
        await _requireCashSlotNotReserved(txn, branch, bank, cur);
        if (managed) {
          await _requireBankSlot(txn, branch, bank, cur, type);
          if (openingMinor == 0 && _isLedgerCash(bank)) {
            final restored = await _restoreCashSlot(
              txn,
              branch,
              commandId,
              cur,
              type,
              now,
              checkingAlias: true,
            );
            if (restored != null) return restored;
          }
        }
        await txn.insert(_accounts, {
          'id': commandId,
          'branch_id': branch,
          'bank_name': bank,
          'account_name': name,
          'account_number': number,
          'currency': cur,
          'account_type': type,
          'iban': cleanIban,
          'balance_minor': openingMinor,
          'created_us': now.microsecondsSinceEpoch,
        });
        if (openingMinor > 0) {
          await _leg(
            txn,
            branch,
            commandId,
            commandId,
            now,
            kind: 'opening_balance',
            delta: openingMinor,
            balance: openingMinor,
            description: 'رصيد افتتاحي',
          );
        }
        return {'id': commandId, 'balance_minor': openingMinor};
      },
    );
  }

  Future<Map<String, Object?>> move(
    BusinessLedgerAccess access, {
    required String commandId,
    required String accountId,
    required int amountMinor,
    required bool withdraw,
    String? description,
    String? expenseCategory,
  }) {
    final branch = _branch(access, BusinessLedgerAction.moveMoney);
    _amount(amountMinor);
    final category = expenseCategory?.trim();
    if (!withdraw && category != null) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    final detail = description?.trim();
    return _commit(
      branch,
      commandId,
      ['movement', accountId, amountMinor, withdraw, detail, category],
      (txn, now) async {
        final account = await _account(txn, branch, accountId);
        final shared = await cashSync._config(txn, branch, accountId);
        if (shared != null) {
          if (!withdraw) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.sharedCashRequiresArbitration,
            );
          }
          return cashSync._stageWithdrawal(
            txn,
            branch,
            access.cashSessionId,
            commandId,
            accountId,
            now,
            account,
            shared,
            amountMinor,
            description: DirectoryDatabase._optional(detail) ?? 'سحب',
            expenseCategory: category == '' ? 'متنوعة' : category,
          );
        }
        final delta = withdraw ? -amountMinor : amountMinor;
        final next = _balance(account, delta);
        if (withdraw && next < 0 && !await _allowsNegative(txn, branch)) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.insufficientBalance,
          );
        }
        await _post(
          txn,
          branch,
          commandId,
          accountId,
          now,
          kind: withdraw ? 'withdrawal' : 'deposit',
          delta: delta,
          next: next,
          description: detail != null && detail.isNotEmpty
              ? detail
              : withdraw
              ? 'سحب'
              : 'إيداع',
          expenseCategory: category == '' ? 'متنوعة' : category,
        );
        return {'id': commandId, 'balance_minor': next};
      },
    );
  }

  /// In-branch bank transfer. Each currency gets exactly one leg. A future
  /// cross-branch command must authorize both branches before using this store.
  Future<Map<String, Object?>> transfer(
    BusinessLedgerAccess access, {
    required String commandId,
    required String fromId,
    required String toId,
    required int amountMinor,
    BusinessRate? rate,
    String? description,
  }) {
    final branch = _branch(access, BusinessLedgerAction.transfer);
    _amount(amountMinor);
    if (fromId == toId) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
    }
    final detail = description?.trim();
    return _commit(
      branch,
      commandId,
      [
        'transfer',
        fromId,
        toId,
        amountMinor,
        rate?.from,
        rate?.to,
        rate?.decimal,
        detail,
      ],
      (txn, now) async {
        final source = await _account(txn, branch, fromId);
        final target = await _account(txn, branch, toId);
        await cashSync._requirePrivate(txn, branch, fromId);
        await cashSync._requirePrivate(txn, branch, toId);
        final from = source['currency'] as String;
        final to = target['currency'] as String;
        // Legacy transfer stores the supplied received amount in NUMERIC(12,2)
        // (half away from zero); debt settlement uses Python Decimal first.
        final credit = _convert(amountMinor, from, to, rate, halfEven: false);
        _amount(credit);
        final debitBalance = _balance(source, -amountMinor);
        // The connected in-branch transfer currently always forbids an
        // overdraft, independently of the setting for manual withdrawals.
        if (debitBalance < 0) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.insufficientBalance,
          );
        }
        final creditBalance = _balance(target, credit);
        final shown = detail == null || detail.isEmpty ? 'تحويل' : detail;
        await _post(
          txn,
          branch,
          commandId,
          fromId,
          now,
          kind: 'transfer_out',
          delta: -amountMinor,
          next: debitBalance,
          description: 'تحويل إلى ${target['account_name']}: $shown',
          rate: rate,
        );
        await _post(
          txn,
          branch,
          commandId,
          toId,
          now,
          kind: 'transfer_in',
          delta: credit,
          next: creditBalance,
          description: 'تحويل من ${source['account_name']}: $shown',
          rate: rate,
        );
        return {
          'id': commandId,
          'from_balance_minor': debitBalance,
          'to_balance_minor': creditBalance,
          'received_minor': credit,
        };
      },
    );
  }

  /// The opening balance form saves the directory card and the corresponding
  /// debt document in one transaction. Zero is the existing card-only case.
  Future<Map<String, Object?>> addPartyWithOpeningDebt(
    BusinessLedgerAccess access,
    DirectoryPartyKind kind, {
    required String commandId,
    required String name,
    String? phone,
    required int amountMinor,
    required String currency,
  }) {
    final branch = _branch(access, BusinessLedgerAction.createDebt);
    _directory._check(access.directory, kind, write: true);
    _amount(amountMinor, zero: true);
    final cur = businessCurrency(currency);
    final phoneValue = DirectoryDatabase._optional(phone);
    return _commit(
      branch,
      commandId,
      [
        'opening_with_party',
        kind.name,
        name.trim(),
        phoneValue,
        amountMinor,
        cur,
      ],
      (txn, now) async {
        final party = _directory._newParty(
          access.directory,
          kind,
          name: name,
          phone: phoneValue,
          id: commandId,
          time: now,
        );
        await _directory._insert(txn, party, 'device');
        if (amountMinor > 0) {
          await _opening(
            txn,
            branch,
            kind,
            party.id,
            commandId,
            now,
            amountMinor,
            cur,
          );
        }
        return {
          'party_id': party.id,
          'invoice_id': amountMinor > 0 ? commandId : null,
        };
      },
    );
  }

  /// The same opening document for an existing directory party (e.g. import
  /// of opening balances). This is not a normal sale/purchase with inventory.
  Future<Map<String, Object?>> recordOpeningDebt(
    BusinessLedgerAccess access,
    DirectoryPartyReference party, {
    required String commandId,
    required int amountMinor,
    required String currency,
    String? groupId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.createDebt);
    _partyScope(access, party);
    _amount(amountMinor);
    final cur = businessCurrency(currency);
    return _commit(
      branch,
      commandId,
      ['opening', party.kind.name, party.id, amountMinor, cur, groupId],
      (txn, now) async {
        await _directory._scopedParty(
          txn,
          access.directory,
          party.kind,
          party.id,
        );
        await _requireGroup(txn, branch, party, groupId);
        await _opening(
          txn,
          branch,
          party.kind,
          party.id,
          commandId,
          now,
          amountMinor,
          cur,
          groupId: groupId,
        );
        return {'invoice_id': commandId};
      },
    );
  }

  Future<void> _opening(
    Transaction txn,
    String branch,
    DirectoryPartyKind kind,
    String partyId,
    String id,
    DateTime now,
    int minor,
    String currency, {
    String? groupId,
  }) async {
    final date = _date(now);
    // Retain the recognizable OPEN prefix without a shared/online sequence.
    // The device UUID remains fixed on retries.
    final number =
        'OPEN-${date.replaceAll('-', '')}-${id.replaceAll('-', '').toUpperCase()}';
    await txn.insert(_debts, {
      'branch_id': branch,
      'id': id,
      'kind': kind.name,
      'party_id': partyId,
      'group_id': groupId,
      'invoice_date': date,
      'number': number,
      'currency': currency,
      'total_minor': minor,
      'paid_minor': 0,
      'created_us': now.microsecondsSinceEpoch,
    });
  }

  Future<List<Map<String, Object?>>> debts(
    BusinessLedgerAccess access,
    DirectoryPartyReference party, {
    String? groupId,
    bool individual = false,
    String? dateFrom,
    String? dateTo,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readDebt);
    _partyScope(access, party);
    if (individual && groupId != null)
      throw ArgumentError('Conflicting group filters');
    return _directory._transaction((txn) async {
      await _directory._scopedParty(
        txn,
        access.directory,
        party.kind,
        party.id,
      );
      await _requireGroup(txn, branch, party, groupId);
      final groupFilter = groupId == null
          ? (individual ? ' AND group_id IS NULL' : '')
          : ' AND group_id = ?';
      final dateFromFilter = dateFrom == null ? '' : ' AND invoice_date >= ?';
      final dateToFilter = dateTo == null ? '' : ' AND invoice_date <= ?';
      // Ordinary invoices share the party's operation list with opening
      // debts, and every row they expose has its edit/delete actions. A
      // returned amount stays on the original invoice, so remaining comes
      // from the document balance, never inferred from total−paid.
      return txn.rawQuery(
        '''
        SELECT id, number, invoice_date, currency, total_minor, paid_minor,
          group_id, created_us,
          MAX(0, total_minor - paid_minor) AS remaining_minor
        FROM $_debts
        WHERE branch_id = ? AND kind = ? AND party_id = ? AND cancelled_us IS NULL
          $groupFilter$dateFromFilter$dateToFilter
        UNION ALL
        SELECT i.id, i.number, i.date AS invoice_date, i.currency, i.total_minor,
          i.paid_minor, i.group_id, i.created_us,
          i.balance_minor AS remaining_minor
        FROM $_commerceInvoices i
        WHERE i.branch_id = ? AND i.party_kind = ? AND i.party_id = ?
          AND i.deleted_us IS NULL AND i.status NOT IN ('draft','cancelled')
          ${groupId == null ? (individual ? ' AND i.group_id IS NULL' : '') : ' AND i.group_id = ?'}${dateFrom == null ? '' : ' AND i.date >= ?'}${dateTo == null ? '' : ' AND i.date <= ?'}
        ORDER BY invoice_date DESC, created_us DESC, id DESC
        ''',
        [
          branch,
          party.kind.name,
          party.id,
          ?groupId,
          ?dateFrom,
          ?dateTo,
          branch,
          party.kind.name,
          party.id,
          ?groupId,
          ?dateFrom,
          ?dateTo,
        ],
      );
    });
  }

  Future<List<Map<String, Object?>>> paymentParts(
    BusinessLedgerAccess access,
    DirectoryPartyReference party,
    String invoiceId,
  ) {
    final branch = _branch(access, BusinessLedgerAction.readDebt);
    _partyScope(access, party);
    return _directory._transaction((txn) async {
      await _directory._scopedParty(
        txn,
        access.directory,
        party.kind,
        party.id,
      );
      await _invoice(txn, branch, party, invoiceId, null);
      return txn.query(
        _paymentHistory,
        where: 'branch_id = ? AND invoice_id = ?',
        whereArgs: [branch, invoiceId],
        orderBy: 'date, created_us, id',
      );
    });
  }

  /// Preserve the encrypted audit trail and posted bank legs, but remove
  /// the unlinked directory party and its debts from active projections.
  /// The tombstone is also the durable Business sharing revocation signal.
  /// It is transported independently on reconnect; deletion never waits for it.
  Future<Map<String, Object?>> deleteUnlinkedParty(
    BusinessLedgerAccess access,
    DirectoryPartyReference party, {
    required String commandId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.deleteParty);
    party.requireScope(access.directory, write: true);
    return _commit(
      branch,
      commandId,
      ['unlinked_delete', party.kind.name, party.id],
      (txn, now) async {
        await _directory._scopedParty(
          txn,
          access.directory,
          party.kind,
          party.id,
        );
        await txn.insert(DirectoryDatabase._deleted, {
          'branch_id': branch,
          'kind': party.kind.name,
          'party_id': party.id,
          'deleted_us': now.microsecondsSinceEpoch,
        });
        return {'id': party.id, 'deleted': true};
      },
    );
  }

  Future<Map<String, Object?>> assignDebtGroup(
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target, {
    required String commandId,
    String? groupId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageDebtGroups);
    final party = target.party;
    _partyScope(access, party);
    return _commit(
      branch,
      commandId,
      ['assign_group', party.kind.name, party.id, target.id, groupId],
      (txn, now) async {
        await _directory._scopedParty(
          txn,
          access.directory,
          party.kind,
          party.id,
        );
        await _requireGroup(txn, branch, party, groupId);
        await _invoice(txn, branch, party, target.id, null);
        await txn.update(
          _debts,
          {'group_id': groupId},
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, target.id],
        );
        return {'id': target.id, 'group_id': groupId};
      },
    );
  }

  Future<Map<String, Object?>> removeDebtGroup(
    BusinessLedgerAccess access,
    DirectoryDebtGroupReference target, {
    required String commandId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageDebtGroups);
    final party = target.party;
    _partyScope(access, party);
    return _commit(
      branch,
      commandId,
      ['remove_group', party.kind.name, party.id, target.id],
      (txn, now) async {
        await _directory._scopedParty(
          txn,
          access.directory,
          party.kind,
          party.id,
        );
        await _requireGroup(txn, branch, party, target.id);
        const where = 'branch_id = ? AND kind = ? AND party_id = ?';
        final args = [branch, party.kind.name, party.id, target.id];
        await txn.update(
          _debts,
          {'group_id': null},
          where: '$where AND group_id = ?',
          whereArgs: args,
        );
        await txn.update(
          _commerceInvoices,
          {'group_id': null},
          where:
              'branch_id = ? AND party_kind = ? AND party_id = ? AND group_id = ?',
          whereArgs: args,
        );
        await txn.delete(
          DirectoryDatabase._groupTable,
          where: '$where AND id = ?',
          whereArgs: args,
        );
        return {'id': target.id, 'deleted': true};
      },
    );
  }

  Future<Map<String, Object?>> settle(
    BusinessLedgerAccess access,
    DirectoryPartyReference party, {
    required String commandId,
    required String accountId,
    required int amountMinor,
    required String currency,
    String method = 'bank',
    String? groupId,
    String? invoiceId,
    BusinessRate? rate,
  }) {
    final branch = _branch(access, BusinessLedgerAction.settleDebt);
    _partyScope(access, party);
    _amount(amountMinor);
    final payCurrency = businessCurrency(currency);
    if (!const {
      'bank',
      'cash',
      'card',
      'transfer',
      'cheque',
    }.contains(method)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    return _commit(
      branch,
      commandId,
      [
        'settle',
        party.kind.name,
        party.id,
        accountId,
        amountMinor,
        payCurrency,
        method,
        groupId,
        invoiceId,
        rate?.from,
        rate?.to,
        rate?.decimal,
      ],
      (txn, now) async {
        final account = await _account(txn, branch, accountId);
        await cashSync._requirePrivate(txn, branch, accountId);
        if (account['currency'] != payCurrency) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.currencyMismatch,
          );
        }
        final partyRow = await _directory._scopedParty(
          txn,
          access.directory,
          party.kind,
          party.id,
        );
        await _requireGroup(txn, branch, party, groupId);
        if (invoiceId != null) {
          var targetCurrency = (await txn.query(
            _debts,
            columns: ['currency', 'kind', 'party_id', 'group_id', 'cancelled_us'],
            where: 'branch_id = ? AND id = ?',
            whereArgs: [branch, invoiceId],
          )).singleOrNull?['currency'];
          if (targetCurrency == null) {
            final commerce = (await txn.query(
              _commerceInvoices,
              columns: ['currency', 'party_kind', 'party_id', 'group_id', 'status', 'deleted_us'],
              where: 'branch_id = ? AND id = ?',
              whereArgs: [branch, invoiceId],
            )).singleOrNull;
            if (commerce == null ||
                commerce['party_kind'] != party.kind.name ||
                commerce['party_id'] != party.id ||
                (groupId != null && commerce['group_id'] != groupId) ||
                commerce['deleted_us'] != null ||
                const {'draft', 'cancelled'}.contains(commerce['status'])) {
              throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
            }
            targetCurrency = commerce['currency'];
          }
          if (targetCurrency != payCurrency) {
            // Existing single-invoice UI only allows the invoice's currency.
            throw const BusinessLedgerError(
              BusinessLedgerProblem.currencyMismatch,
            );
          }
        }
        final open = <Map<String, Object?>>[];
        final openingRows = await txn.query(
          _debts,
          where:
              'branch_id = ? AND kind = ? AND party_id = ? AND cancelled_us IS NULL AND paid_minor < total_minor'
              '${groupId == null ? '' : ' AND group_id = ?'}'
              '${invoiceId == null ? '' : ' AND id = ?'}',
          whereArgs: [branch, party.kind.name, party.id, ?groupId, ?invoiceId],
          orderBy: 'invoice_date, created_us, id',
        );
        for (final row in openingRows) {
          open.add({
            'id': row['id'],
            'currency': row['currency'],
            'remaining': (row['total_minor'] as int) - (row['paid_minor'] as int),
            'paid': row['paid_minor'],
            'revision': row['revision'],
            'invoice_date': row['invoice_date'],
            'created_us': row['created_us'],
            'source': 'opening',
          });
        }
        final commerceRows = await txn.rawQuery(
          '''
          SELECT id, currency, balance_minor AS remaining, paid_minor AS paid,
            date AS invoice_date, created_us
          FROM $_commerceInvoices
          WHERE branch_id = ? AND party_kind = ? AND party_id = ?
            AND deleted_us IS NULL AND status NOT IN ('draft','cancelled')
            AND balance_minor > 0
            ${groupId == null ? '' : ' AND group_id = ?'}
            ${invoiceId == null ? '' : ' AND id = ?'}
          ''',
          [branch, party.kind.name, party.id, ?groupId, ?invoiceId],
        );
        for (final row in commerceRows) {
          open.add({...row, 'revision': null, 'source': 'commerce'});
        }
        open.sort((a, b) {
          final byDate = '${a['invoice_date']}'.compareTo('${b['invoice_date']}');
          if (byDate != 0) return byDate;
          final byTime = (a['created_us'] as int).compareTo(b['created_us'] as int);
          return byTime != 0 ? byTime : '${a['id']}'.compareTo('${b['id']}');
        });
        if (open.isEmpty) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.noDebtInCurrency,
          );
        }
        final debtCurrency = open.any((r) => r['currency'] == payCurrency)
            ? payCurrency
            : open.first['currency'] as String;
        final cross = debtCurrency != payCurrency;
        final equivalent = _convert(
          amountMinor,
          payCurrency,
          debtCurrency,
          rate,
        );
        _amount(equivalent);
        final supplier = party.kind == DirectoryPartyKind.supplier;
        final delta = supplier ? -amountMinor : amountMinor;
        final next = _balance(account, delta);
        if (supplier && next < 0 && !await _allowsNegative(txn, branch)) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.insufficientBalance,
          );
        }

        var left = equivalent;
        var allocatedOriginal = 0;
        final touched = <String>[];
        for (final row in open.where((r) => r['currency'] == debtCurrency)) {
          if (left == 0) break;
          final id = row['id'] as String;
          final paid = row['paid'] as int;
          final remaining = row['remaining'] as int;
          final take = min(left, remaining);
          left -= take;
          // Round cumulative original amounts, not every split independently:
          // the tiny rounding residue cannot create or destroy bank cents.
          final originalSoFar = left == 0
              ? amountMinor
              : cross
              ? min(amountMinor, rate!.original(equivalent - left))
              : equivalent - left;
          if (row['source'] == 'opening') {
            await txn.update(
              _debts,
              {
                'paid_minor': paid + take,
                'revision': (row['revision'] as int) + 1,
              },
              where: 'branch_id = ? AND id = ?',
              whereArgs: [branch, id],
            );
            await txn.insert(_parts, {
              'branch_id': branch,
              'command_id': commandId,
              'invoice_id': id,
              'account_id': accountId,
              'method': method,
              'date': _date(now),
              'payment_currency': payCurrency,
              'debt_currency': debtCurrency,
              'original_minor': originalSoFar - allocatedOriginal,
              'applied_minor': take,
              'exchange_rate': cross ? rate!.decimal : '1.00000000',
            });
          } else {
            await txn.update(
              _commerceInvoices,
              {
                'paid_minor': paid + take,
                'balance_minor': remaining - take,
                'status': remaining - take == 0
                    ? 'paid'
                    : (paid + take > 0 ? 'partially_paid' : 'confirmed'),
              },
              where: 'branch_id = ? AND id = ?',
              whereArgs: [branch, id],
            );
            final balanceRow = (await txn.query(
              _commerceBalances,
              where: 'branch_id = ? AND invoice_id = ?',
              whereArgs: [branch, id],
            )).singleOrNull;
            if (balanceRow != null) {
              final owed =
                  (balanceRow['amount_minor'] as int) -
                  (balanceRow['paid_minor'] as int) -
                  take;
              await txn.update(
                _commerceBalances,
                {
                  'paid_minor': (balanceRow['paid_minor'] as int) + take,
                  'status': owed <= 0 ? 'paid' : 'partial',
                },
                where: 'branch_id = ? AND invoice_id = ?',
                whereArgs: [branch, id],
              );
            }
            await txn.insert(_commercePayments, {
              'branch_id': branch,
              'id': const Uuid().v5(
                commandId,
                'fyona.commerce.settle.v1:$id',
              ),
              'invoice_id': id,
              'account_id': accountId,
              'method': method,
              'date': _date(now),
              'payment_currency': payCurrency,
              'debt_currency': debtCurrency,
              'exchange_rate': cross ? rate!.decimal : '1.00000000',
              'original_minor': originalSoFar - allocatedOriginal,
              'applied_minor': take,
              'created_by': access.directory.workspace.accountId,
              'created_us': now.toUtc().microsecondsSinceEpoch,
            });
          }
          allocatedOriginal = originalSoFar;
          touched.add(id);
        }
        final surplus = amountMinor - allocatedOriginal;
        final name = partyRow['name'];
        final label = supplier ? 'سداد للمورد $name' : 'تحصيل من العميل $name';
        await _post(
          txn,
          branch,
          commandId,
          accountId,
          now,
          kind: supplier ? 'supplier_payment' : 'customer_collection',
          delta: delta,
          next: next,
          description: surplus == 0
              ? label
              : '$label (+زيادة ${BusinessMoney.display(surplus)} $payCurrency)',
          rate: cross ? rate : null,
        );
        return {
          'id': commandId,
          'party_id': party.id,
          'invoices': touched,
          'applied_minor': equivalent - left,
          'surplus_minor': surplus,
          'debt_currency': debtCurrency,
          'payment_currency': payCurrency,
          'balance_minor': next,
        };
      },
    );
  }

  Future<Map<String, Object?>> _commit(
    String branch,
    String id,
    List<Object?> fields,
    Future<Map<String, Object?>> Function(Transaction, DateTime) write, {
    bool Function()? allowed,
    Future<void> Function(Transaction)? validate,
    List<String> mirrorBranches = const [],
  }) async {
    if (!isDirectoryId(id) || id != id.toLowerCase()) {
      throw ArgumentError('Invalid Business command ID');
    }
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(fields)))
        .toString();
    return _directory._transaction((txn) async {
      if (allowed?.call() == false) throw const DirectoryAccessDenied();
      if (validate != null) await validate(txn);
      final existing = await txn.query(
        _commands,
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, id],
      );
      if (existing.isNotEmpty) {
        final old = existing.single;
        if (old['fingerprint'] != fingerprint) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        if (allowed?.call() == false) throw const DirectoryAccessDenied();
        return Map<String, Object?>.from(
          jsonDecode(old['result'] as String) as Map,
        );
      }
      final result = await write(txn, DateTime.now());
      await txn.insert(_commands, {
        'branch_id': branch,
        'id': id,
        'fingerprint': fingerprint,
        'result': jsonEncode(result),
      });
      // A command that moved two branches is replayable and auditable from
      // either side, and their rows require its presence per branch.
      for (final mirror in mirrorBranches) {
        if (mirror == branch) continue;
        await txn.insert(_commands, {
          'branch_id': mirror,
          'id': id,
          'fingerprint': fingerprint,
          'result': jsonEncode(result),
        });
      }
      if (allowed?.call() == false) throw const DirectoryAccessDenied();
      return result;
    }, exclusive: true);
  }

  Future<Map<String, Object?>> _account(
    DatabaseExecutor db,
    String branch,
    String id, {
    bool allowInactive = false,
    bool allowClosed = false,
  }) async {
    final rows = await db.query(
      _accounts,
      where:
          'branch_id = ? AND id = ?'
          '${allowClosed ? '' : ' AND closed_us IS NULL'}'
          '${allowInactive ? '' : ' AND is_active = 1'}',
      whereArgs: [branch, id],
    );
    if (rows.isEmpty) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    return rows.single;
  }

  Future<Map<String, Object?>> _invoice(
    DatabaseExecutor db,
    String branch,
    DirectoryPartyReference party,
    String id,
    String? groupId,
  ) async {
    final rows = await db.query(
      _debts,
      where:
          'branch_id = ? AND kind = ? AND party_id = ? AND id = ? AND cancelled_us IS NULL'
          '${groupId == null ? '' : ' AND group_id = ?'}',
      whereArgs: [branch, party.kind.name, party.id, id, ?groupId],
    );
    if (rows.isEmpty) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    return rows.single;
  }

  Future<void> _requireGroup(
    DatabaseExecutor db,
    String branch,
    DirectoryPartyReference party,
    String? id,
  ) async {
    if (id == null) return;
    final rows = await db.query(
      DirectoryDatabase._groupTable,
      columns: ['id'],
      where: 'branch_id = ? AND kind = ? AND party_id = ? AND id = ?',
      whereArgs: [branch, party.kind.name, party.id, id],
    );
    if (rows.isEmpty) throw const DirectoryPartyNotFound();
  }

  Future<void> _post(
    Transaction txn,
    String branch,
    String command,
    String account,
    DateTime now, {
    required String kind,
    required int delta,
    required int next,
    required String description,
    String? expenseCategory,
    BusinessRate? rate,
    String? reference,
  }) async {
    await txn.update(
      _accounts,
      {'balance_minor': next},
      where: 'branch_id = ? AND id = ?',
      whereArgs: [branch, account],
    );
    await _leg(
      txn,
      branch,
      command,
      account,
      now,
      kind: kind,
      delta: delta,
      balance: next,
      description: description,
      expenseCategory: expenseCategory,
      rate: rate,
      reference: reference,
    );
  }

  Future<void> _leg(
    Transaction txn,
    String branch,
    String command,
    String account,
    DateTime now, {
    required String kind,
    required int delta,
    required int balance,
    required String description,
    String? expenseCategory,
    BusinessRate? rate,
    String? reference,
  }) async {
    final row = await _account(
      txn,
      branch,
      account,
      allowInactive: true,
      allowClosed: true,
    );
    await txn.insert(_legs, {
      'branch_id': branch,
      'command_id': command,
      'account_id': account,
      'kind': kind,
      'delta_minor': delta,
      'balance_minor': balance,
      'description': description,
      'expense_category': expenseCategory,
      'created_us': now.microsecondsSinceEpoch,
      'fx_rate': rate?.decimal,
      'currency': row['currency'],
      'reference': reference,
    });
  }

  static int _balance(Map<String, Object?> account, int delta) =>
      BusinessMoney.checked((account['balance_minor'] as int) + delta);

  static int _convert(
    int amount,
    String from,
    String to,
    BusinessRate? rate, {
    bool halfEven = true,
  }) {
    if (rate != null && (rate.from != from || rate.to != to)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.currencyMismatch);
    }
    if (from == to) return amount;
    if (rate == null) {
      throw const BusinessLedgerError(BusinessLedgerProblem.missingRate);
    }
    return rate.convert(amount, halfEven: halfEven);
  }

  static void _amount(int amount, {bool zero = false}) {
    if (amount < (zero ? 0 : 1) || amount > BusinessMoney.maxMinor) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
  }

  static String _requiredField(String value, int limit) {
    final field = value.trim();
    if (field.isEmpty || field.runes.length > limit) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    return field;
  }

  static String _date(DateTime now) => now.toIso8601String().split('T').first;
}
