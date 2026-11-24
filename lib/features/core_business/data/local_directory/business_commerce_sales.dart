part of 'directory_database.dart';

/// One line of an ordinary sale/purchase document. Quantities and prices are
/// exact decimal strings; the device never converts them through doubles.
final class CommerceIssueLine {
  const CommerceIssueLine({
    required this.description,
    required this.quantity,
    required this.unitMinor,
    this.discountMinor = 0,
    this.productId,
    this.unitId,
    this.factor,
    this.isService = false,
    this.expiryDate,
    this.lotNumber,
    this.image,
    this.newProduct,
    this.originalUnitMinor,
    this.priceCurrency,
    this.priceRate,
  });

  final String description;
  final String quantity;
  final int unitMinor;
  final int discountMinor;
  final String? productId;
  final String? unitId;
  final String? factor;
  final bool isService;
  final String? expiryDate;
  final String? lotNumber;
  final String? image;
  final Map<String, Object?>? newProduct;
  final int? originalUnitMinor;
  final String? priceCurrency;
  final BusinessRate? priceRate;
}

/// Money received/paid on issue. [originalMinor] is in [paymentCurrency]; a
/// cross-currency payment carries the frozen quote used at issue time.
final class CommerceIssuePayment {
  const CommerceIssuePayment({
    required this.accountId,
    required this.originalMinor,
    required this.paymentCurrency,
    this.method = 'bank',
    this.rate,
  });

  final String accountId;
  final int originalMinor;
  final String paymentCurrency;
  final String method;
  final BusinessRate? rate;
}

final class CommerceReturnLine {
  const CommerceReturnLine({
    required this.itemId,
    required this.quantity,
    this.restock = true,
  });

  final String itemId;
  final String quantity;
  final bool restock;
}

/// Ordinary invoices and their returns, written atomically to SQLCipher with
/// the same totals, stock and money effects as the connected invoice engine.
/// Re-running the same command returns the same document; no REST, no spinner.
extension BusinessCommerceSales on BusinessLedger {
  static const _documentLabel = 'fyona.commerce.document.v1';
  static const _returnLabel = 'fyona.commerce.return.v1';

  Future<Map<String, Object?>> issueCommerceDocument(
    BusinessLedgerAccess access, {
    required BusinessInvoiceKind kind,
    required String commandId,
    required String currency,
    String? partyId,
    String? groupId,
    String? discountType,
    int discountValue2 = 0,
    String? taxType,
    int taxRate2 = 0,
    String? notes,
    String? dueDate,
    required List<CommerceIssueLine> lines,
    List<CommerceIssuePayment> payments = const [],
  }) {
    final supplier = kind == BusinessInvoiceKind.purchase;
    final branch = _branch(access, BusinessLedgerAction.issueDocument);
    final money = businessCurrency(currency);
    if (lines.isEmpty || lines.length > 500) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    if (discountValue2 < 0 || taxRate2 < 0) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    for (final type in {discountType, taxType}) {
      if (type != null && !const {'percentage', 'fixed'}.contains(type)) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
      }
    }
    return _commit(
      branch,
      commandId,
      [
        'issue_document',
        kind.name,
        money,
        partyId,
        groupId,
        discountType,
        discountValue2,
        taxType,
        taxRate2,
        notes,
        dueDate,
        for (final line in lines)
          [
            line.description,
            line.quantity,
            line.unitMinor,
            line.discountMinor,
            line.productId,
            line.unitId,
            line.factor,
            line.isService,
            line.expiryDate,
            line.lotNumber,
            if (line.newProduct != null) line.newProduct,
            if (line.priceCurrency != null || line.originalUnitMinor != null)
              [
                line.originalUnitMinor,
                line.priceCurrency,
                line.priceRate?.decimal,
              ],
          ],
        for (final payment in payments)
          [
            payment.accountId,
            payment.originalMinor,
            payment.paymentCurrency,
            payment.method,
            payment.rate?.decimal,
          ],
      ],
      (txn, now) async {
        DirectoryPartyReference? party;
        if (partyId != null) {
          party = DirectoryPartyReference(
            scope: access.directory,
            kind: supplier
                ? DirectoryPartyKind.supplier
                : DirectoryPartyKind.customer,
            id: partyId,
          );
          await _directory._scopedParty(
            txn,
            access.directory,
            party.kind,
            party.id,
          );
          await _requireGroup(txn, branch, party, groupId);
        } else if (groupId != null) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
        }

        final computed = await _computeCommerceLines(
          txn,
          branch,
          kind,
          money,
          lines,
          commandId,
          now,
        );
        final totals = _commerceTotals(
          computed,
          discountType,
          discountValue2,
          taxType,
          taxRate2,
        );
        if (totals.total < 0) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
        }

        var paid = 0;
        final resolved = <String, _CommercePaid>{};
        for (final payment in payments) {
          if (!const {
            'cash',
            'bank',
            'card',
            'transfer',
            'cheque',
          }.contains(payment.method)) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidAccount,
            );
          }
          final payMoney = businessCurrency(payment.paymentCurrency);
          final account = await _account(txn, branch, payment.accountId);
          await cashSync._requirePrivate(txn, branch, payment.accountId);
          if (account['currency'] != payMoney || payment.originalMinor <= 0) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.currencyMismatch,
            );
          }
          final same = payMoney == money;
          final applied = BusinessLedger._convert(
            payment.originalMinor,
            payMoney,
            money,
            payment.rate,
          );
          BusinessLedger._amount(applied);
          paid = paid + applied;
          // One account, one command: several rows for the same account merge
          // into the single bank movement its command key allows.
          final previous = resolved[payment.accountId];
          if (previous == null) {
            resolved[payment.accountId] = _CommercePaid(
              payment,
              payMoney,
              same ? null : payment.rate!,
              payment.originalMinor,
              applied,
            );
          } else {
            if (previous.currency != payMoney ||
                previous.rate?.decimal !=
                    (same ? null : payment.rate!.decimal)) {
              throw const BusinessLedgerError(
                BusinessLedgerProblem.currencyMismatch,
              );
            }
            resolved[payment.accountId] = _CommercePaid(
              payment,
              payMoney,
              previous.rate,
              previous.originalMinor + payment.originalMinor,
              previous.appliedMinor + applied,
            );
          }
        }
        if (paid > totals.total) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
        }
        final balance = totals.total - paid;
        if (balance > 0 && party == null) {
          // A cash document cannot leave an unpaid remainder without a party.
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
        }

        final id = const Uuid().v5(commandId, _documentLabel);
        final date = BusinessLedger._date(now);
        final number =
            '${supplier ? 'PUR' : 'INV'}-${date.replaceAll('-', '')}'
            '-${id.replaceAll('-', '').toUpperCase()}';
        await txn.insert(_commerceInvoices, {
          'branch_id': branch,
          'id': id,
          'number': number,
          'invoice_type': kind.name,
          'party_kind': supplier ? 'supplier' : 'customer',
          'party_id': partyId,
          'group_id': groupId,
          'date': date,
          'due_date': dueDate,
          'currency': money,
          'status': balance == 0
              ? 'paid'
              : (paid > 0 ? 'partially_paid' : 'confirmed'),
          'subtotal_minor': totals.subtotal,
          'discount_type': discountType,
          'discount_value_2': discountValue2,
          'discount_minor': totals.discount,
          'tax_type': taxType,
          'tax_rate_2': taxRate2,
          'tax_minor': totals.tax,
          'total_minor': totals.total,
          'paid_minor': paid,
          'balance_minor': balance,
          'notes': notes,
          'idempotency_key': commandId,
          'created_by': access.directory.workspace.accountId,
          'created_us': now.toUtc().microsecondsSinceEpoch,
          'confirmed_us': now.toUtc().microsecondsSinceEpoch,
        });

        for (var index = 0; index < computed.length; index++) {
          final line = computed[index];
          final itemId = const Uuid().v5(
            commandId,
            'fyona.commerce.line.v1:$index',
          );
          await txn.insert(_commerceLines, {
            'branch_id': branch,
            'id': itemId,
            'invoice_id': id,
            'product_id': line.productId,
            'unit_id': line.unitId,
            'unit_name': line.unitName,
            'description': line.description,
            'quantity_micro': line.quantityMicro,
            'base_micro': line.baseMicro,
            'factor_4': line.factor4,
            'unit_minor': line.unitMinor,
            'discount_minor': line.discountMinor,
            'tax_rate_2': 0,
            'total_minor': line.totalMinor,
            'is_service': line.tracksStock ? 0 : 1,
            'image': line.image,
            'original_minor': line.line.originalUnitMinor ?? line.unitMinor,
            'price_currency': line.line.priceCurrency ?? money,
            'exchange_rate': line.line.priceRate?.decimal,
          });
          if (!line.tracksStock) continue;
          final basePrice = _commerceRatioRound(
            BigInt.from(line.unitMinor) * BigInt.from(10000),
            BigInt.from(line.factor4),
          );
          await _commerceStockEffect(
            txn,
            branch,
            commandId,
            kind,
            line,
            itemId,
            id,
            number,
            basePrice,
            money,
            partyId,
            now,
            access.directory.workspace.accountId,
          );
          if (!supplier) {
            final cost = await _commerceCapturedCost(txn, branch, itemId, money,
                line.line.priceCurrency, line.line.priceRate?.decimal,
                line.baseMicro, outstandingOnly: true);
            await txn.update(_commerceLines, {
              'cost_total_minor': cost,
              'profit_minor': cost == null ? null : line.totalMinor - cost,
            }, where: 'branch_id = ? AND id = ?', whereArgs: [branch, itemId]);
          }
        }

        for (final entry in resolved.values) {
          final payment = entry.payment;
          final delta = supplier ? -entry.originalMinor : entry.originalMinor;
          final account = await _account(txn, branch, payment.accountId);
          final next = BusinessLedger._balance(account, delta);
          if (next < 0 && !await _allowsNegative(txn, branch)) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.insufficientBalance,
            );
          }
          await _post(
            txn,
            branch,
            commandId,
            payment.accountId,
            now,
            kind: supplier ? 'withdrawal' : 'deposit',
            delta: delta,
            next: next,
            description: supplier
                ? 'سداد فاتورة شراء $number'
                : 'تحصيل فاتورة بيع $number',
            reference: number,
          );
          await txn.insert(_commercePayments, {
            'branch_id': branch,
            'id': const Uuid().v5(
              commandId,
              'fyona.commerce.payment.v1:${payment.accountId}:${entry.currency}',
            ),
            'invoice_id': id,
            'account_id': payment.accountId,
            'method': payment.method,
            'date': date,
            'payment_currency': entry.currency,
            'debt_currency': money,
            'exchange_rate': entry.rate?.decimal ?? '1.00000000',
            'original_minor': entry.originalMinor,
            'applied_minor': entry.appliedMinor,
            'created_by': access.directory.workspace.accountId,
            'created_us': now.toUtc().microsecondsSinceEpoch,
          });
        }
        if (balance > 0) {
          await txn.insert(_commerceBalances, {
            'branch_id': branch,
            'id': const Uuid().v5(commandId, 'fyona.commerce.balance.v1'),
            'invoice_id': id,
            'amount_minor': balance,
            'paid_minor': 0,
            'status': 'open',
          });
        }
        return {
          'id': id,
          'number': number,
          'total_minor': totals.total,
          'paid_minor': paid,
          'balance_minor': balance,
        };
      },
    );
  }

  Future<Map<String, Object?>> confirmCommerceReturn(
    BusinessLedgerAccess access, {
    required String commandId,
    required BusinessInvoiceKind kind,
    required String invoiceId,
    required List<CommerceReturnLine> lines,
    String? reason,
    String? refundAccountId,
    int? refundOriginalMinor,
    BusinessRate? refundRate,
    bool allowNegative = false,
    bool rememberAllowNegative = false,
    int? expectedRefundMinor,
    String? expectedAccountCurrency,
  }) {
    final supplier = kind == BusinessInvoiceKind.purchase;
    final branch = _branch(access, BusinessLedgerAction.confirmReturn);
    if (allowNegative) {
      if (supplier) throw const DirectoryAccessDenied();
      _branch(access, BusinessLedgerAction.authorizeReturnOverdraft);
    }
    if (rememberAllowNegative) {
      if (!allowNegative) throw const DirectoryAccessDenied();
      _branch(access, BusinessLedgerAction.changeNegativePolicy);
    }
    if (lines.isEmpty || lines.length > 500) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    return _commit(
      branch,
      commandId,
      [
        'confirm_return',
        kind.name,
        invoiceId,
        reason,
        refundAccountId,
        refundOriginalMinor,
        if (refundRate != null || allowNegative)
          [
            refundRate?.from,
            refundRate?.to,
            refundRate?.decimal,
            allowNegative,
          ],
        if (rememberAllowNegative || expectedRefundMinor != null)
          ['overdraft', rememberAllowNegative, expectedRefundMinor],
        if (expectedAccountCurrency != null) expectedAccountCurrency,
        for (final line in lines) [line.itemId, line.quantity, line.restock],
      ],
      (txn, now) async {
        final header = (await txn.query(
          _commerceInvoices,
          where:
              'branch_id = ? AND id = ? AND invoice_type = ? AND deleted_us IS NULL',
          whereArgs: [branch, invoiceId, kind.name],
        )).singleOrNull;
        if (header == null ||
            const {'draft', 'cancelled'}.contains(header['status'])) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
        }
        final money = header['currency'] as String;
        final items = {
          for (final row in await _commerceRows(
            txn,
            _commerceLines,
            branch,
            'invoice_id',
            invoiceId,
          ))
            row['id'] as String: row,
        };
        final already = <String, int>{};
        for (final row in await _commerceRows(
          txn,
          _commerceReturnLines,
          branch,
          'invoice_id',
          invoiceId,
        )) {
          final ret = (await txn.query(
            _commerceReturns,
            columns: ['status'],
            where: 'branch_id = ? AND id = ?',
            whereArgs: [branch, row['return_id']],
          )).singleOrNull;
          if (ret?['status'] != 'confirmed') continue;
          final item = row['item_id'] as String;
          already[item] = (already[item] ?? 0) + (row['quantity_micro'] as int);
        }

        final returnId = const Uuid().v5(commandId, _returnLabel);
        final date = BusinessLedger._date(now);
        final number =
            '${supplier ? 'PRT' : 'RTN'}-${date.replaceAll('-', '')}'
            '-${returnId.replaceAll('-', '').toUpperCase()}';
        var total = 0;
        final prepared = <_CommerceReturned>[];
        final selected = <String>{};
        for (final line in lines) {
          final item = items[line.itemId];
          if (item == null || !selected.add(line.itemId)) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidInvoice,
            );
          }
          final soldMicro = item['quantity_micro'] as int;
          final returned = already[line.itemId] ?? 0;
          final quantityMicro = _commerceMicro(line.quantity);
          if (quantityMicro <= 0 || returned + quantityMicro > soldMicro) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidAmount,
            );
          }
          already[line.itemId] = returned + quantityMicro;
          // Prorate the line discount exactly as the connected return engine:
          // return value = quantity × unit price − discount × returned ratio.
          final lineTotal = BusinessMoney.returnLineMinor(
            quantityMicro: quantityMicro,
            soldMicro: soldMicro,
            unitMinor: item['unit_minor'] as int,
            discountMinor: item['discount_minor'] as int,
          );
          total += lineTotal;
          prepared.add(_CommerceReturned(line, item, quantityMicro, lineTotal));
        }
        final paid = header['paid_minor'] as int;
        var balance = header['balance_minor'] as int;
        final apply = min(total, balance);
        final remainder = total - apply;
        if (expectedRefundMinor != null && expectedRefundMinor != remainder) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invoiceChanged);
        }
        var moveMinor = 0;
        int? nextBankBalance;
        String? accountCurrency;
        if (remainder > 0) {
          if (refundAccountId == null) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidAccount,
            );
          }
          final account = await _account(txn, branch, refundAccountId);
          await cashSync._requirePrivate(txn, branch, refundAccountId);
          accountCurrency = account['currency'] as String;
          if (expectedAccountCurrency != null && expectedAccountCurrency != accountCurrency) {
            throw const BusinessLedgerError(BusinessLedgerProblem.accountChanged);
          }
          moveMinor = remainder;
          if (accountCurrency != money) {
            if (refundRate == null) {
              throw const BusinessLedgerError(
                BusinessLedgerProblem.missingRate,
              );
            }
            if (refundRate.from != accountCurrency || refundRate.to != money) {
              throw const BusinessLedgerError(
                BusinessLedgerProblem.currencyMismatch,
              );
            }
            moveMinor = refundRate.original(remainder);
            if (refundOriginalMinor != null && refundOriginalMinor != moveMinor) {
              throw const BusinessLedgerError(BusinessLedgerProblem.invoiceChanged);
            }
          }
          BusinessLedger._amount(moveMinor);
          final delta = supplier ? moveMinor : -moveMinor;
          nextBankBalance = BusinessLedger._balance(account, delta);
          if (!supplier && (nextBankBalance < 0 || rememberAllowNegative) &&
              !await _allowsNegative(txn, branch)) {
            if (nextBankBalance < 0 && !allowNegative) {
              // Nothing has been posted yet. Even if the picker had a stale
              // balance, the dialog is only a response to this atomic check.
              if (access._actions.contains(BusinessLedgerAction.authorizeReturnOverdraft)) {
                throw BusinessReturnOverdraft(moveMinor);
              }
              throw const BusinessLedgerError(BusinessLedgerProblem.insufficientBalance);
            }
            // The account could receive money while the dialog is open.
            // Honor "always" for the same verified refund even then.
            if (rememberAllowNegative) await _setNegativePolicy(txn, branch, true);
          }
        }
        balance -= apply;
        if (remainder > paid) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
        }
        final paidAfter = paid - remainder;
        await txn.update(
          _commerceInvoices,
          {
            'balance_minor': balance,
            'paid_minor': paidAfter,
            'status': balance == 0
                ? 'paid'
                : (paidAfter > 0 ? 'partially_paid' : 'confirmed'),
          },
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, invoiceId],
        );
        await txn.insert(_commerceReturns, {
          'branch_id': branch,
          'id': returnId,
          'invoice_id': invoiceId,
          'invoice_type': kind.name,
          'number': number,
          'date': date,
          'status': 'confirmed',
          'total_minor': total,
          'reason': reason,
          'created_by': access.directory.workspace.accountId,
          'created_us': now.toUtc().microsecondsSinceEpoch,
        });

        final balanceRow = (await txn.query(
          _commerceBalances,
          where: 'branch_id = ? AND invoice_id = ?',
          whereArgs: [branch, invoiceId],
        )).singleOrNull;
        if (balanceRow != null) {
          final balancePaid = balanceRow['paid_minor'] as int;
          await txn.update(
            _commerceBalances,
            {
              'amount_minor': balance + balancePaid,
              'status': balance == 0 ? 'paid' : (balancePaid > 0 ? 'partial' : 'open'),
            },
            where: 'branch_id = ? AND invoice_id = ?',
            whereArgs: [branch, invoiceId],
          );
        }

        for (var index = 0; index < prepared.length; index++) {
          final entry = prepared[index];
          final item = entry.item;
          await txn.insert(_commerceReturnLines, {
            'branch_id': branch,
            'id': const Uuid().v5(
              commandId,
              'fyona.commerce.return.line.v1:$index',
            ),
            'return_id': returnId,
            'invoice_id': invoiceId,
            'item_id': entry.line.itemId,
            'product_id': item['product_id'],
            'description': item['description'],
            'quantity_micro': entry.quantityMicro,
            'unit_minor': item['unit_minor'],
            'total_minor': entry.totalMinor,
          });
          if (item['product_id'] == null || item['is_service'] == 1) continue;
          final factor4 = (item['factor_4'] as int?) ?? 10000;
          final baseMicro = _commerceRatioRound(
            BigInt.from(entry.quantityMicro) * BigInt.from(factor4),
            BigInt.from(10000),
          );
          final basePrice = _commerceRatioRound(
            BigInt.from(item['unit_minor'] as int) * BigInt.from(10000),
            BigInt.from(factor4),
          );
          await _commerceReturnStockEffect(
            txn,
            branch,
            kind,
            entry,
            baseMicro,
            basePrice,
            money,
            returnId,
            now,
            access.directory.workspace.accountId,
          );
        }

        if (nextBankBalance != null) {
          final delta = supplier ? moveMinor : -moveMinor;
          await _post(
            txn,
            branch,
            commandId,
            refundAccountId!,
            now,
            kind: supplier ? 'deposit' : 'withdrawal',
            delta: delta,
            next: nextBankBalance,
            rate: accountCurrency == money ? null : refundRate,
            description: supplier
                ? 'استرداد مرتجع شراء $number'
                : 'استرداد مرتجع $number',
            reference: number,
          );
        }
        return {
          'id': returnId,
          'number': number,
          'invoice_id': invoiceId,
          'total_minor': total,
          'applied_minor': apply,
          'refunded_minor': remainder,
          if (nextBankBalance != null) ...{
            'refund_account_id': refundAccountId,
            'refund_currency': accountCurrency,
            'refund_original_minor': moveMinor,
          },
        };
      },
    );
  }

  Future<List<_CommerceLineMath>> _computeCommerceLines(
    Transaction txn,
    String branch,
    BusinessInvoiceKind kind,
    String money,
    List<CommerceIssueLine> lines,
    String commandId,
    DateTime now,
  ) async {
    final supplier = kind == BusinessInvoiceKind.purchase;
    final computed = <_CommerceLineMath>[];
    for (final (index, line) in lines.indexed) {
      final quick = line.newProduct;
      if (quick != null && (line.productId != null || line.unitId != null)) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
      }
      final description = line.description.trim().isEmpty
          ? '${quick?['name'] ?? ''}'.trim()
          : line.description.trim();
      if (description.isEmpty || description.runes.length > 500) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
      }
      final quantityMicro = _commerceMicro(line.quantity);
      if (quantityMicro <= 0 || line.unitMinor < 0 || line.discountMinor < 0) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
      }
      var productRow = line.productId;
      var unitId = line.unitId;
      var image = line.image;
      String? unitName;
      int factor4;
      var service = line.isService;
      if (quick != null &&
          quick['save_to_inventory'] != false &&
          quick['is_service'] != true) {
        (productRow, unitId) = await _quickCommerceProduct(
          txn,
          branch,
          commandId,
          index,
          money,
          line,
          quick,
          now,
          purchase: supplier,
        );
        service = false;
      }
      if (productRow != null) {
        final product = (await txn.query(
          _commerceProducts,
          columns: ['id', 'is_service', 'unit', 'image'],
          where:
              'branch_id = ? AND id = ? AND deleted_us IS NULL AND is_active = 1',
          whereArgs: [branch, productRow],
        )).singleOrNull;
        if (product == null) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
        }
        service = product['is_service'] == 1;
        unitName = product['unit'] as String?;
        if (unitId != null) {
          final unit = (await txn.query(
            _commerceUnits,
            columns: ['id', 'factor_4', 'name', 'image'],
            where:
                'branch_id = ? AND product_id = ? AND id = ? AND is_active = 1',
            whereArgs: [branch, productRow, unitId],
          )).singleOrNull;
          if (unit == null) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidProduct,
            );
          }
          factor4 = unit['factor_4'] as int;
          unitName = unit['name'] as String;
          // The unit's own photo (a carton) is the line's picture.
          image ??= _deviceInventoryImage(unit['image']);
        } else if (line.factor != null) {
          factor4 = _commerceFactor4(line.factor!);
        } else {
          factor4 = 10000;
        }
        image ??= product['image'] as String?;
      } else {
        if (quick != null) {
          service = true;
          unitName = _commerceName('${quick['unit'] ?? 'خدمة'}');
        }
        if (line.unitId != null || (line.factor != null && !service)) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
        }
        factor4 = line.factor == null ? 10000 : _commerceFactor4(line.factor!);
      }
      final numerator =
          BigInt.from(quantityMicro) * BigInt.from(line.unitMinor) -
          BigInt.from(line.discountMinor) * BigInt.from(1000000);
      final totalMinor = _commerceRatioRound(numerator, BigInt.from(1000000));
      if (totalMinor < 0) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
      }
      final baseMicro = _commerceRatioRound(
        BigInt.from(quantityMicro) * BigInt.from(factor4),
        BigInt.from(10000),
      );
      if (productRow != null && !service && baseMicro == 0) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
      }
      computed.add(
        _CommerceLineMath(
          line: line,
          description: description,
          productId: productRow,
          unitId: unitId,
          unitName: unitName,
          quantityMicro: quantityMicro,
          baseMicro: baseMicro,
          factor4: factor4,
          unitMinor: line.unitMinor,
          discountMinor: line.discountMinor,
          totalMinor: totalMinor,
          tracksStock: productRow != null && !service,
          image: image,
          supplier: supplier,
        ),
      );
    }
    return computed;
  }

  Future<void> _commerceStockEffect(
    Transaction txn,
    String branch,
    String commandId,
    BusinessInvoiceKind kind,
    _CommerceLineMath line,
    String itemId,
    String invoiceId,
    String number,
    int basePrice,
    String money,
    String? partyId,
    DateTime now,
    String actor,
  ) async {
    final supplier = kind == BusinessInvoiceKind.purchase;
    final product = line.productId!;
    final when = now.toUtc().microsecondsSinceEpoch;
    final stockRow = (await _commerceRows(
      txn,
      _commerceStock,
      branch,
      'product_id',
      product,
    )).singleOrNull;
    final oldMilli = stockRow?['quantity_milli'] as int? ?? 0;
    final deltaMilli = _commerceRatioRound(
      BigInt.from(line.baseMicro) * BigInt.from(supplier ? 1 : -1),
      BigInt.from(1000),
    );
    if (supplier) {
      final cost4 = _commerceRatioRound(
        BigInt.from(line.totalMinor) * BigInt.from(100000000),
        BigInt.from(line.baseMicro),
      );
      await _receiveInventoryBatch(
        txn, branch: branch,
        id: const Uuid().v5(commandId, 'fyona.commerce.lot.v1:$itemId'),
        product: product, quantity: line.baseMicro, source: 'purchase', now: now,
        cost4: cost4, currency: money, supplierId: partyId, invoiceId: invoiceId,
        itemId: itemId, unitId: line.unitId, expiryDate: line.line.expiryDate,
        lotNumber: line.line.lotNumber,
      );
      if (stockRow == null) {
        await txn.insert(_commerceStock, {
          'branch_id': branch,
          'id': const Uuid().v5(commandId, 'fyona.commerce.stock.v1:$product'),
          'product_id': product,
          'quantity_milli': oldMilli + deltaMilli,
          'avg_cost_4': cost4,
        });
      } else {
        final oldQty = oldMilli;
        final avg = stockRow['avg_cost_4'] as int;
        final newQty = oldQty + deltaMilli;
        // Weighted average on receipts, exactly as branch stock does.
        final merged = newQty > 0
            ? _commerceRatioRound(
                BigInt.from(oldQty) * BigInt.from(avg) +
                    BigInt.from(deltaMilli) * BigInt.from(cost4),
                BigInt.from(newQty),
              )
            : avg;
        await txn.update(
          _commerceStock,
          {'quantity_milli': newQty, 'avg_cost_4': merged},
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, stockRow['id']],
        );
      }
    } else {
      if (oldMilli * 1000 < line.baseMicro || oldMilli + deltaMilli < 0) {
        throw const BusinessLedgerError(
          BusinessLedgerProblem.insufficientStock,
        );
      }
      await _consumeCommerceLots(
        txn,
        branch,
        commandId,
        product,
        line.baseMicro,
        now,
        saleItemId: itemId,
      );
      if (stockRow != null) {
        await txn.update(
          _commerceStock,
          {'quantity_milli': oldMilli + deltaMilli},
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, stockRow['id']],
        );
      } else {
        await txn.insert(_commerceStock, {
          'branch_id': branch,
          'id': const Uuid().v5(commandId, 'fyona.commerce.stock.v1:$product'),
          'product_id': product,
          'quantity_milli': oldMilli + deltaMilli,
          'avg_cost_4': 0,
        });
      }
    }
    await txn.insert(_commerceMovements, {
      'branch_id': branch,
      'id': const Uuid().v5(commandId, 'fyona.commerce.movement.v1:$itemId'),
      'product_id': product,
      'movement_type': supplier ? 'purchase' : 'sale',
      'quantity_micro': line.baseMicro * (supplier ? 1 : -1),
      'unit_minor': basePrice,
      'total_minor': line.totalMinor,
      'currency': money,
      'reference_type': 'invoice',
      'reference_id': invoiceId,
      'notes': supplier ? 'شراء $number' : 'بيع $number',
      'created_by': actor,
      'created_us': when,
    });
  }

  Future<void> _consumeCommerceLots(
    Transaction txn,
    String branch,
    String commandId,
    String product,
    int needMicro,
    DateTime now, {
    String? saleItemId,
    String? preferredPurchaseItem,
  }) async {
    var pending = needMicro;
    // Oldest receipt first even when later stock has an earlier expiry.
    // A supplier return first draws from the referenced receipt, then from
    // the other available batches for the same product if necessary.
    final lots = await _availableInventoryLots(txn, branch, product,
        preferredPurchaseItem: preferredPurchaseItem);
    final sliceKey = saleItemId ?? preferredPurchaseItem ?? product;
    Future<void> record(String id, int qty, int cost4, String? currency) =>
        txn.insert(_commerceConsumptions, {
          'branch_id': branch,
          'id': const Uuid().v5(commandId, 'fyona.commerce.consume.v1:$id:$sliceKey'),
          'lot_id': id,
          'item_id': saleItemId,
          'quantity_micro': qty,
          'unit_cost_4': cost4,
          'currency': currency,
          'created_us': now.microsecondsSinceEpoch,
        });
    for (final lot in lots) {
      if (pending == 0) break;
      final take = min(lot['remaining_micro'] as int, pending);
      await txn.update(
        _commerceLots,
        {'remaining_micro': (lot['remaining_micro'] as int) - take},
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, lot['id']],
      );
      await record(lot['id'] as String, take, lot['unit_cost_4'] as int,
          lot['currency'] as String?);
      pending -= take;
    }
    if (pending > 0) {
      // Stock was already validated. Unattributed legacy units can have a
      // consumption record for an exact future return, but aren't a receipt.
      final lotId = const Uuid().v5(
        commandId,
        'fyona.commerce.cover.v1:$sliceKey',
      );
      await txn.insert(_commerceLots, {
        'branch_id': branch,
        'id': lotId,
        'product_id': product,
        'received_micro': pending,
        'remaining_micro': 0,
        'unit_cost_4': 0,
        'source': 'legacy_cover',
        'created_us': now.microsecondsSinceEpoch,
      });
      await record(lotId, pending, 0, null);
    }
  }

  Future<void> _commerceReturnStockEffect(
    Transaction txn,
    String branch,
    BusinessInvoiceKind kind,
    _CommerceReturned entry,
    int baseMicro,
    int basePrice,
    String money,
    String returnId,
    DateTime now,
    String actor,
  ) async {
    final supplier = kind == BusinessInvoiceKind.purchase;
    final product = entry.item['product_id'] as String;
    final when = now.toUtc().microsecondsSinceEpoch;
    final movementType = supplier
        ? (entry.line.restock ? 'purchase_return' : 'purchase_return_no_stock')
        : (entry.line.restock ? 'sale_return' : 'sale_return_no_stock');
    if (entry.line.restock) {
      final stockRow = (await _commerceRows(
        txn,
        _commerceStock,
        branch,
        'product_id',
        product,
      )).singleOrNull;
      final deltaMilli = _commerceRatioRound(
        BigInt.from(baseMicro) * BigInt.from(supplier ? -1 : 1),
        BigInt.from(1000),
      );
      final old = stockRow?['quantity_milli'] as int? ?? 0;
      if (supplier && (old * 1000 < baseMicro || old + deltaMilli < 0)) {
        throw const BusinessLedgerError(BusinessLedgerProblem.insufficientStock);
      }
      if (stockRow != null) {
        await txn.update(
          _commerceStock,
          {'quantity_milli': old + deltaMilli},
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, stockRow['id']],
        );
      } else if (deltaMilli > 0) {
        await txn.insert(_commerceStock, {
          'branch_id': branch,
          'id': const Uuid().v5(returnId, 'stock:$product'),
          'product_id': product,
          'quantity_milli': deltaMilli,
          'avg_cost_4': 0,
        });
      }
      if (supplier) {
        await _consumeCommerceLots(txn, branch, returnId, product, baseMicro,
            now, preferredPurchaseItem: entry.line.itemId);
      } else {
        await _markRestoredSlices(txn, branch, entry.line.itemId, baseMicro);
      }
    }
    await txn.insert(_commerceMovements, {
      'branch_id': branch,
      'id': const Uuid().v5(
        returnId,
        'fyona.commerce.return.movement.v1:${entry.line.itemId}',
      ),
      'product_id': product,
      'movement_type': movementType,
      'quantity_micro': baseMicro * (supplier ? -1 : 1),
      'unit_minor': basePrice,
      'total_minor': entry.totalMinor,
      'currency': money,
      'reference_type': supplier ? 'purchase_return' : 'invoice_return',
      'reference_id': returnId,
      'created_by': actor,
      'created_us': when,
    });
  }

  /// Edit one ordinary line exactly like the connected debt-invoice adjust:
  /// line and header totals move, the audit records before → after, stock
  /// follows the quantity delta, and the unpaid remainder is recomputed.
  Future<Map<String, Object?>> editCommerceDocumentLine(
    Transaction txn,
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target,
    String commandId,
    String branch,
    String itemId,
    int revision,
    BusinessOpeningDebtLine line,
    DateTime now,
  ) async {
    final supplier = target.party.kind == DirectoryPartyKind.supplier;
    final header = await _commerceOwned(txn, branch, target, supplier);
    final item = (await txn.query(
      _commerceLines,
      where: 'branch_id = ? AND invoice_id = ? AND id = ?',
      whereArgs: [branch, target.id, itemId],
    )).singleOrNull;
    if (item == null) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    await _requireCommerceRevision(txn, branch, target.id, revision);
    final oldQuantity = item['quantity_micro'] as int;
    final oldUnit = item['unit_minor'] as int;
    final newQuantity = _commerceMicro(line.quantity);
    final newUnit = line.unitMinor;
    if (newQuantity <= 0 || newUnit < 0) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    if (oldQuantity == newQuantity && oldUnit == newUnit) {
      throw const BusinessLedgerError(BusinessLedgerProblem.noChanges);
    }
    final returned = await txn.rawQuery('''
      SELECT 1 FROM $_commerceReturnLines r JOIN $_commerceReturns h
        ON h.branch_id = r.branch_id AND h.id = r.return_id
      WHERE r.branch_id = ? AND r.item_id = ? AND h.status = 'confirmed' LIMIT 1
    ''', [branch, itemId]);
    if (returned.isNotEmpty) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    final numerator =
        BigInt.from(newQuantity) * BigInt.from(newUnit) -
        BigInt.from(item['discount_minor'] as int) * BigInt.from(1000000);
    final newTotal = _commerceRatioRound(numerator, BigInt.from(1000000));
    if (newTotal < 0) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    final factor4 = (item['factor_4'] as int?) ?? 10000;
    final oldBase = item['base_micro'] as int;
    final newBase = _commerceRatioRound(
      BigInt.from(newQuantity) * BigInt.from(factor4),
      BigInt.from(10000),
    );
    final basePrice = _commerceRatioRound(
      BigInt.from(newUnit) * BigInt.from(10000),
      BigInt.from(factor4),
    );
    if (item['product_id'] != null &&
        item['is_service'] != 1 &&
        oldBase != newBase) {
      await _commerceQuantityDelta(
        txn,
        branch,
        commandId,
        supplier,
        item['product_id'] as String,
        itemId,
        oldBase,
        newBase,
        basePrice,
        header,
        item,
        now,
      );
    }
    final cost = !supplier && item['is_service'] != 1 && oldBase != newBase
        ? await _commerceCapturedCost(txn, branch, itemId,
            header['currency'] as String, item['price_currency'] as String?,
            item['exchange_rate'] as String?, newBase, outstandingOnly: true)
        : item['cost_total_minor'] as int?;
    await txn.update(
      _commerceLines,
      {
        'quantity_micro': newQuantity,
        'unit_minor': newUnit,
        'total_minor': newTotal,
        'base_micro': newBase,
        if (!supplier) ...{
          'cost_total_minor': cost,
          'profit_minor': cost == null ? null : newTotal - cost,
        },
      },
      where: 'branch_id = ? AND id = ?',
      whereArgs: [branch, itemId],
    );
    await txn.insert(_commerceEdits, {
      'branch_id': branch,
      'id': const Uuid().v5(commandId, 'fyona.commerce.edit.v1'),
      'invoice_id': target.id,
      'item_id': itemId,
      'description': item['description'],
      if (oldQuantity != newQuantity) ...{
        'old_quantity_micro': oldQuantity,
        'new_quantity_micro': newQuantity,
      },
      if (oldUnit != newUnit) ...{
        'old_unit_minor': oldUnit,
        'new_unit_minor': newUnit,
      },
      'changed_by': access.directory.workspace.accountId,
      'created_us': now.toUtc().microsecondsSinceEpoch,
    });
    final balance = await _recomputeCommerceDocument(
      txn,
      branch,
      target.id,
      header,
    );
    return {
      'id': target.id,
      'revision': revision + 1,
      'balance_minor': balance,
    };
  }

  /// Delete an ordinary document with full reversal: applied money returns to
  /// its accounts, product quantities go back (or their unconsumed purchase
  /// lots are removed), and the document stays as a cancelled audit record.
  Future<Map<String, Object?>> deleteCommerceDocument(
    Transaction txn,
    BusinessLedgerAccess access,
    DirectoryDebtInvoiceReference target,
    String commandId,
    String branch,
    int revision,
    DateTime now,
  ) async {
    final supplier = target.party.kind == DirectoryPartyKind.supplier;
    final header = await _commerceOwned(txn, branch, target, supplier);
    await _requireCommerceRevision(txn, branch, target.id, revision);
    final confirmedReturns = await txn.query(
      _commerceReturns,
      columns: ['id'],
      where: 'branch_id = ? AND invoice_id = ? AND status = ?',
      whereArgs: [branch, target.id, 'confirmed'],
      limit: 1,
    );
    if (confirmedReturns.isNotEmpty) {
      // The connected delete would restore quantities a return already gave
      // back. Refuse instead of corrupting stock; handle the return first.
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    final lines = await _commerceRows(
      txn,
      _commerceLines,
      branch,
      'invoice_id',
      target.id,
    );
    for (final item in lines) {
      if (item['product_id'] == null || item['is_service'] == 1) continue;
      final baseMicro = item['base_micro'] as int;
      if (baseMicro == 0) continue;
      final product = item['product_id'] as String;
      final stockRow = (await _commerceRows(
        txn,
        _commerceStock,
        branch,
        'product_id',
        product,
      )).singleOrNull;
      final deltaMilli = _commerceRatioRound(
        BigInt.from(baseMicro) * BigInt.from(supplier ? -1 : 1),
        BigInt.from(1000),
      );
      if (supplier) {
        // A purchase line may only disappear while all of its lots are whole.
        final lots = await txn.query(
          _commerceLots,
          where: 'branch_id = ? AND purchase_invoice_id = ? AND item_id = ?',
          whereArgs: [branch, target.id, item['id']],
        );
        for (final lot in lots) {
          if (lot['remaining_micro'] != lot['received_micro']) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidInvoice,
            );
          }
        }
        for (final lot in lots) {
          // A sale may already have restored its units to this lot. Retain
          // the historical FK and hide the cancelled receipt in the report.
          await txn.update(
            _commerceLots,
            {'remaining_micro': 0},
            where: 'branch_id = ? AND id = ?',
            whereArgs: [branch, lot['id']],
          );
        }
      } else {
        await _markRestoredSlices(txn, branch, item['id'] as String, baseMicro);
      }
      if (stockRow != null) {
        await txn.update(
          _commerceStock,
          {'quantity_milli': (stockRow['quantity_milli'] as int) + deltaMilli},
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, stockRow['id']],
        );
      }
    }
    await txn.delete(
      _commerceMovements,
      where: 'branch_id = ? AND reference_type = ? AND reference_id = ?',
      whereArgs: [branch, 'invoice', target.id],
    );
    final payments = await _commerceRows(
      txn,
      _commercePayments,
      branch,
      'invoice_id',
      target.id,
    );
    final refunds = <String, int>{};
    for (final payment in payments) {
      final account = payment['account_id'] as String?;
      if (account == null) continue;
      refunds[account] =
          (refunds[account] ?? 0) + (payment['original_minor'] as int);
    }
    for (final entry in refunds.entries) {
      final delta = supplier ? entry.value : -entry.value;
      final account = await _account(txn, branch, entry.key);
      await cashSync._requirePrivate(txn, branch, entry.key);
      final next = BusinessLedger._balance(account, delta);
      if (next < 0 && !await _allowsNegative(txn, branch)) {
        throw const BusinessLedgerError(
          BusinessLedgerProblem.insufficientBalance,
        );
      }
      await _post(
        txn,
        branch,
        commandId,
        entry.key,
        now,
        kind: supplier ? 'deposit' : 'withdrawal',
        delta: delta,
        next: next,
        description: supplier
            ? 'عكس سداد فاتورة شراء ${header['number']}'
            : 'عكس تحصيل فاتورة بيع ${header['number']}',
        reference: header['number'] as String?,
      );
    }
    await txn.update(
      _commerceBalances,
      {'status': 'cancelled'},
      where: 'branch_id = ? AND invoice_id = ?',
      whereArgs: [branch, target.id],
    );
    await txn.update(
      _commerceInvoices,
      {
        'status': 'cancelled',
        'deleted_us': now.toUtc().microsecondsSinceEpoch,
        'balance_minor': 0,
      },
      where: 'branch_id = ? AND id = ?',
      whereArgs: [branch, target.id],
    );
    return {'id': target.id, 'deleted': true};
  }

  Future<Map<String, Object?>> _commerceOwned(
    Transaction txn,
    String branch,
    DirectoryDebtInvoiceReference target,
    bool supplier,
  ) async {
    final header = (await txn.query(
      _commerceInvoices,
      where: 'branch_id = ? AND id = ? AND invoice_type = ?',
      whereArgs: [branch, target.id, supplier ? 'purchase' : 'sale'],
    )).singleOrNull;
    if (header == null ||
        header['party_kind'] != target.party.kind.name ||
        header['party_id'] != target.party.id ||
        header['deleted_us'] != null ||
        const {'draft', 'cancelled'}.contains(header['status'])) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    return header;
  }

  Future<void> _requireCommerceRevision(
    Transaction txn,
    String branch,
    String invoiceId,
    int revision,
  ) async {
    final rows = await txn.rawQuery(
      'SELECT COUNT(*) AS n FROM $_commerceEdits WHERE branch_id = ? AND invoice_id = ?',
      [branch, invoiceId],
    );
    final count = rows.single['n'] as int;
    if (count != revision) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invoiceChanged);
    }
  }

  Future<void> _commerceQuantityDelta(
    Transaction txn,
    String branch,
    String commandId,
    bool supplier,
    String product,
    String itemId,
    int oldBase,
    int newBase,
    int basePrice,
    _CommerceRow header,
    _CommerceRow item,
    DateTime now,
  ) async {
    final growing = newBase > oldBase;
    final delta = (newBase - oldBase) * (supplier ? 1 : -1);
    final stockRow = (await _commerceRows(
      txn,
      _commerceStock,
      branch,
      'product_id',
      product,
    )).singleOrNull;
    final stock = stockRow?['quantity_milli'] as int? ?? 0;
    if (delta < 0 && -delta > stock * 1000) {
      throw const BusinessLedgerError(BusinessLedgerProblem.insufficientStock);
    }
    final deltaMilli = _commerceRatioRound(
      BigInt.from(delta),
      BigInt.from(1000),
    );
    if (stockRow != null) {
      await txn.update(
        _commerceStock,
        {'quantity_milli': stock + deltaMilli},
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, stockRow['id']],
      );
    }
    if (supplier && growing) {
      await _receiveInventoryBatch(
        txn, branch: branch,
        id: const Uuid().v5(commandId, 'fyona.commerce.adjust.lot.v1'),
        product: product, quantity: newBase - oldBase, source: 'purchase', now: now,
        cost4: basePrice * 100, currency: header['currency'] as String,
        invoiceId: header['id'] as String, itemId: itemId,
        supplierId: header['party_id'] as String?, unitId: item['unit_id'] as String?,
      );
    } else if (supplier) {
      await _consumeCommerceLots(
        txn,
        branch,
        commandId,
        product,
        oldBase - newBase,
        now,
        preferredPurchaseItem: itemId,
      );
    } else if (growing) {
      await _consumeCommerceLots(
        txn,
        branch,
        commandId,
        product,
        newBase - oldBase,
        now,
        saleItemId: itemId,
      );
    } else {
      await _markRestoredSlices(txn, branch, itemId, oldBase - newBase);
    }
  }

  /// Recompute the document totals from its current lines. Returns the new
  /// unpaid balance; the paid amount and its frozen payments never move.
  Future<int> _recomputeCommerceDocument(
    Transaction txn,
    String branch,
    String invoiceId,
    Map<String, Object?> header,
  ) async {
    final lines = await _commerceRows(
      txn,
      _commerceLines,
      branch,
      'invoice_id',
      invoiceId,
    );
    final totals = _commerceTotals(
      [
        for (final row in lines)
          _CommerceLineMath(
            line: CommerceIssueLine(
              description: '${row['description']}',
              quantity: '0',
              unitMinor: row['unit_minor'] as int,
            ),
            description: '${row['description']}',
            productId: null,
            unitId: null,
            unitName: null,
            quantityMicro: 0,
            baseMicro: 0,
            factor4: 10000,
            unitMinor: row['unit_minor'] as int,
            discountMinor: row['discount_minor'] as int,
            totalMinor: row['total_minor'] as int,
            tracksStock: false,
            image: null,
            supplier: false,
          ),
      ],
      header['discount_type'] as String?,
      header['discount_value_2'] as int,
      header['tax_type'] as String?,
      header['tax_rate_2'] as int,
    );
    final paid = header['paid_minor'] as int;
    final balance = max(0, totals.total - paid);
    await txn.update(
      _commerceInvoices,
      {
        'subtotal_minor': totals.subtotal,
        'discount_minor': totals.discount,
        'tax_minor': totals.tax,
        'total_minor': totals.total,
        'balance_minor': balance,
        'status': balance == 0
            ? 'paid'
            : (paid > 0 ? 'partially_paid' : 'confirmed'),
      },
      where: 'branch_id = ? AND id = ?',
      whereArgs: [branch, invoiceId],
    );
    final balanceRow = (await txn.query(
      _commerceBalances,
      where: 'branch_id = ? AND invoice_id = ?',
      whereArgs: [branch, invoiceId],
    )).singleOrNull;
    if (balanceRow != null) {
      final collected = balanceRow['paid_minor'] as int;
      await txn.update(
        _commerceBalances,
        {
          'amount_minor': balance + collected,
          'status': balance == 0
              ? 'paid'
              : (collected > 0 ? 'partial' : 'open'),
        },
        where: 'branch_id = ? AND invoice_id = ?',
        whereArgs: [branch, invoiceId],
      );
    }
    return balance;
  }
}

final class _CommercePaid {
  const _CommercePaid(
    this.payment,
    this.currency,
    this.rate,
    this.originalMinor,
    this.appliedMinor,
  );
  final CommerceIssuePayment payment;
  final String currency;
  final BusinessRate? rate;
  final int originalMinor;
  final int appliedMinor;
}

final class _CommerceLineMath {
  const _CommerceLineMath({
    required this.line,
    required this.description,
    required this.productId,
    required this.unitId,
    required this.unitName,
    required this.quantityMicro,
    required this.baseMicro,
    required this.factor4,
    required this.unitMinor,
    required this.discountMinor,
    required this.totalMinor,
    required this.tracksStock,
    required this.image,
    required this.supplier,
  });

  final CommerceIssueLine line;
  final String description;
  final String? productId;
  final String? unitId;
  final String? unitName;
  final int quantityMicro;
  final int baseMicro;
  final int factor4;
  final int unitMinor;
  final int discountMinor;
  final int totalMinor;
  final bool tracksStock;
  final String? image;
  final bool supplier;
}

final class _CommerceReturned {
  const _CommerceReturned(
    this.line,
    this.item,
    this.quantityMicro,
    this.totalMinor,
  );
  final CommerceReturnLine line;
  final Map<String, Object?> item;
  final int quantityMicro;
  final int totalMinor;
}

final class _CommerceTotals {
  const _CommerceTotals(this.subtotal, this.discount, this.tax, this.total);
  final int subtotal;
  final int discount;
  final int tax;
  final int total;
}

_CommerceTotals _commerceTotals(
  List<_CommerceLineMath> lines,
  String? discountType,
  int discountValue2,
  String? taxType,
  int taxRate2,
) {
  var subtotal = 0;
  for (final line in lines) {
    subtotal += line.totalMinor;
  }
  final discount = switch (discountType) {
    'percentage' => _commerceRatioRound(
      BigInt.from(subtotal) * BigInt.from(discountValue2),
      BigInt.from(10000),
    ),
    'fixed' => discountValue2,
    _ => 0,
  };
  if (discount > subtotal) {
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
  }
  final after = subtotal - discount;
  final tax = switch (taxType) {
    'percentage' => _commerceRatioRound(
      BigInt.from(after) * BigInt.from(taxRate2),
      BigInt.from(10000),
    ),
    'fixed' => taxRate2,
    _ => 0,
  };
  return _CommerceTotals(subtotal, discount, tax, after + tax);
}

int _commerceMicro(String raw) {
  final clean = raw.trim();
  final match = RegExp(r'^(\d+)(?:\.(\d{1,6}))?$').firstMatch(clean);
  if (match == null || clean.length > 24) {
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
  }
  final fraction = (match[2] ?? '').padRight(6, '0');
  return int.parse('${match[1]}$fraction');
}

int _commerceFactor4(String raw) {
  final match = RegExp(r'^(\d+)(?:\.(\d{1,4}))?$').firstMatch(raw.trim());
  if (match == null) {
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
  }
  final value = int.parse('${match[1]}${(match[2] ?? '').padRight(4, '0')}');
  if (value <= 0) {
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
  }
  return value;
}

/// Quantity strings keep their exact decimals for the original edit dialog.
String commerceMicroDecimal(int micro) {
  final negative = micro < 0;
  final whole = micro.abs() ~/ 1000000;
  final fraction = (micro.abs() % 1000000)
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
}

/// Half-even rounding of an exact integer ratio, without doubles.
int _commerceRatioRound(BigInt numerator, BigInt denominator) {
  if (denominator <= BigInt.zero) throw ArgumentError.value(denominator);
  final negative = numerator.isNegative;
  final abs = numerator.abs();
  final whole = abs ~/ denominator;
  final twice = (abs % denominator) * BigInt.two;
  final up = twice > denominator || (twice == denominator && whole.isOdd);
  final value = up ? whole + BigInt.one : whole;
  final result = negative ? -value : value;
  if (result.abs() > BigInt.from(BusinessMoney.maxMinor)) {
    throw const FormatException('Business amount is out of range');
  }
  return result.toInt();
}
