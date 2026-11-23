import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_debt_projection.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/business_cash_test_checkpoint.dart';
import 'support/business_commerce_test_schema.dart';
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
  final otherBranch = _id();
  DirectoryAccess directory({String? branchId, DirectoryWorkspace? owner}) =>
      DirectoryAccess(
        workspace: owner ?? workspace,
        branchId: branchId ?? branch,
        readable: {_customer, _supplier},
        writable: {_customer, _supplier},
      );
  final scope = directory();
  final all = BusinessLedgerAction.values.toSet();
  final access = BusinessLedgerAccess(scope, all);
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryDatabase db;
  BusinessLedger ledger() => db.ledger;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-ledger-');
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

  Future<String> bank({
    String currency = 'SAR',
    int opening = 0,
    BusinessLedgerAccess? scoped,
    String? id,
  }) async {
    final commandId = id ?? _id();
    await ledger().createAccount(
      scoped ?? access,
      commandId: commandId,
      bankName: 'Bank fixture',
      accountName: 'Test $currency',
      accountNumber: '100',
      currency: currency,
      openingMinor: opening,
    );
    return commandId;
  }

  Future<DirectoryPartyReference> party(
    DirectoryPartyKind kind,
    String name, {
    DirectoryAccess? scoped,
  }) async {
    final branch = scoped ?? scope;
    final row = await db.create(branch, kind, name: name);
    return DirectoryPartyReference(scope: branch, kind: kind, id: row.id);
  }

  Future<String> opening(
    DirectoryPartyReference party,
    int amount, {
    String currency = 'SAR',
    String? group,
  }) async {
    final id = _id();
    await ledger().recordOpeningDebt(
      access,
      party,
      commandId: id,
      amountMinor: amount,
      currency: currency,
      groupId: group,
    );
    return id;
  }

  Future<int> balance(String id) async {
    final rows = await ledger().accounts(access);
    return rows.singleWhere((row) => row['id'] == id)['balance_minor'] as int;
  }

  Matcher problem(BusinessLedgerProblem value) =>
      isA<BusinessLedgerError>().having((e) => e.problem, 'problem', value);

  Future<void> removeOpeningProjection(Transaction txn) async {
    // These tests synthesize old fixtures from a fresh schema. The v15
    // empty preparation table did not exist in those fixtures.
    await txn.execute('DROP TABLE business_cash_link_preparations');
    await removeCommerceFixtureSchema(txn);
    await txn.execute('DROP VIEW business_debt_payment_history');
    await txn.execute('DROP TABLE business_opening_projection_receipts');
    await txn.execute('DROP TABLE business_imported_opening_payments');
    for (final col in ['opening_item_id', 'legacy_receivable_id']) {
      await txn.execute('ALTER TABLE business_local_debts DROP COLUMN $col');
    }
    for (final col in ['group_kind', 'period']) {
      await txn.execute('ALTER TABLE business_debt_groups DROP COLUMN $col');
    }
  }

  test(
    'v5 native payments remain linked to their original legs after v7',
    () async {
      final customer = await party(_customer, 'V5 customer');
      final till = await bank(opening: 10000);
      final invoice = await opening(customer, 3025);
      final cmd = _id();
      await ledger().settle(
        access,
        customer,
        commandId: cmd,
        accountId: till,
        amountMinor: 500,
        currency: 'SAR',
        invoiceId: invoice,
      );
      await db.close();
      final old = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        await old.transaction((txn) async {
          await removeOpeningProjection(txn);
          await txn.execute('PRAGMA user_version = 5');
        });
      } finally {
        await old.close();
      }
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      final target = DirectoryDebtInvoiceReference(
        party: customer,
        id: invoice,
      );
      final operation = await ledger().openingDebtOperation(access, target);
      expect((operation['items'] as List).single['id'], invoice);
      final payment = (await ledger().paymentParts(
        access,
        customer,
        invoice,
      )).single;
      expect(payment['id'], cmd);
      expect(payment['command_id'], cmd);
      expect(payment['account_id'], till);
      expect(await balance(till), 10500);
      await ledger().deleteOpeningDebt(
        access,
        target,
        commandId: _id(),
        revision: 1,
      );
      expect(await balance(till), 10000);
    },
  );

  test('money and frozen FX match the connected debt decimal precision', () {
    expect(BusinessMoney.minor('1000.01'), 100001);
    expect(BusinessMoney.minor('1.'), 100);
    expect(BusinessMoney.minor('.1'), 10);
    expect(BusinessMoney.minor('0.005', halfEven: true), 0);
    expect(BusinessMoney.minor('0.015', halfEven: true), 2);
    expect(BusinessMoney.display(-1), '-0.01');
    expect(() => BusinessMoney.minor('10000000000'), throwsFormatException);
    expect(() => BusinessMoney.minor('NaN'), throwsFormatException);
    expect(() => BusinessRate('SAR', 'SAR', '2'), throwsFormatException);
    final quote = BusinessRate(' usd ', 'yer_old', '534.00100000');
    expect(quote.decimal, '534.00100000');
    expect(quote.convert(300), 160200);
    final exactHalf = BusinessRate('USD', 'SAR', '3.75');
    expect(exactHalf.convert(2), 8);
    expect(exactHalf.convert(6), 22);
    expect(exactHalf.convert(6, halfEven: false), 23);
  });

  test(
    'bank metadata edits leave the exact currencies and legs of past money',
    () async {
      final till = await bank(opening: 10025);
      final cmd = _id();
      Future<void> change({int? balance, int? expected, String? currency}) =>
          ledger().editBankAccount(
            access,
            accountId: till,
            commandId: cmd,
            bankName: 'Renamed till',
            balanceMinor: balance,
            expectedBalanceMinor: expected,
            currency: currency,
          );
      await ledger().move(
        access,
        commandId: _id(),
        accountId: till,
        amountMinor: 1,
        withdraw: false,
      );
      await expectLater(
        change(balance: 20000, expected: 10025),
        throwsA(problem(BusinessLedgerProblem.accountChanged)),
      );
      expect(await balance(till), 10026);
      await change(currency: 'USD');
      await change(currency: 'USD');
      await ledger().move(
        access,
        commandId: _id(),
        accountId: till,
        amountMinor: 100,
        withdraw: false,
      );
      final history = await ledger().bankHistory(access, [
        till,
      ], includeBalances: false);
      expect(history.map((item) => item['currency']), ['USD', 'SAR', 'SAR']);
      expect(history.map((item) => item['amount']), ['1.00', '0.01', '100.25']);
      expect(
        history.every((item) => !item.containsKey('running_balance')),
        isTrue,
      );
      expect(
        (await ledger().manualMovements(
          access,
          showIncome: true,
          showExpenses: false,
        )).map((item) => item['currency']),
        ['USD', 'SAR'],
      );
      await expectLater(
        Future.sync(
          () => ledger().bankHistory(
            BusinessLedgerAccess(scope, {BusinessLedgerAction.readBank}),
            [till],
            includeBalances: true,
          ),
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
    },
  );

  test(
    'cash currency preferences and their balances retire and restore atomically',
    () async {
      await ledger().initializeBankCash(
        access,
        commandId: _id(),
        currencies: ['USD', 'SAR'],
      );
      final usd =
          (await ledger().accounts(
                access,
              )).singleWhere((r) => r['currency'] == 'USD')['id']
              as String;
      await ledger().move(
        access,
        commandId: _id(),
        accountId: usd,
        amountMinor: 1777,
        withdraw: false,
      );
      final command = _id();
      Future<void> customize(
        Set<String> before,
        Set<String> after,
        String cmd,
      ) => ledger().customizeCashCurrencies(
        access,
        commandId: cmd,
        expected: before,
        currencies: after,
      );
      await Future.wait([
        customize({'SAR', 'USD'}, {'SAR'}, command),
        customize({'SAR', 'USD'}, {'SAR'}, command),
      ]);
      expect(await ledger().cashCurrencies(access), {'SAR'});
      await expectLater(
        customize({'SAR', 'USD'}, {'SAR', 'EUR'}, _id()),
        throwsA(problem(BusinessLedgerProblem.accountChanged)),
      );
      final sar = (await ledger().accounts(access)).single['id'] as String;
      await expectLater(
        ledger().closeBankAccounts(
          access,
          commandId: _id(),
          accountIds: [sar],
          onlyCash: true,
        ),
        throwsA(problem(BusinessLedgerProblem.cannotDeleteLastCash)),
      );
      await ledger().initializeBankCash(
        access,
        commandId: _id(),
        currencies: ['USD', 'SAR'],
      );
      expect(await ledger().cashCurrencies(access), {
        'SAR',
      }); // A default cannot resurrect it.
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      await customize({'SAR'}, {'SAR', 'USD'}, _id());
      expect(await balance(usd), 1777);
      expect(await ledger().statement(access, usd), hasLength(1));
      expect(await ledger().cashCurrencies(access), {'SAR', 'USD'});
    },
  );

  test(
    'bank group closure cannot partially retire an account or cross a branch',
    () async {
      final first = await bank(
        id: '001c1040-cbd6-4d57-83b8-2c4bb0fa78c5',
        opening: 10000,
      );
      final second = await bank(currency: 'USD');
      final sibling = BusinessLedgerAccess(
        directory(branchId: otherBranch),
        all,
      );
      final other = await bank(
        id: 'ffff1040-cbd6-4d57-83b8-2c4bb0fa78c5',
        scoped: sibling,
      );
      final command = _id();
      await expectLater(
        ledger().closeBankAccounts(
          access,
          commandId: command,
          accountIds: [first, other],
        ),
        throwsA(problem(BusinessLedgerProblem.invalidAccount)),
      );
      expect(await balance(first), 10000);
      await ledger().closeBankAccounts(
        access,
        commandId: command,
        accountIds: [first, second],
      );
      await ledger().closeBankAccounts(
        access,
        commandId: command,
        accountIds: [second, first],
      );
      expect(await ledger().accounts(access), isEmpty);
      expect((await ledger().accounts(sibling)).single['id'], other);
      await expectLater(
        ledger().move(
          access,
          commandId: _id(),
          accountId: first,
          amountMinor: 1,
          withdraw: false,
        ),
        throwsA(problem(BusinessLedgerProblem.invalidAccount)),
      );
    },
  );

  test(
    'managed bank slots deduplicate concurrent submits without merging balances',
    () async {
      Future<Map<String, Object?>> add(
        String id,
        String bankName, {
        String type = 'checking',
      }) => ledger().createAccount(
        access,
        commandId: id,
        bankName: bankName,
        accountName: bankName,
        accountNumber: '',
        currency: 'SAR',
        accountType: type,
        openingMinor: 1050,
        managed: true,
      );
      final command = _id();
      final replies = await Future.wait([
        add(command, 'Main Bank'),
        add(command, 'Main Bank'),
      ]);
      expect(replies.first, replies.last);
      await expectLater(
        add(_id(), 'main  bank'),
        throwsA(problem(BusinessLedgerProblem.duplicateBankAccount)),
      );
      await add(_id(), 'Main Bank', type: 'savings');
      expect(await ledger().accounts(access), hasLength(2));
      expect(await balance(command), 1050);
    },
  );

  test(
    'v4 statements keep IDs, exact balances and currencies through v7',
    () async {
      final till = await bank(currency: 'USD', opening: 4910);
      final commandId = _id();
      await ledger().move(
        access,
        commandId: commandId,
        accountId: till,
        amountMinor: 39,
        withdraw: true,
      );
      await db.close();
      final old = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        await old.transaction((txn) async {
          await removeOpeningProjection(txn);
          await txn.execute('DROP TABLE business_bank_projection_receipts');
          await txn.execute('DROP TABLE business_bank_account_edits');
          await txn.execute(
            'ALTER TABLE business_cutover_archives DROP COLUMN bank_policy',
          );
          for (final column in ['closed_us', 'is_active', 'cash_stashed']) {
            await txn.execute(
              'ALTER TABLE business_local_accounts DROP COLUMN $column',
            );
          }
          for (final column in ['currency', 'reference', 'legacy', 'hidden']) {
            await txn.execute(
              'ALTER TABLE business_local_bank_legs DROP COLUMN $column',
            );
          }
          await txn.execute('PRAGMA user_version = 4');
        });
      } finally {
        await old.close();
      }
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      final rows = await ledger().bankHistory(access, [
        till,
      ], includeBalances: true);
      expect(rows.map((row) => row['id']), ['$commandId:$till', '$till:$till']);
      expect(rows.map((row) => row['currency']), ['USD', 'USD']);
      expect(rows.map((row) => row['running_balance']), ['48.71', '49.10']);
      expect(await balance(till), 4871);
    },
  );

  test(
    'opening invoice keeps edited line, paid amount, and exact audit',
    () async {
      final customer = await party(_customer, 'Edited opening');
      final till = await bank();
      final id = await opening(customer, 3025);
      final target = DirectoryDebtInvoiceReference(party: customer, id: id);
      await ledger().settle(
        access,
        customer,
        commandId: _id(),
        accountId: till,
        amountMinor: 3500,
        currency: 'SAR',
        invoiceId: id,
      );
      final start = await ledger().openingDebtOperation(access, target);
      expect(start['revision'], 1);
      final command = _id();
      Future<Map<String, Object?>> edit(int revision) =>
          ledger().editOpeningDebt(
            access,
            target,
            commandId: command,
            revision: revision,
            itemId: id,
            line: BusinessOpeningDebtLine('1.500', '10.25'),
          );
      await expectLater(
        edit(0),
        throwsA(problem(BusinessLedgerProblem.invoiceChanged)),
      );
      final edits = await Future.wait([edit(1), edit(1)]);
      expect(edits[0], edits[1]);
      final detail = await ledger().openingDebtOperation(access, target);
      expect(detail['total'], '15.38');
      expect(detail['paid'], '30.25');
      expect(detail['remaining'], '0.00');
      final changes = detail['item_changes'] as List;
      expect(changes.single['old_quantity'], '1');
      expect(changes.single['new_quantity'], '1.5');
      expect(changes.single['old_unit_price'], '30.25');
      expect(changes.single['new_unit_price'], '10.25');
      expect(await balance(till), 3500);

      final readOnly = BusinessLedgerAccess(scope, {
        BusinessLedgerAction.readDebt,
      });
      await expectLater(
        Future.sync(
          () => ledger().editOpeningDebt(
            readOnly,
            target,
            commandId: _id(),
            revision: 2,
            itemId: id,
            line: BusinessOpeningDebtLine('1', '99.12'),
          ),
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        Future.sync(
          () => ledger().openingDebtOperation(
            BusinessLedgerAccess(directory(branchId: otherBranch), all),
            target,
          ),
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );

      final delete = _id();
      Future<Map<String, Object?>> remove(int revision) =>
          ledger().deleteOpeningDebt(
            access,
            target,
            commandId: delete,
            revision: revision,
          );
      await expectLater(
        remove(1),
        throwsA(problem(BusinessLedgerProblem.invoiceChanged)),
      );
      final results = await Future.wait([remove(2), remove(2)]);
      expect(results[0], results[1]);
      expect(
        await balance(till),
        475,
      ); // Advance, not a payment on the deleted invoice.
      expect(await ledger().debts(access, customer), isEmpty);
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      expect(await remove(2), results.first);
      await expectLater(
        ledger().openingInvoice(access, target),
        throwsA(problem(BusinessLedgerProblem.invalidInvoice)),
      );
      final legs = await ledger().statement(access, till);
      expect(
        legs
            .where((row) => row['kind'] == 'invoice_cancel')
            .single['delta_minor'],
        -3025,
      );
    },
  );

  test(
    'opening delete rolls back the first account when a later reversal fails',
    () async {
      final seller = await party(_supplier, 'Rollback supplier');
      final invoice = await opening(seller, 6025);
      final target = DirectoryDebtInvoiceReference(party: seller, id: invoice);
      final tills = [_id(), _id()]..sort();
      for (final id in tills) {
        await bank(opening: 10000, id: id);
        await ledger().settle(
          access,
          seller,
          commandId: _id(),
          accountId: id,
          amountMinor: 2000,
          currency: 'SAR',
          invoiceId: invoice,
        );
      }
      final before = await ledger().openingDebtOperation(access, target);
      final revision = before['revision'] as int;
      final raw = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) async => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      addTearDown(raw.close);
      await raw.execute('''
      CREATE TRIGGER fail_opening_cancel BEFORE INSERT ON business_local_bank_legs
      WHEN NEW.kind = 'invoice_cancel' AND NEW.account_id = '${tills.last}'
      BEGIN SELECT RAISE(ABORT, 'injected reversal failure'); END
    ''');
      final command = _id();
      Future<Map<String, Object?>> remove() => ledger().deleteOpeningDebt(
        access,
        target,
        commandId: command,
        revision: revision,
      );
      await expectLater(remove(), throwsA(isA<DatabaseException>()));
      for (final id in tills) {
        expect(await balance(id), 8000);
      }
      expect(await ledger().openingDebtOperation(access, target), before);
      await raw.execute('DROP TRIGGER fail_opening_cancel');
      await remove();
      for (final id in tills) {
        expect(await balance(id), 10000);
      }
    },
  );

  test(
    'schema three payments and IDs survive the opening-document upgrade',
    () async {
      final customer = await party(_customer, 'Existing encrypted ledger');
      final id = await opening(customer, 3025);
      final till = await bank();
      final payment = _id();
      await ledger().settle(
        access,
        customer,
        commandId: payment,
        accountId: till,
        amountMinor: 1000,
        currency: 'SAR',
        invoiceId: id,
      );
      await db.close();
      final v3 = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) async => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        await v3.transaction((txn) async {
          await removeOpeningProjection(txn);
          for (final table in [
            'business_bank_projection_receipts',
            'business_bank_account_edits',
            'business_cash_conflict_reads',
            'business_opening_debt_edits',
            'business_cutover_rows',
            'business_cutover_archives',
          ]) {
            await txn.execute('DROP TABLE $table');
          }
          for (final column in [
            'opening_quantity',
            'opening_unit_minor',
            'revision',
            'cancelled_us',
          ]) {
            await txn.execute(
              'ALTER TABLE business_local_debts DROP COLUMN $column',
            );
          }
          for (final column in ['closed_us', 'is_active', 'cash_stashed']) {
            await txn.execute(
              'ALTER TABLE business_local_accounts DROP COLUMN $column',
            );
          }
          for (final column in ['currency', 'reference', 'legacy', 'hidden']) {
            await txn.execute(
              'ALTER TABLE business_local_bank_legs DROP COLUMN $column',
            );
          }
          await txn.execute('PRAGMA user_version = 3');
        });
      } finally {
        await v3.close();
      }
      db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      final invoice = DirectoryDebtInvoiceReference(party: customer, id: id);
      final info = await ledger().openingDebtOperation(access, invoice);
      expect(info['remaining'], '20.25');
      expect((info['payments'] as List).single['id'], payment);
      expect(await balance(till), 1000);
      expect(
        (await ledger().bankHistory(access, [
          till,
        ], includeBalances: true)).single['currency'],
        'SAR',
      );
      await ledger().deleteOpeningDebt(
        access,
        invoice,
        commandId: _id(),
        revision: info['revision'] as int,
      );
      expect(await balance(till), 0);
    },
  );

  test(
    'opening party + debt are persisted once with one stable replay receipt',
    () async {
      final command = _id();
      Future<Map<String, Object?>> save(int amount) =>
          ledger().addPartyWithOpeningDebt(
            access,
            _customer,
            commandId: command,
            name: 'Starting customer',
            phone: '123456',
            amountMinor: amount,
            currency: 'SAR',
          );
      final replies = await Future.wait([save(1000), save(1000)]);
      expect(replies[0], replies[1]);
      expect(replies[0], {'party_id': command, 'invoice_id': command});
      final reference = DirectoryPartyReference(
        scope: scope,
        kind: _customer,
        id: command,
      );
      expect(
        (await ledger().debts(access, reference)).single['total_minor'],
        1000,
      );
      await expectLater(
        save(1200),
        throwsA(problem(BusinessLedgerProblem.commandConflict)),
      );
      await expectLater(
        ledger().addPartyWithOpeningDebt(
          access,
          _customer,
          commandId: _id(),
          name: 'Another name',
          phone: '123456',
          amountMinor: 500,
          currency: 'SAR',
        ),
        throwsA(isA<DirectoryValidation>()),
      );
      expect(await db.search(scope, _customer, ''), hasLength(1));
      await db.close();
      final file = File(DirectoryDatabase.filePath(root, workspace));
      final raw = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      expect(raw, isNot(contains('Starting customer')));
      expect(raw, isNot(contains('business_local_debts')));
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      expect(await save(1000), replies.first);
      expect((await ledger().debts(access, reference)).single['paid_minor'], 0);
    },
  );

  test(
    'collection applies oldest matching invoices, advances surplus and never pays twice',
    () async {
      final client = await party(_customer, 'Normal customer');
      final older = await opening(client, 3000);
      final newer = await opening(client, 2000);
      final foreign = await opening(client, 10000, currency: 'USD');
      final till = await bank();
      final command = _id();
      Future<Map<String, Object?>> collect() => ledger().settle(
        access,
        client,
        commandId: command,
        accountId: till,
        amountMinor: 4000,
        currency: 'SAR',
      );
      final receipts = await Future.wait([collect(), collect(), collect()]);
      expect(receipts[0], receipts[1]);
      expect(receipts[0]['invoices'], [older, newer]);
      expect(receipts[0]['applied_minor'], 4000);
      expect(await balance(till), 4000);
      expect(
        (await ledger().statement(access, till)).single['delta_minor'],
        4000,
      );
      final parts = await ledger().paymentParts(access, client, older);
      expect(parts.single['applied_minor'], 3000);
      expect(
        (await ledger().paymentParts(
          access,
          client,
          newer,
        )).single['applied_minor'],
        1000,
      );
      expect(await ledger().paymentParts(access, client, foreign), isEmpty);
      final extra = await ledger().settle(
        access,
        client,
        commandId: _id(),
        accountId: till,
        invoiceId: newer,
        amountMinor: 1050,
        currency: 'SAR',
      );
      expect(extra['applied_minor'], 1000);
      expect(extra['surplus_minor'], 50);
      expect(await balance(till), 5050);
      await expectLater(
        ledger().settle(
          access,
          client,
          commandId: _id(),
          accountId: till,
          amountMinor: 5,
          currency: 'SAR',
          invoiceId: newer,
        ),
        throwsA(problem(BusinessLedgerProblem.noDebtInCurrency)),
      );
      expect(await balance(till), 5050);
    },
  );

  test(
    'cross-currency group payment freezes FX and only affects its group',
    () async {
      final vendor = await party(_supplier, 'Invoice vendor');
      final outsider = await party(_supplier, 'Other vendor');
      await db.createGroup(scope, _supplier, vendor.id, 'Named group');
      final group =
          (await db.groups(scope, _supplier, vendor.id)).single['id'] as String;
      final id = await opening(vendor, 3000, group: group);
      final outside = await opening(vendor, 1500);
      final usd = await bank(currency: 'USD', opening: 1000);
      await expectLater(
        ledger().settle(
          access,
          vendor,
          commandId: _id(),
          accountId: usd,
          amountMinor: 900,
          currency: 'USD',
          groupId: group,
        ),
        throwsA(problem(BusinessLedgerProblem.missingRate)),
      );
      final rate = BusinessRate('USD', 'SAR', '3.75');
      final result = await ledger().settle(
        access,
        vendor,
        commandId: _id(),
        accountId: usd,
        amountMinor: 900,
        currency: 'USD',
        groupId: group,
        rate: rate,
      );
      expect(result['applied_minor'], 3000);
      expect(result['surplus_minor'], 100);
      expect(await balance(usd), 100);
      final part = (await ledger().paymentParts(access, vendor, id)).single;
      expect(part['original_minor'], 800);
      expect(part['exchange_rate'], '3.75000000');
      expect(await ledger().paymentParts(access, vendor, outside), isEmpty);
      await expectLater(
        ledger().paymentParts(access, outsider, id),
        throwsA(problem(BusinessLedgerProblem.invalidInvoice)),
      );
      await expectLater(
        ledger().settle(
          access,
          vendor,
          commandId: _id(),
          accountId: usd,
          amountMinor: 10,
          currency: 'USD',
          invoiceId: outside,
          rate: rate,
        ),
        throwsA(problem(BusinessLedgerProblem.currencyMismatch)),
      );
    },
  );

  test(
    'two real connections cannot both spend a constrained bank balance',
    () async {
      final till = await bank(opening: 10000);
      final otherConnection = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      addTearDown(otherConnection.close);
      Future<Object> spend(BusinessLedger writer) async {
        try {
          return await writer.move(
            access,
            commandId: _id(),
            accountId: till,
            amountMinor: 10000,
            withdraw: true,
            expenseCategory: 'إيجار',
          );
        } on BusinessLedgerError catch (e) {
          return e;
        }
      }

      final results = await Future.wait([
        spend(ledger()),
        spend(otherConnection.ledger),
      ]);
      expect(results.whereType<Map>(), hasLength(1));
      expect(
        results.whereType<BusinessLedgerError>().single,
        problem(BusinessLedgerProblem.insufficientBalance),
      );
      final statement = await ledger().statement(access, till);
      expect(statement.map((e) => e['kind']), [
        'withdrawal',
        'opening_balance',
      ]);
      expect(statement.first['expense_category'], 'إيجار');
      expect(await balance(till), 0);
      await ledger().setAllowNegative(access, true);
      await ledger().move(
        access,
        commandId: _id(),
        accountId: till,
        amountMinor: 1,
        withdraw: true,
      );
      expect(await balance(till), -1);
    },
  );

  test(
    'failed second leg and failed payment posting roll back every row',
    () async {
      final from = await bank(opening: 10000);
      final to = await bank(currency: 'USD');
      final vendor = await party(_supplier, 'Rollback vendor');
      final invoice = await opening(vendor, 1500);
      final key = keys.memory[workspace.storageId]!;
      // Fail *during* the real writer, after it performed earlier SQL changes.
      final raw = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute('PRAGMA key = "x\'$key\'"'),
        ),
      );
      addTearDown(raw.close);
      await raw.execute('''
      CREATE TRIGGER fail_local_leg BEFORE INSERT ON business_local_bank_legs
      WHEN NEW.kind IN ('transfer_in', 'supplier_payment')
      BEGIN SELECT RAISE(ABORT, 'injected disk write failure'); END
    ''');
      final transfer = _id();
      final payment = _id();
      Future<Map<String, Object?>> remit() => ledger().transfer(
        access,
        commandId: transfer,
        fromId: from,
        toId: to,
        amountMinor: 1500,
        rate: BusinessRate('SAR', 'USD', '0.26666667'),
      );
      Future<Map<String, Object?>> settle() => ledger().settle(
        access,
        vendor,
        commandId: payment,
        accountId: from,
        amountMinor: 1000,
        currency: 'SAR',
        invoiceId: invoice,
      );
      await expectLater(remit(), throwsA(isA<DatabaseException>()));
      await expectLater(settle(), throwsA(isA<DatabaseException>()));
      expect(await balance(from), 10000);
      expect(await balance(to), 0);
      expect(await ledger().statement(access, to), isEmpty);
      expect(await ledger().paymentParts(access, vendor, invoice), isEmpty);
      expect((await ledger().debts(access, vendor)).single['paid_minor'], 0);
      await raw.execute('DROP TRIGGER fail_local_leg');
      expect((await remit())['received_minor'], 400);
      expect((await settle())['applied_minor'], 1000);
      expect(await balance(from), 7500);
      expect(await balance(to), 400);
    },
  );

  test(
    'a branch, workspace or employee view cannot read or spend other data',
    () async {
      final till = await bank(opening: 5000);
      final client = await party(_customer, 'Branch A customer');
      final spare = BusinessLedgerAccess(directory(branchId: otherBranch), all);
      final otherAccount = await bank(scoped: spare, opening: 2000);
      final otherWorkspace = DirectoryWorkspace(
        server: workspace.server,
        accountId: _id(),
        organizationId: workspace.organizationId,
      );
      final outsider = BusinessLedgerAccess(
        directory(owner: otherWorkspace),
        all,
      );
      final viewer = BusinessLedgerAccess(scope, {
        BusinessLedgerAction.readDebt,
      });
      expect(await ledger().debts(viewer, client), isEmpty);
      expect(
        () => ledger().accounts(viewer),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        () => ledger().accounts(outsider),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        () => ledger().debts(spare, client),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        () => ledger().move(
          viewer,
          commandId: _id(),
          accountId: till,
          amountMinor: 100,
          withdraw: true,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        ledger().statement(spare, till),
        throwsA(problem(BusinessLedgerProblem.invalidAccount)),
      );
      await expectLater(
        ledger().transfer(
          access,
          commandId: _id(),
          fromId: till,
          toId: otherAccount,
          amountMinor: 100,
        ),
        throwsA(problem(BusinessLedgerProblem.invalidAccount)),
      );
      expect(await balance(till), 5000);
    },
  );

  test(
    'group assignment and deletion move the debt without changing money',
    () async {
      final customer = await party(_customer, 'Grouped customer');
      final other = await party(_customer, 'Other customer');
      final invoiceId = await opening(customer, 1000);
      final invoice = DirectoryDebtInvoiceReference(
        party: customer,
        id: invoiceId,
      );
      await db.createGroup(scope, _customer, customer.id, 'Valid group');
      await db.createGroup(scope, _customer, other.id, 'Other party group');
      final group =
          (await db.groups(scope, _customer, customer.id)).single['id']
              as String;
      final wrong =
          (await db.groups(scope, _customer, other.id)).single['id'] as String;
      await expectLater(
        ledger().assignDebtGroup(
          access,
          invoice,
          commandId: _id(),
          groupId: wrong,
        ),
        throwsA(isA<DirectoryPartyNotFound>()),
      );
      final commandId = _id();
      await ledger().assignDebtGroup(
        access,
        invoice,
        commandId: commandId,
        groupId: group,
      );
      await ledger().assignDebtGroup(
        access,
        invoice,
        commandId: commandId,
        groupId: group,
      );
      expect(await ledger().debts(access, customer, individual: true), isEmpty);
      expect(
        (await db.groups(scope, _customer, customer.id)).single['count'],
        1,
      );
      expect(
        await ledger().debts(access, customer, dateTo: '2000-01-01'),
        isEmpty,
      );
      final till = await bank();
      await ledger().settle(
        access,
        customer,
        commandId: _id(),
        accountId: till,
        amountMinor: 250,
        currency: 'SAR',
        groupId: group,
      );
      await ledger().removeDebtGroup(
        access,
        DirectoryDebtGroupReference(party: customer, id: group),
        commandId: _id(),
      );
      final operation = (await ledger().debts(
        access,
        customer,
        individual: true,
      )).single;
      expect(operation['id'], invoiceId);
      expect(operation['total_minor'], 1000);
      expect(operation['paid_minor'], 250);
      expect(await balance(till), 250);
      expect(await db.groups(scope, _customer, customer.id), isEmpty);
      expect(
        (await ledger().openingInvoice(access, invoice))['balance'],
        '7.50',
      );

      final deleted = _id();
      await ledger().deleteUnlinkedParty(access, customer, commandId: deleted);
      await ledger().deleteUnlinkedParty(access, customer, commandId: deleted);
      expect(await db.search(scope, _customer, 'Grouped'), isEmpty);
      await expectLater(
        ledger().openingInvoice(access, invoice),
        throwsA(isA<DirectoryPartyNotFound>()),
      );
      await expectLater(
        ledger().paymentParts(access, customer, invoiceId),
        throwsA(isA<DirectoryPartyNotFound>()),
      );
      expect(await balance(till), 250);
      final replacement = await party(_customer, 'Grouped customer');
      expect(replacement.id, isNot(customer.id));
      expect(await ledger().debts(access, replacement), isEmpty);
    },
  );

  test(
    'display totals expose missing rates without repricing paid amounts',
    () async {
      final customer = await party(_customer, 'Multiple currencies');
      final document = await opening(customer, 2500);
      await opening(customer, 300, currency: 'USD');
      final projection = BusinessDebtProjection(
        await ledger().debts(access, customer),
      );
      final missing = projection.report('SAR', (_, _) => null);
      expect(missing['fx_missing'], ['USD']);
      expect(missing['remaining_total'], isNull);
      final report = projection.report(
        'SAR',
        (from, to) => BusinessRate(from, to, '3.75'),
      );
      expect(report['remaining_total'], '36.25');
      expect(report['fx_missing'], isEmpty);
      expect(
        (await ledger().openingInvoice(
          access,
          DirectoryDebtInvoiceReference(party: customer, id: document),
        ))['total'],
        '25.00',
      );
    },
  );

  test('v8 upgrade preserves pending cash and refuses silent re-enrollment', () async {
    final account = await bank(opening: 1000);
    final session = _id();
    final scoped = BusinessLedgerAccess(scope, all, cashSessionId: session);
    final opening = cashTestCheckpoint(scope, account, balance: 1000);
    await ledger().cashSync.provision(scoped, account, grantVersion: 1, allowNegative: false);
    await ledger().cashSync.bindReplica(scoped, sessionId: session, checkpoint: opening);
    final command = _id();
    await ledger().move(scoped, commandId: command, accountId: account, amountMinor: 250, withdraw: true);
    await db.close();
    final old = await databaseFactoryFfi.openDatabase(
      DirectoryDatabase.filePath(root, workspace),
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (db) => db.execute('PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"'),
      ),
    );
    try {
      await old.transaction((tx) async {
        await tx.execute('DROP TABLE business_cash_replica');
         await tx.execute('DROP TABLE business_backup_recoveries');
          await tx.execute('DROP TABLE business_reconciliations');
         await tx.execute('DROP TABLE business_cash_link_preparations');
        await tx.execute('PRAGMA user_version = 8');
      });
    } finally {
      await old.close();
    }
    db = await DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
    expect(await balance(account), 750);
    expect((await ledger().cashSync.pending(scoped)).single['command_id'], command);
    expect(await ledger().cashSync.replicaCheckpoint(scoped, session), isNull);
    await expectLater(
      ledger().cashSync.bindReplica(scoped, sessionId: session,
          checkpoint: cashTestCheckpoint(scope, account, balance: 750)),
      throwsA(isA<DirectoryAccessDenied>()),
    );
    await expectLater(
      ledger().move(scoped, commandId: _id(), accountId: account, amountMinor: 50, withdraw: true),
      throwsA(problem(BusinessLedgerProblem.sharedCashRequiresArbitration)),
    );
    expect(await balance(account), 750);
    expect((await ledger().cashSync.pending(scoped)).single['command_id'], command);
  });

  test(
    'two devices settle the same cash from durable outboxes without double applying',
    () async {
      final account = await bank(opening: 10000);
      final secondRoot = Directory('${root.path}/second');
      final secondKeys = FixtureDirectoryKeys();
      final secondWorkspace = DirectoryWorkspace(
        server: workspace.server,
        accountId: _id(),
        organizationId: workspace.organizationId,
      );
      final secondAccess = BusinessLedgerAccess(
        directory(owner: secondWorkspace),
        all,
        cashSessionId: _id(),
      );
      final firstSession = BusinessLedgerAccess(scope, all, cashSessionId: _id());
      Future<DirectoryDatabase> reopenSecond() => DirectoryDatabase.open(
        root: secondRoot,
        workspace: secondWorkspace,
        keys: secondKeys,
      );
      var secondDB = await reopenSecond();
      addTearDown(() => secondDB.close());
      final winner = _id();
      final loser = _id();
      await secondDB.ledger.createAccount(
        secondAccess,
        commandId: account,
        bankName: 'Bank fixture',
        accountName: 'Test SAR',
        accountNumber: '100',
        currency: 'SAR',
        openingMinor: 10000,
      );
      await ledger().cashSync.provision(
        access,
        account,
        grantVersion: 1,
        allowNegative: false,
      );
      await secondDB.ledger.cashSync.provision(
        secondAccess,
        account,
        grantVersion: 1,
        allowNegative: false,
      );
      await expectLater(
        ledger().move(
          access,
          commandId: _id(),
          accountId: account,
          amountMinor: 1,
          withdraw: false,
        ),
        throwsA(problem(BusinessLedgerProblem.sharedCashRequiresArbitration)),
      );
      await expectLater(ledger().cashSync.withdraw(
        access,
        commandId: winner,
        accountId: account,
        amountMinor: 10000,
      ), throwsA(problem(BusinessLedgerProblem.sharedCashRequiresArbitration)));
      expect(await balance(account), 10000);
      await ledger().cashSync.bindReplica(
        firstSession, sessionId: firstSession.cashSessionId!,
        checkpoint: cashTestCheckpoint(scope, account, balance: 10000),
      );
      await secondDB.ledger.cashSync.bindReplica(
        secondAccess, sessionId: secondAccess.cashSessionId!,
        checkpoint: cashTestCheckpoint(secondAccess.directory, account, balance: 10000),
      );
      await expectLater(ledger().cashSync.withdraw(
        BusinessLedgerAccess(scope, all, cashSessionId: secondAccess.cashSessionId),
        commandId: winner,
        accountId: account,
        amountMinor: 10000,
      ), throwsA(problem(BusinessLedgerProblem.sharedCashRequiresArbitration)));
      await ledger().cashSync.withdraw(
        firstSession,
        commandId: winner,
        accountId: account,
        amountMinor: 10000,
        description: 'Private note',
      );
      await secondDB.ledger.cashSync.withdraw(
        secondAccess,
        commandId: loser,
        accountId: account,
        amountMinor: 10000,
      );
      await secondDB.close();
      secondDB = await reopenSecond();
      expect((await secondDB.ledger.cashSync.pending(secondAccess)).single, {
        'command_id': loser,
        'account_id': account,
        'amount_minor': 10000,
        'currency': 'SAR',
        'grant_version': 1,
      });
      expect(
        (await ledger().cashSync.pending(access)).single.values,
        isNot(contains('Private note')),
      );

      Future<bool> apply(BusinessLedgerAccess grant, BusinessLedger device) =>
          device.cashSync.applyWithdrawal(
            grant,
            commandId: winner,
            accountId: account,
            sequence: 1,
            currency: 'SAR',
            amountMinor: 10000,
          );
      // The sender can fetch its accepted event after losing the send reply.
      expect(await apply(firstSession, ledger()), isTrue);
      await ledger().cashSync.decide(
        firstSession,
        commandId: winner,
        sequence: 1,
        decision: BusinessCashDecision.accepted,
      );
      expect(await ledger().cashSync.pending(access), isEmpty);
      expect(await balance(account), 0);
      expect(await apply(secondAccess, secondDB.ledger), isFalse);
      Future<void> reject() => secondDB.ledger.cashSync.decide(
        secondAccess,
        commandId: loser,
        sequence: 2,
        blockedBy: winner,
        decision: BusinessCashDecision.insufficientBalance,
      );
      await Future.wait([reject(), reject()]);
      await secondDB.close();
      secondDB = await reopenSecond();
      expect(await apply(secondAccess, secondDB.ledger), isTrue);
      expect(await apply(secondAccess, secondDB.ledger), isTrue);
      final rows = await secondDB.ledger.statement(secondAccess, account);
      expect(rows.map((row) => row['kind']), [
        'withdrawal',
        'withdrawal_reversal',
        'withdrawal',
        'opening_balance',
      ]);
      expect(rows.map((row) => row['delta_minor']), [
        -10000,
        10000,
        -10000,
        10000,
      ]);
      expect(
        (await secondDB.ledger.accounts(secondAccess)).single['balance_minor'],
        0,
      );
      expect(await secondDB.ledger.cashSync.pending(secondAccess), isEmpty);
      final report = await secondDB.ledger.moneyReport(secondAccess, currency: 'SAR');
      expect(report['balances']['total'], '0.00');
      expect(report['inflow']['total'], '0.00'); // the conflict reversal is not income
      expect(report['outflow']['total'], '100.00'); // only the accepted withdrawal
      expect(report['pending_shared_cash'], isFalse);
    },
  );
}
