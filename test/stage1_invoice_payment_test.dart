import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_design_models.dart';
import 'package:fyona_flutter/features/invoices/presentation/widgets/invoice_preview_card.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/returns/data/returns_api.dart';
import 'package:fyona_flutter/features/returns/presentation/providers/returns_providers.dart';
import 'package:fyona_flutter/features/sales/data/sales_api.dart';
import 'package:fyona_flutter/features/sales/presentation/providers/sale_providers.dart';
import 'package:fyona_flutter/shared/widgets/invoice_amount.dart';
import 'package:shared_preferences/shared_preferences.dart';

const huge = 999999999999.99;
final invoice = <String, dynamic>{
  'invoice_number': 'INV-1', 'status': 'confirmed', 'currency': 'SAR',
  'customer_name': 'عميل', 'supplier_name': 'مورد',
  'total': huge, 'subtotal': huge, 'paid_amount': huge, 'balance': huge,
  'items': [
    {'description': 'منتج', 'quantity': 1, 'unit_name': 'حبة',
      'unit_price': huge, 'total': huge},
  ],
};

class FakeSales extends SalesApi {
  FakeSales() : super(ApiClient(dio: Dio()));
  List<dynamic> accounts = [];
  int calls = 0;
  @override
  Future<Map<String, dynamic>> getInvoice(String id) async => invoice;
  @override
  Future<List<dynamic>> bankAccounts() async { calls++; return accounts; }
}

class FakePurchase extends PurchaseApi {
  FakePurchase() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> getInvoice(String id) async => invoice;
}

class FakeReturns extends ReturnsApi {
  FakeReturns() : super(ApiClient(dio: Dio()));
  List<dynamic> accounts = [];
  int calls = 0;
  @override
  Future<List<dynamic>> bankAccounts() async { calls++; return accounts; }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final rtl in [true, false]) {
    for (final target in ['sale', 'purchase', 'paper', 'thermal', 'thermal58']) {
      testWidgets('$target huge money stays inside cells rtl=$rtl', (tester) async {
        await tester.runAsync(() => AppLocalizations.preload('ar'));
        tester.view.physicalSize = const Size(360, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // «عرض الفاتورة» (sale & purchase) renders InvoicePreviewCard.
        final Widget page = Scaffold(body: SingleChildScrollView(child: InvoicePreviewCard(
          invoice: invoice,
          design: InvoiceDesignPreset(
            templateId: target == 'sale' || target == 'purchase' ? 'paper' : target,
            showQR: false, showSignature: false, showStamp: false),
          isPurchase: target == 'purchase',
        )));
        await tester.pumpWidget(ProviderScope(
          overrides: [salesApiProvider.overrideWithValue(FakeSales()),
            purchaseApiProvider.overrideWithValue(FakePurchase())],
          child: MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: child!),
            home: page,
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final values = find.widgetWithText(InvoiceAmount, fmtNum(huge));
        expect(values, findsAtLeastNWidgets(2)); // unit price AND line total
        for (final element in values.evaluate()) {
          final box = element.renderObject! as RenderBox;
          final text = find.descendant(of: find.byWidget(element.widget), matching: find.byType(Text));
          final rect = tester.getRect(text);
          final bounds = box.localToGlobal(Offset.zero) & box.size;
          expect(rect.left, greaterThanOrEqualTo(bounds.left - .01));
          expect(rect.right, lessThanOrEqualTo(bounds.right + .01));
          expect(tester.widget<Text>(text).overflow, isNot(TextOverflow.ellipsis));
        }
      });
    }
  }

  test('sale and return caches refresh empty data, dedupe and follow branch epoch', () async {
    final sales = FakeSales();
    final returns = FakeReturns();
    final c = ProviderContainer(overrides: [salesApiProvider.overrideWithValue(sales),
      returnsApiProvider.overrideWithValue(returns)]);
    addTearDown(c.dispose);
    expect(await c.read(saleAccountsProvider.future), isEmpty);
    expect(await c.read(returnAccountsProvider.future), isEmpty);
    final cash = {'id': 'cash-b1', 'bank_name': 'كاش', 'currency': 'SAR'};
    final bank = {'id': 'bank-b1', 'bank_name': 'بنك', 'currency': 'SAR'};
    sales.accounts = returns.accounts = [cash, bank, cash];
    expect((await c.refresh(saleAccountsProvider.future)).map((a) => a['id']), ['cash-b1', 'bank-b1']);
    expect((await c.refresh(returnAccountsProvider.future)).length, 2);
    sales.accounts = returns.accounts = [
      {'id': 'cash-b2', 'bank_name': 'كاش', 'currency': 'SAR'}];
    c.read(branchEpochProvider.notifier).state++;
    expect((await c.read(saleAccountsProvider.future)).single['id'], 'cash-b2');
    expect((await c.read(returnAccountsProvider.future)).single['id'], 'cash-b2');
    expect(sales.calls, 3);
    expect(returns.calls, 3);
  });

  test('chat scrubber has an explicit local LTR direction', () {
    final source = File('lib/features/personal/presentation/pages/chat_page.dart').readAsStringSync();
    expect(RegExp(r'Directionality\(\s*textDirection: TextDirection.ltr,\s*child: VideoProgressIndicator\(').hasMatch(source), isTrue);
  });
}
