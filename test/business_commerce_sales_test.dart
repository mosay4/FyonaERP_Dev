import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

const _customer = DirectoryPartyKind.customer;
const _supplier = DirectoryPartyKind.supplier;
String _id() => const Uuid().v4();

void main() {
  final workspace = DirectoryWorkspace(
    server: 'http://localhost:18083/api/v1',
    accountId: _id(),
    organizationId: _id(),
  );
  final branch = _id();
  final sibling = _id();
  DirectoryAccess scopeFor(String branchId) => DirectoryAccess(
    workspace: workspace,
    branchId: branchId,
    readable: {_customer, _supplier},
    writable: {_customer, _supplier},
  );
  final scope = scopeFor(branch);
  final all = BusinessLedgerAction.values.toSet();
  final access = BusinessLedgerAccess(scope, all);
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryDatabase db;
  BusinessLedger ledger() => db.ledger;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-commerce-');
    keys = FixtureDirectoryKeys();
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: keys,
    );
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> bank(String name, String currency, int opening) async {
    final commandId = _id();
    await ledger().createAccount(
      access,
      commandId: commandId,
      bankName: name,
      accountName: name,
      accountNumber: '100',
      currency: currency,
      openingMinor: opening,
    );
    return commandId;
  }

  Future<DirectoryPartyReference> party(
    DirectoryPartyKind kind,
    String name, {
    String? branchId,
  }) async {
    final scoped = branchId == null ? scope : scopeFor(branchId);
    final row = await db.create(scoped, kind, name: name);
    return DirectoryPartyReference(scope: scoped, kind: kind, id: row.id);
  }

  Future<int> balance(String id) async {
    final rows = await ledger().accounts(access);
    return rows.singleWhere((row) => row['id'] == id)['balance_minor'] as int;
  }

  CommerceIssueLine service(String description, String quantity, int unitMinor) =>
      CommerceIssueLine(
        description: description,
        quantity: quantity,
        unitMinor: unitMinor,
        isService: true,
      );

  test('sale issue keeps exact totals, split payments and the unpaid remainder', () async {
    final till = await bank('Cash A', 'SAR', 1000);
    final office = await bank('Cash B', 'SAR', 0);
    final buyer = await party(_customer, 'Buyer');
    final command = _id();
    final result = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: command,
      currency: 'SAR',
      partyId: buyer.id,
      discountType: 'percentage',
      discountValue2: 1000, // 10.00%
      taxType: 'fixed',
      taxRate2: 125, // 1.25
      notes: 'device sale',
      lines: [service('Repair', '2', 1500)],
      payments: [
        CommerceIssuePayment(accountId: till, originalMinor: 1000, paymentCurrency: 'SAR'),
        CommerceIssuePayment(accountId: office, originalMinor: 825, paymentCurrency: 'SAR'),
      ],
    );
    // line 30.00 − 10% + 1.25 fixed tax = 28.25; paid 18.25; open 10.00
    expect(result['total_minor'], 2825);
    expect(result['paid_minor'], 1825);
    expect(result['balance_minor'], 1000);
    expect('${result['number']}', startsWith('INV-'));
    expect(await balance(till), 2000);
    expect(await balance(office), 825);

    final document = await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.sale,
      result['id'] as String,
    );
    expect(document!['status'], 'partially_paid');
    expect(document['subtotal'], 30);
    expect(document['discount_amount'], 3);
    expect(document['tax_amount'], 1.25);
    expect(document['total'], 28.25);
    expect(document['paid_amount'], 18.25);
    expect(document['balance'], 10);
    expect(document['customer_name'], 'Buyer');
    expect(document['notes'], 'device sale');
    expect((document['payments'] as List).map((row) => row['amount']), unorderedEquals([10, 8.25]));
    expect(document['receivable']['amount'], 10);
    expect(document['receivable']['status'], 'open');

    // Collection reaches the ordinary invoice in one atomic command and
    // closes its remainder against the same account.
    await ledger().settle(
      access,
      buyer,
      commandId: _id(),
      accountId: till,
      amountMinor: 1000,
      currency: 'SAR',
      invoiceId: result['id'] as String,
    );
    expect(await balance(till), 3000);
    final settled = await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.sale,
      result['id'] as String,
    );
    expect(settled!['status'], 'paid');
    expect(settled['balance'], 0);
    expect(settled['paid_amount'], 28.25);
    expect(settled['receivable']['status'], 'paid');
    expect((settled['payments'] as List), hasLength(3));
  });

  test('the same command returns the same document and never double taps', () async {
    final till = await bank('Cash', 'SAR', 0);
    final buyer = await party(_customer, 'Buyer');
    final command = _id();
    Future<Map<String, Object?>> issue() => ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: command,
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '1', 5000)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 2000, paymentCurrency: 'SAR')],
    );
    final first = await issue();
    final replay = await issue();
    expect(replay, first);
    expect(await balance(till), 2000);

    final second = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '1', 5000)],
    );
    expect(second['id'], isNot(first['id']));
    expect(await balance(till), 2000);
  });

  test('documents, payments and balances survive a database reopen', () async {
    final till = await bank('Cash', 'SAR', 700);
    final buyer = await party(_customer, 'Buyer');
    final result = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '1.5', 1025)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 500, paymentCurrency: 'SAR')],
    );
    await db.close();
    db = await DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
    expect(await balance(till), 1200);
    final document = await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.sale,
      result['id'] as String,
    );
    expect(document!['total'], 15.38);
    expect(document['balance'], 10.38);
    expect((document['payments'] as List).single['amount'], 5);
  });

  test('sale return refunds only the overpaid remainder and closes the debt', () async {
    final till = await bank('Cash', 'SAR', 5000);
    final refund = await bank('Refund', 'SAR', 2000);
    final buyer = await party(_customer, 'Buyer');
    final sale = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '2', 1500)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 1000, paymentCurrency: 'SAR')],
    );
    final invoice = sale['id'] as String;
    final line = (await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.sale,
      invoice,
    ))!['items'] as List;
    final itemId = (line.single as Map)['id'] as String;

    final returnCommand = _id();
    Future<Map<String, Object?>> confirm() => ledger().confirmCommerceReturn(
      access,
      commandId: returnCommand,
      kind: BusinessInvoiceKind.sale,
      invoiceId: invoice,
      reason: 'customer changed mind',
      refundAccountId: refund,
      lines: [CommerceReturnLine(itemId: itemId, quantity: '2')],
    );
    final returned = await confirm();
    // Return value 30.00: 20.00 clears the balance, the 10.00 actually
    // paid is refunded — nothing more and nothing less.
    expect(returned['total_minor'], 3000);
    expect(returned['applied_minor'], 2000);
    expect(returned['refunded_minor'], 1000);
    expect(await balance(refund), 1000);
    expect(await balance(till), 6000);
    final document = await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.sale,
      invoice,
    );
    expect(document!['status'], 'paid');
    expect(document['balance'], 0);
    expect(document['paid_amount'], 0);
    expect(document['receivable']['status'], 'paid');
    final returns = await ledger().commerceReturns(
      access,
      BusinessInvoiceKind.sale,
      invoice,
    );
    expect(returns.single['total'], 30);
    expect(returns.single['reason'], 'customer changed mind');

    // A second confirmation of the same command is the same return.
    final replay = await confirm();
    expect(replay, returned);
    expect(await balance(refund), 1000);
    expect((document['payments'] as List), hasLength(1));
  });

  test('cross-currency issue freezes its rate and keeps the account currency', () async {
    final dollars = await bank('Dollars', 'USD', 10000);
    final buyer = await party(_customer, 'Buyer');
    final sale = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '1', 3750)],
      payments: [
        CommerceIssuePayment(
          accountId: dollars,
          originalMinor: 1000, // 10.00 USD = 37.50 SAR at the frozen quote
          paymentCurrency: 'USD',
          rate: BusinessRate('USD', 'SAR', '3.75'),
        ),
      ],
    );
    expect(sale['paid_minor'], 3750);
    expect(sale['balance_minor'], 0);
    expect(await balance(dollars), 11000);
    final document = await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.sale,
      sale['id'] as String,
    );
    final payment = (document!['payments'] as List).single as Map;
    expect(payment['payment_currency'], 'USD');
    expect(payment['original_amount'], 10);
    expect(payment['amount'], 37.5);
    expect(payment['exchange_rate'], '3.75000000');
    // The frozen settlement keeps the account currency change blocked.
    await expectLater(
      ledger().editBankAccount(
        access,
        accountId: dollars,
        commandId: _id(),
        currency: 'SAR',
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.currencyHasPayments,
        ),
      ),
    );
  });

  test('purchase and its return move the account only in its own currency', () async {
    final till = await bank('Cash', 'SAR', 3000);
    final vendor = await party(_supplier, 'Vendor');
    final purchase = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.purchase,
      commandId: _id(),
      currency: 'SAR',
      partyId: vendor.id,
      lines: [service('Service', '1', 5000)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 2000, paymentCurrency: 'SAR')],
    );
    expect(purchase['total_minor'], 5000);
    expect(purchase['balance_minor'], 3000);
    expect(await balance(till), 1000);
    final document = await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.purchase,
      purchase['id'] as String,
    );
    expect(document!['supplier_name'], 'Vendor');
    expect(document['payable']['amount'], 30);

    final line = (document['items'] as List).single as Map;
    final returned = await ledger().confirmCommerceReturn(
      access,
      commandId: _id(),
      kind: BusinessInvoiceKind.purchase,
      invoiceId: purchase['id'] as String,
      refundAccountId: till,
      lines: [CommerceReturnLine(itemId: line['id'] as String, quantity: '1')],
    );
    // 5.00 returned: 3.00 clears the payable, 2.00 comes back to the till.
    expect(returned['applied_minor'], 3000);
    expect(returned['refunded_minor'], 2000);
    expect(await balance(till), 3000);
    final after = await ledger().commerceInvoice(
      access,
      BusinessInvoiceKind.purchase,
      purchase['id'] as String,
    );
    expect(after!['status'], 'paid');
    expect(after['balance'], 0);
  });

  test('a document cannot overspend its account or overpay its total', () async {
    final till = await bank('Cash', 'SAR', 500);
    final buyer = await party(_customer, 'Buyer');
    final vendor = await party(_supplier, 'Vendor');
    await expectLater(
      () => ledger().issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.purchase,
        commandId: _id(),
        currency: 'SAR',
        partyId: vendor.id,
        lines: [service('Service', '1', 5000)],
        payments: [
          CommerceIssuePayment(accountId: till, originalMinor: 700, paymentCurrency: 'SAR'),
        ],
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.insufficientBalance,
        ),
      ),
    );
    expect(await balance(till), 500);
    await expectLater(
      () => ledger().issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.sale,
        commandId: _id(),
        currency: 'SAR',
        partyId: buyer.id,
        lines: [service('Work', '1', 1000)],
        payments: [
          CommerceIssuePayment(accountId: till, originalMinor: 2000, paymentCurrency: 'SAR'),
        ],
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.invalidAmount,
        ),
      ),
    );
    // An unpaid remainder needs a real party, never a cash-customer fiction.
    await expectLater(
      () => ledger().issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.sale,
        commandId: _id(),
        currency: 'SAR',
        lines: [service('Work', '1', 1000)],
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.invalidInvoice,
        ),
      ),
    );
    expect(await balance(till), 500);
  });

  test('ordinary edit moves line, totals, audit and balance in one command', () async {
    final till = await bank('Cash', 'SAR', 1000);
    final buyer = await party(_customer, 'Buyer');
    final sale = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '2', 1500)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 1000, paymentCurrency: 'SAR')],
    );
    final invoice = sale['id'] as String;
    final target = DirectoryDebtInvoiceReference(party: buyer, id: invoice);
    final before = await ledger().openingDebtOperation(access, target);
    final itemId = ((before['items'] as List).single as Map)['id'] as String;
    expect(before['revision'], 0);
    expect(before['total'], '30.00');
    expect(before['remaining'], '20.00');

    final edited = await ledger().editOpeningDebt(
      access,
      target,
      commandId: _id(),
      itemId: itemId,
      revision: 0,
      line: BusinessOpeningDebtLine('1', '20.00'),
    );
    expect(edited['revision'], 1);
    expect(edited['balance_minor'], 1000);
    final after = await ledger().openingDebtOperation(access, target);
    expect(after['revision'], 1);
    expect(after['total'], '20.00');
    expect(after['paid'], '10.00');
    expect(after['remaining'], '10.00');
    expect(after['is_modified'], isTrue);
    final change = (after['item_changes'] as List).single as Map;
    expect(change['old_quantity'], '2');
    expect(change['new_quantity'], '1');
    expect(change['old_unit_price'], '15.00');
    expect(change['new_unit_price'], '20.00');
    expect((after['items'] as List).single['qty'], '1');
    expect((after['items'] as List).single['price'], '20.00');
    final document = await ledger().openingInvoice(access, target);
    expect(document['total'], '20.00');
    expect(document['balance'], '10.00');
    expect(((document['items'] as List).single)['unit_price'], '20.00');
    // A stale revision cannot overwrite the edited document.
    await expectLater(
      () => ledger().editOpeningDebt(
        access,
        target,
        commandId: _id(),
        itemId: itemId,
        revision: 0,
        line: BusinessOpeningDebtLine('5', '1.00'),
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.invoiceChanged,
        ),
      ),
    );
    // The same document is not an opening debt: both lists stay distinguishable.
    final operations = await ledger().debts(access, buyer);
    expect(operations.single['id'], invoice);
    expect(operations.single['remaining_minor'], 1000);
  });

  test('ordinary delete reverses its collection and keeps the cancelled record', () async {
    final till = await bank('Cash', 'SAR', 1000);
    final buyer = await party(_customer, 'Buyer');
    final sale = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '2', 1500)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 1000, paymentCurrency: 'SAR')],
    );
    final invoice = sale['id'] as String;
    final target = DirectoryDebtInvoiceReference(party: buyer, id: invoice);
    final deleteCommand = _id();
    await ledger().deleteOpeningDebt(access, target, commandId: deleteCommand, revision: 0);
    // The 10.00 collected is back; the till is at its opening balance again.
    expect(await balance(till), 1000);
    expect(
      await ledger().commerceInvoice(access, BusinessInvoiceKind.sale, invoice),
      isNull,
    );
    expect(await ledger().debts(access, buyer), isEmpty);
    await expectLater(
      () => ledger().openingDebtOperation(access, target),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.invalidInvoice,
        ),
      ),
    );
    // Replay of the same delete command changes nothing twice.
    await ledger().deleteOpeningDebt(access, target, commandId: deleteCommand, revision: 0);
    expect(await balance(till), 1000);
  });

  test('purchase delete returns its payments and refuses consumed stock', () async {
    final till = await bank('Cash', 'SAR', 3000);
    final vendor = await party(_supplier, 'Vendor');
    final purchase = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.purchase,
      commandId: _id(),
      currency: 'SAR',
      partyId: vendor.id,
      lines: [service('Service', '1', 5000)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 2000, paymentCurrency: 'SAR')],
    );
    final target = DirectoryDebtInvoiceReference(
      party: vendor,
      id: purchase['id'] as String,
    );
    await ledger().deleteOpeningDebt(access, target, commandId: _id(), revision: 0);
    // The 20.00 paid returns to the till.
    expect(await balance(till), 3000);
    expect(await ledger().debts(access, vendor), isEmpty);
  });

  test('branch isolation: sibling scope cannot see or issue in another branch', () async {
    final till = await bank('Cash', 'SAR', 900);
    final buyer = await party(_customer, 'Buyer');
    final sale = await ledger().issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      lines: [service('Work', '1', 900)],
      payments: [CommerceIssuePayment(accountId: till, originalMinor: 900, paymentCurrency: 'SAR')],
    );
    final stranger = BusinessLedgerAccess(scopeFor(sibling), all);
    await expectLater(
      () => ledger().debts(stranger, buyer),
      throwsA(isA<DirectoryAccessDenied>()),
    );
    await expectLater(
      () => ledger().issueCommerceDocument(
        stranger,
        kind: BusinessInvoiceKind.sale,
        commandId: _id(),
        currency: 'SAR',
        partyId: buyer.id,
        lines: [service('Work', '1', 900)],
      ),
      throwsA(isA<DirectoryPartyNotFound>()),
    );
    expect(
      await ledger().commerceInvoice(
        stranger,
        BusinessInvoiceKind.sale,
        sale['id'] as String,
      ),
      isNull,
    );
    // The ordinary document is not an opening debt; both remain separate.
    expect(
      await ledger().commerceInvoice(access, BusinessInvoiceKind.sale, sale['id'] as String),
      isNotNull,
    );
  });
}
