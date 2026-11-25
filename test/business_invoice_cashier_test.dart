import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_design_models.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_doc.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_labels.dart';
import 'package:fyona_flutter/features/invoices/presentation/pdf/invoice_pdf.dart';
import 'package:fyona_flutter/features/invoices/presentation/widgets/invoice_preview_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();
const _customer = DirectoryPartyKind.customer;

void main() {
  final workspace = DirectoryWorkspace(
    server: 'http://localhost:18083/api/v1',
    accountId: _id(),
    organizationId: _id(),
  );
  final branch = _id();
  DirectoryAccess scopeOf({bool member = false}) => DirectoryAccess(
        workspace: workspace,
        branchId: branch,
        readable: {_customer},
        writable: {_customer},
        member: member,
      );
  final all = BusinessLedgerAction.values.toSet();
  final owner = BusinessLedgerAccess(scopeOf(), all);
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryDatabase db;

  Future<DirectoryDatabase> open() =>
      DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-cashier-');
    keys = FixtureDirectoryKeys();
    db = await open();
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<Map<String, Object?>> sell(BusinessLedgerAccess access, String? cashier) async {
    final buyer = await db.create(scopeOf(), _customer, name: 'Buyer ${_id()}');
    return db.ledger.issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: buyer.id,
      cashierName: cashier,
      lines: const [
        CommerceIssueLine(description: 'Repair', quantity: '2', unitMinor: 1500, isService: true),
      ],
    );
  }

  test('owner invoice + return store «التاجر» snapshot on the row', () async {
    final sale = await sell(owner, '  أحمد التاجر  ');
    final doc = await db.ledger.commerceInvoice(
        owner, BusinessInvoiceKind.sale, '${sale['id']}');
    expect(doc!['cashier_name'], 'أحمد التاجر');
    expect(doc['cashier_role'], 'owner');

    final item = (doc['items'] as List).first as Map;
    await db.ledger.confirmCommerceReturn(
      owner,
      commandId: _id(),
      kind: BusinessInvoiceKind.sale,
      invoiceId: '${sale['id']}',
      cashierName: 'أحمد التاجر',
      lines: [CommerceReturnLine(itemId: '${item['id']}', quantity: '1')],
    );
    final returns = await db.ledger.commerceReturnsList(owner);
    expect(returns.single['cashier_name'], 'أحمد التاجر');
    expect(returns.single['cashier_role'], 'owner');

    final invoiceDoc = InvoiceDoc.from(Map<String, dynamic>.from(doc));
    expect(invoiceDoc.cashier, 'أحمد التاجر');
    expect(const InvoiceLabels(true).cashierFor(invoiceDoc.cashierRole), 'التاجر');
    expect(const InvoiceLabels(false).cashierFor(invoiceDoc.cashierRole), 'Merchant');
  });

  test('employee (member scope) invoice is labelled «الكاشير»', () async {
    final employee = BusinessLedgerAccess(scopeOf(member: true), all);
    final sale = await sell(employee, 'سارة الموظفة');
    final doc = await db.ledger.commerceInvoice(
        owner, BusinessInvoiceKind.sale, '${sale['id']}');
    expect(doc!['cashier_name'], 'سارة الموظفة');
    expect(doc['cashier_role'], 'employee');
    final d = InvoiceDoc.from(Map<String, dynamic>.from(doc));
    expect(const InvoiceLabels(true).cashierFor(d.cashierRole), 'الكاشير');
    expect(const InvoiceLabels(false).cashierFor(d.cashierRole), 'Cashier');
  });

  test('v18 ledgers gain the cashier columns; old invoices show no cashier', () async {
    final old = await sell(owner, null);
    await db.close();
    // Rebuild the v18 file: invoices/returns without the cashier columns.
    final raw = await databaseFactoryFfi.openDatabase(
      DirectoryDatabase.filePath(root, workspace),
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (sql) async {
          await sql.execute('PRAGMA key = "x\'${keys.memory[workspace.storageId]!}\'"');
        },
      ),
    );
    try {
      for (final t in ['business_commerce_invoices', 'business_commerce_returns']) {
        for (final c in ['created_by_name', 'created_by_role']) {
          await raw.execute('ALTER TABLE $t DROP COLUMN $c');
        }
      }
      await raw.execute('PRAGMA user_version = 18');
    } finally {
      await raw.close();
    }
    db = await open();
    final before = await db.ledger.commerceInvoice(
        owner, BusinessInvoiceKind.sale, '${old['id']}');
    expect(before!['cashier_name'], isNull);
    final legacy = InvoiceDoc.from(Map<String, dynamic>.from(before));
    expect(legacy.cashier, isEmpty); // → no cashier line, no crash
    final fresh = await sell(owner, 'Owner');
    final after = await db.ledger.commerceInvoice(
        owner, BusinessInvoiceKind.sale, '${fresh['id']}');
    expect(after!['cashier_name'], 'Owner');
    expect(after['cashier_role'], 'owner');
  });

  testWidgets('invoice preview shows the merchant / cashier line', (tester) async {
    Map<String, dynamic> inv(String? name, String? role) => {
          'invoice_number': 'INV-1',
          'invoice_type': 'sale',
          'invoice_date': '2026-11-25',
          'currency': 'SAR',
          'customer_name': 'Buyer',
          'total': 10,
          'items': const [],
          'cashier_name': name,
          'cashier_role': role,
        };
    Future<void> show(Map<String, dynamic> invoice) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: InvoicePreviewCard(
                invoice: invoice,
                design: InvoiceDesignPreset.defaults('paper'),
                isPurchase: false,
              ),
            ),
          ),
        ));
    final L = InvoiceLabels.current();
    await show(inv('أحمد', 'owner'));
    expect(find.text('${L.merchant}: أحمد'), findsOneWidget);
    await show(inv('سارة', 'employee'));
    expect(find.text('${L.cashier}: سارة'), findsOneWidget);
    await show(inv(null, null));
    expect(find.textContaining(L.cashier), findsNothing);
    expect(find.textContaining(L.merchant), findsNothing);
  });

  test('PDF / thermal templates build with and without a cashier', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final template in ['paper', 'thermal', 'thermal58']) {
      for (final name in ['أحمد', null]) {
        final bytes = await buildInvoicePdf(
          {
            'invoice_number': 'INV-1',
            'invoice_type': 'sale',
            'invoice_date': '2026-11-25',
            'currency': 'SAR',
            'total': 10,
            'items': const [],
            'cashier_name': name,
            'cashier_role': 'owner',
          },
          InvoiceDesignPreset.defaults(template),
          templateId: template,
          isPurchase: false,
        );
        expect(bytes, isNotEmpty);
      }
    }
  });
}
