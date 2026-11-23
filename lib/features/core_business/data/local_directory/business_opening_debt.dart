part of 'directory_database.dart';

/// The opening debt is a one-line service document. Regular invoices with
/// products/returns will need their own atomic stock-and-ledger writer.
extension BusinessOpeningDebts on BusinessLedger {
  static const _edits = 'business_opening_debt_edits';
  static const _openingLabel = 'رصيد افتتاحي';

  Future<Map<String, Object?>> _debtTarget(
    Transaction txn,
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target,
  ) async {
    final party = target.party;
    await _directory._scopedParty(txn, access.directory, party.kind, party.id);
    return _invoice(txn, access.directory.branchId, party, target.id, null);
  }

  Future<Map<String, dynamic>> openingDebtOperation(
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target,
  ) => _openingView(access, target, document: false);

  Future<Map<String, dynamic>> openingInvoice(
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target,
  ) => _openingView(access, target, document: true);

  Future<Map<String, dynamic>> _openingView(
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target, {
    required bool document,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readDebt);
    final party = target.party;
    _partyScope(access, party);
    return _directory._transaction((txn) async {
      final contact = await _directory._scopedParty(
        txn,
        access.directory,
        party.kind,
        party.id,
      );
      final commerce = (await txn.query(
        _commerceInvoices,
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, target.id],
      )).singleOrNull;
      if (commerce != null) {
        if (commerce['deleted_us'] != null) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
        }
        return _commerceOperationView(
          txn, branch, party, contact, commerce, target.id, document,
        );
      }
      final debt = await _invoice(txn, branch, party, target.id, null);
      final paid = debt['paid_minor'] as int;
      final total = debt['total_minor'] as int;
      final remaining = max(0, total - paid);
      final price = BusinessMoney.display(
        debt['opening_unit_minor'] as int? ?? total,
      );
      final quantity = debt['opening_quantity'] as String;
      final itemId = debt['opening_item_id'] as String? ?? target.id;
      final supplier = party.kind == DirectoryPartyKind.supplier;
      final parts = await txn.rawQuery(
        '''
        SELECT p.*, a.account_name, a.bank_name FROM ${BusinessLedger._paymentHistory} p
        LEFT JOIN ${BusinessLedger._accounts} a ON a.branch_id = p.branch_id AND a.id = p.account_id
        WHERE p.branch_id = ? AND p.invoice_id = ?
        ORDER BY p.date, p.created_us, p.id
        ''',
        [branch, target.id],
      );
      if (document) {
        return {
          'id': target.id,
          'invoice_number': debt['number'],
          'invoice_type': supplier ? 'purchase' : 'sale',
          'invoice_date': debt['invoice_date'],
          'currency': debt['currency'],
          if (supplier) ...{
            'supplier_name': contact['name'],
            'supplier_phone': contact['phone'],
          } else ...{
            'customer_name': contact['name'],
            'customer_phone': contact['phone'],
          },
          'subtotal': BusinessMoney.display(total),
          'total': BusinessMoney.display(total),
          'paid_amount': BusinessMoney.display(paid),
          'balance': BusinessMoney.display(remaining),
          'status': remaining == 0
              ? 'paid'
              : paid > 0
              ? 'partially_paid'
              : 'confirmed',
          'notes': _openingLabel,
          'items': [
            {
              'id': itemId,
              'description': _openingLabel,
              'quantity': double.parse(quantity),
              'unit_price': price,
              'total': BusinessMoney.display(total),
              'is_service': true,
            },
          ],
          'payments': [
            for (final part in parts)
              {
                'id': part['id'],
                'bank_account_name': part['account_name'],
                'bank_name': part['bank_name'],
                'payment_method': part['method'],
                'payment_date': part['date'],
                'payment_currency': part['payment_currency'],
                'invoice_currency': part['debt_currency'],
                'amount': BusinessMoney.display(part['applied_minor'] as int),
                'original_amount': BusinessMoney.display(
                  part['original_minor'] as int,
                ),
                'exchange_rate': part['exchange_rate'],
              },
          ],
        };
      }
      final changes = await txn.query(
        _edits,
        where: 'branch_id = ? AND invoice_id = ?',
        whereArgs: [branch, target.id],
        orderBy: 'revision',
      );
      return {
        'id': target.id,
        'number': debt['number'],
        'date': debt['invoice_date'],
        'party_name': contact['name'],
        'perspective': party.kind.name,
        'linked':
            false, // Only the unlinked directory is attached to this source.
        'currency': debt['currency'],
        'revision': debt['revision'],
        'total': BusinessMoney.display(total),
        'paid': BusinessMoney.display(paid),
        'remaining': BusinessMoney.display(remaining),
        'is_modified': changes.isNotEmpty,
        'item_changes': [
          for (final change in changes)
            {
              'id': change['command_id'],
              'item_id': itemId,
              'description': _openingLabel,
              'old_quantity': change['old_quantity'],
              'new_quantity': change['new_quantity'],
              'old_unit_price': _displayOptional(change['old_unit_minor']),
              'new_unit_price': _displayOptional(change['new_unit_minor']),
              'changed_at': DateTime.fromMicrosecondsSinceEpoch(
                change['created_us'] as int,
                isUtc: true,
              ).toIso8601String(),
              // This pilot only admits owners, not employee financial writers.
              'changed_by_is_manager': true,
            },
        ],
        'items': [
          {
            'id': itemId,
            'name': _openingLabel,
            'qty': quantity,
            'price': price,
            'total': BusinessMoney.display(total),
          },
        ],
        'payments': [
          for (final part in parts)
            {
              'id': part['id'],
              'method': part['method'],
              'amount': BusinessMoney.display(part['original_minor'] as int),
              'currency': part['payment_currency'],
              'date': part['date'],
            },
        ],
      };
    });
  }

  static String? _displayOptional(Object? value) =>
      value == null ? null : BusinessMoney.display(value as int);

  /// Ordinary documents use the operation and paper screens unchanged.
  Future<Map<String, dynamic>> _commerceOperationView(
    Transaction txn,
    String branch,
    DirectoryPartyReference party,
    Map<String, Object?> contact,
    Map<String, Object?> header,
    String invoiceId,
    bool document,
  ) async {
    final supplier = party.kind == DirectoryPartyKind.supplier;
    final items = await _commerceRows(
      txn, _commerceLines, branch, 'invoice_id', invoiceId,
    );
    final parts = await txn.rawQuery(
      '''
      SELECT p.*, a.account_name, a.bank_name FROM ${_commercePayments} p
      LEFT JOIN ${BusinessLedger._accounts} a ON a.branch_id = p.branch_id AND a.id = p.account_id
      WHERE p.branch_id = ? AND p.invoice_id = ?
      ORDER BY p.date, p.created_us, p.id
      ''',
      [branch, invoiceId],
    );
    final total = header['total_minor'] as int;
    final paid = header['paid_minor'] as int;
    final remaining = header['balance_minor'] as int;
    if (document) {
      return {
        'id': invoiceId,
        'invoice_number': header['number'],
        'invoice_type': supplier ? 'purchase' : 'sale',
        'invoice_date': header['date'],
        'currency': header['currency'],
        if (supplier) ...{
          'supplier_name': contact['name'],
          'supplier_phone': contact['phone'],
        } else ...{
          'customer_name': contact['name'],
          'customer_phone': contact['phone'],
        },
        'subtotal': BusinessMoney.display(header['subtotal_minor'] as int),
        'total': BusinessMoney.display(total),
        'paid_amount': BusinessMoney.display(paid),
        'balance': BusinessMoney.display(remaining),
        'status': header['status'],
        'notes': header['notes'],
        'items': [
          for (final item in items)
            {
              'id': item['id'],
              'description': item['description'],
              'quantity': double.parse(
                commerceMicroDecimal(item['quantity_micro'] as int),
              ),
              'unit_price': BusinessMoney.display(item['unit_minor'] as int),
              'total': BusinessMoney.display(item['total_minor'] as int),
              'is_service': item['is_service'] == 1,
            },
        ],
        'payments': [
          for (final part in parts)
            {
              'id': part['id'],
              'bank_account_name': part['account_name'],
              'bank_name': part['bank_name'],
              'payment_method': part['method'],
              'payment_date': part['date'],
              'payment_currency': part['payment_currency'],
              'invoice_currency': part['debt_currency'],
              'amount': BusinessMoney.display(part['applied_minor'] as int),
              'original_amount': BusinessMoney.display(
                part['original_minor'] as int,
              ),
              'exchange_rate': part['exchange_rate'],
            },
        ],
      };
    }
    final changes = await txn.query(
      _commerceEdits,
      where: 'branch_id = ? AND invoice_id = ?',
      whereArgs: [branch, invoiceId],
      orderBy: 'created_us, id',
    );
    return {
      'id': invoiceId,
      'number': header['number'],
      'date': header['date'],
      'party_name': contact['name'],
      'perspective': party.kind.name,
      'linked': false,
      'currency': header['currency'],
      'revision': changes.length,
      'total': BusinessMoney.display(total),
      'paid': BusinessMoney.display(paid),
      'remaining': BusinessMoney.display(remaining),
      'is_modified': changes.isNotEmpty,
      'item_changes': [
        for (final change in changes)
          {
            'id': change['id'],
            'item_id': change['item_id'],
            'description': change['description'],
            'old_quantity': change['old_quantity_micro'] == null
                ? null
                : commerceMicroDecimal(change['old_quantity_micro'] as int),
            'new_quantity': change['new_quantity_micro'] == null
                ? null
                : commerceMicroDecimal(change['new_quantity_micro'] as int),
            'old_unit_price': _displayOptional(change['old_unit_minor']),
            'new_unit_price': _displayOptional(change['new_unit_minor']),
            'changed_at': DateTime.fromMicrosecondsSinceEpoch(
              change['created_us'] as int,
              isUtc: true,
            ).toIso8601String(),
            'changed_by_is_manager': true,
          },
      ],
      'items': [
        for (final item in items)
          {
            'id': item['id'],
            'name': item['description'],
            'qty': commerceMicroDecimal(item['quantity_micro'] as int),
            'price': BusinessMoney.display(item['unit_minor'] as int),
            'total': BusinessMoney.display(item['total_minor'] as int),
          },
      ],
      'payments': [
        for (final part in parts)
          {
            'id': part['id'],
            'method': part['method'],
            'amount': BusinessMoney.display(part['original_minor'] as int),
            'currency': part['payment_currency'],
            'date': part['date'],
          },
      ],
    };
  }

  Future<Map<String, Object?>> editOpeningDebt(
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target, {
    required String commandId,
    required String itemId,
    required int revision,
    required BusinessOpeningDebtLine line,
  }) {
    final branch = _branch(access, BusinessLedgerAction.editDebtInvoice);
    final party = target.party;
    party.requireScope(access.directory, write: true);
    return _commit(
      branch,
      commandId,
      [
        'edit_opening',
        party.kind.name,
        party.id,
        target.id,
        revision,
        line.quantity,
        line.unitMinor,
        if (itemId != target.id) itemId,
      ],
      (txn, now) async {
        final commerce = (await txn.query(
          _commerceInvoices,
          columns: ['id'],
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, target.id],
        )).singleOrNull;
        if (commerce != null) {
          return editCommerceDocumentLine(
            txn, access, target, commandId, branch, itemId, revision, line, now,
          );
        }
        final debt = await _debtTarget(txn, access, target);
        if (itemId != (debt['opening_item_id'] ?? target.id)) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
        }
        if (debt['revision'] != revision) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invoiceChanged);
        }
        final oldQuantity = debt['opening_quantity'] as String;
        final oldPrice =
            (debt['opening_unit_minor'] ?? debt['total_minor']) as int;
        final quantityChanged = oldQuantity != line.quantity;
        final priceChanged = oldPrice != line.unitMinor;
        if (!quantityChanged && !priceChanged) {
          throw const BusinessLedgerError(BusinessLedgerProblem.noChanges);
        }
        final revisionAfter = revision + 1;
        await txn.update(
          BusinessLedger._debts,
          {
            'opening_quantity': line.quantity,
            'opening_unit_minor': line.unitMinor,
            'total_minor': line.totalMinor,
            'revision': revisionAfter,
          },
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, target.id],
        );
        await txn.insert(_edits, {
          'branch_id': branch,
          'command_id': commandId,
          'invoice_id': target.id,
          'revision': revisionAfter,
          'account_id': access.directory.workspace.accountId,
          if (quantityChanged) ...{
            'old_quantity': oldQuantity,
            'new_quantity': line.quantity,
          },
          if (priceChanged) ...{
            'old_unit_minor': oldPrice,
            'new_unit_minor': line.unitMinor,
          },
          'created_us': now.toUtc().microsecondsSinceEpoch,
        });
        return {'id': target.id, 'revision': revisionAfter};
      },
    );
  }

  /// Reverse only the amounts applied to this invoice, in the original
  /// account currency. Surplus advances and sibling invoices stay posted.
  Future<Map<String, Object?>> deleteOpeningDebt(
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target, {
    required String commandId,
    required int revision,
  }) {
    final branch = _branch(access, BusinessLedgerAction.deleteDebtInvoice);
    final party = target.party;
    party.requireScope(access.directory, write: true);
    return _commit(
      branch,
      commandId,
      ['delete_opening', party.kind.name, party.id, target.id, revision],
      (txn, now) async {
        final commerce = (await txn.query(
          _commerceInvoices,
          columns: ['id'],
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, target.id],
        )).singleOrNull;
        if (commerce != null) {
          return deleteCommerceDocument(
            txn, access, target, commandId, branch, revision, now,
          );
        }
        final debt = await _debtTarget(txn, access, target);
        if (debt['revision'] != revision) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invoiceChanged);
        }
        final refunds = await txn.rawQuery(
          '''
          SELECT account_id, payment_currency, SUM(original_minor) AS amount_minor
           FROM ${BusinessLedger._paymentHistory}
           WHERE branch_id = ? AND invoice_id = ? AND account_id IS NOT NULL
          GROUP BY account_id, payment_currency ORDER BY account_id
        ''',
          [branch, target.id],
        );
        for (final refund in refunds) {
          final id = refund['account_id'] as String;
          final amount = refund['amount_minor'] as int;
          if (amount == 0) continue;
          final account = await _account(
            txn,
            branch,
            id,
            allowClosed: true,
            allowInactive: true,
          );
          await cashSync._requirePrivate(txn, branch, id);
          if (account['currency'] != refund['payment_currency']) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.currencyMismatch,
            );
          }
          final delta = party.kind == DirectoryPartyKind.supplier
              ? amount
              : -amount;
          await _post(
            txn,
            branch,
            commandId,
            id,
            now,
            kind: 'invoice_cancel',
            delta: delta,
            next: BusinessLedger._balance(account, delta),
            description: 'إلغاء فاتورة ${debt['number']}',
            reference: 'cancel:${target.id}',
          );
        }
        await txn.update(
          BusinessLedger._debts,
          {
            'cancelled_us': now.toUtc().microsecondsSinceEpoch,
            'revision': revision + 1,
          },
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, target.id],
        );
        return {'id': target.id, 'deleted': true};
      },
    );
  }
}
