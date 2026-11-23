import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/presentation/widgets/product_picker.dart';

/// Real-scenario gate tests for the shared product picker:
/// 1. SALE mode (checkStock: true) blocks 0-stock products with a RED snack.
/// 2. PURCHASE mode (checkStock: false) adds 0-stock products freely and the
///    quantity stepper is never capped by stock (buying ADDS stock).
/// 3. Scanning an UNKNOWN barcode shows the solid RED snack (never green).
/// 4. Scanning a known 0-stock product follows the same mode gate.
void main() {
  Map<String, dynamic> product(String id, String name, double stock) => {
        'id': id,
        'name': name,
        'stock': stock,
        'price': '10',
        'unit': 'قطعة',
        'is_service': false,
      };

  InventoryApi stubApi(Interceptor interceptor) {
    final dio = Dio();
    dio.interceptors.add(interceptor);
    return InventoryApi(ApiClient(dio: dio));
  }

  Interceptor listOnly(List<Map<String, dynamic>> products) =>
      InterceptorsWrapper(onRequest: (o, h) {
        h.resolve(Response(requestOptions: o, statusCode: 200,
            data: {'data': products}));
      });

  Future<void> pumpUntilSnack(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (tester.any(find.byType(SnackBar))) return;
    }
    fail('snack never appeared');
  }

  /// Opens the picker sheet. Returns the popped result through [resultOut]
  /// when [captureResult] is set (purchase/save flow).
  Future<void> openSheet(
    WidgetTester tester, {
    required InventoryApi api,
    bool checkStock = true,
    String? initialBarcode,
    void Function(List<PickedProduct>?)? resultOut,
  }) async {
    // The sheet wraps ListTiles in a tinted Container — a benign styling
    // warning that must not fail these behavior tests.
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final r = await showProductMultiPicker(
                  context,
                  api: api,
                  title: 'اختيار المنتجات',
                  checkStock: checkStock,
                  initialBarcode: initialBarcode,
                );
                resultOut?.call(r);
              },
              child: const Text('OPEN'),
            ),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle(); // let localizations resolve → home builds
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle(); // sheet entrance + initial list load
  }

  testWidgets('SALE mode: 0-stock product is blocked with a RED snack',
      (tester) async {
    await openSheet(tester,
        api: stubApi(listOnly(
            [product('p0', 'منتج نافذ', 0), product('p1', 'منتج متوفر', 5)])));

    await tester.tap(find.text('منتج نافذ'));
    await pumpUntilSnack(tester);
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.backgroundColor, AppColors.danger); // RED, never green
    expect(find.textContaining('حفظ (0)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'PURCHASE mode: 0-stock product is addable and stepper is uncapped',
      (tester) async {
    List<PickedProduct>? result;
    await openSheet(
      tester,
      api: stubApi(listOnly(
          [product('p0', 'منتج نافذ', 0), product('p1', 'منتج متوفر', 5)])),
      checkStock: false,
      resultOut: (r) => result = r,
    );

    await tester.tap(find.text('منتج نافذ')); // stock == 0 → must be allowed
    await tester.pumpAndSettle();
    expect(find.textContaining('حفظ (1)'), findsOneWidget);

    // Stepper: + beyond stock 0 must be allowed in purchase mode.
    final plus = find.widgetWithIcon(IconButton, Icons.add).last;
    await tester.tap(plus);
    await tester.pumpAndSettle();
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget); // 1 + 2 taps

    await tester.tap(find.textContaining('حفظ'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.single.product['id'], 'p0');
    expect(result!.single.quantity, 3);
  });

  testWidgets('Unknown barcode scan shows the RED snack (never green)',
      (tester) async {
    final api = stubApi(InterceptorsWrapper(onRequest: (o, h) {
      if (o.path.contains('resolve-barcode')) {
        h.reject(DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(
                requestOptions: o,
                statusCode: 500,
                data: {'success': false, 'message': 'لا يوجد منتج بهذا الباركود'})));
        return;
      }
      h.resolve(Response(requestOptions: o, statusCode: 200,
          data: {'data': <Map<String, dynamic>>[]}));
    }));
    await openSheet(tester, api: api, initialBarcode: 'UNKNOWN-QR');
    await pumpUntilSnack(tester);
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.backgroundColor, AppColors.danger);
    // Red snack (white text) + red inline message — never green.
    expect(find.text('باركود غير معروف'), findsNWidgets(2));
    final inline = tester.widget<Text>(find.text('باركود غير معروف').last);
    expect(inline.style?.color, AppColors.danger);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'SALE mode: scanning a known 0-stock product is blocked with a RED snack',
      (tester) async {
    Response<Object?> ok(RequestOptions o, Map<String, dynamic> data) =>
        Response(requestOptions: o, statusCode: 200, data: data);
    final resolveOk = InterceptorsWrapper(onRequest: (o, h) {
      if (o.path.contains('resolve-barcode')) {
        h.resolve(ok(o, {
          'data': {'product': product('p0', 'منتج نافذ', 0), 'unit': null}
        }));
        return;
      }
      h.resolve(ok(o, {'data': <Map<String, dynamic>>[]}));
    });

    await openSheet(tester, api: stubApi(resolveOk), initialBarcode: 'GOOD0');
    await pumpUntilSnack(tester);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).backgroundColor,
        AppColors.danger);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'PURCHASE mode: scanning a known 0-stock product adds it successfully',
      (tester) async {
    Response<Object?> ok(RequestOptions o, Map<String, dynamic> data) =>
        Response(requestOptions: o, statusCode: 200, data: data);
    final resolveOk = InterceptorsWrapper(onRequest: (o, h) {
      if (o.path.contains('resolve-barcode')) {
        h.resolve(ok(o, {
          'data': {'product': product('p0', 'منتج نافذ', 0), 'unit': null}
        }));
        return;
      }
      h.resolve(ok(o, {'data': <Map<String, dynamic>>[]}));
    });

    await openSheet(tester,
        api: stubApi(resolveOk), checkStock: false, initialBarcode: 'GOOD0');
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('تمت إضافة'), findsOneWidget);
    expect(find.textContaining('حفظ (1)'), findsOneWidget);
  });
}