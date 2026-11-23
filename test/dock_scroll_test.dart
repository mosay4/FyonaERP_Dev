import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/falcon_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';

void main() {
  testWidgets('LONG message + scroll DURING dock: falcon lands, no crash', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<void>();
    final longAnswer =
        'أنا الصقر، خبير التجارة والمخزون والتسويق في متجرك.\n'
        'الوضع الحالي: المخزون يكفي الطلب الحالي مع هامش ربح صحي.\n'
        'أرصد أن المبيعات تمشي بثبات والربح في النطاق المتوقع.\n'
        'انتبه: سكر وصل حد التنبيه، أعد طلبه قريباً قبل النفاد.\n'
        'الفرصة: شاي يحقق أعلى هامش، اعرضه صباحاً على الواجهة.\n'
        'التوصية: أعد طلب السكر والأرز هذا الأسبوع.\n'
        'وأنصحك بمتابعة حركة المنتجات الراكدة أسبوعياً.\n'
        'إذا احتجت خطة طلب شهرية، اسألني في أي وقت.';
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path.contains('/falcon/chat')) {
        handler.resolve(Response(
            requestOptions: options, statusCode: 200,
            data: {'answer': longAnswer}));
        return;
      }
      await gate.future;
      handler.resolve(Response(
          requestOptions: options, statusCode: 200, data: _report));
    }));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        inventoryApiProvider
            .overrideWithValue(InventoryApi(ApiClient(dio: dio))),
        currentUserIdProvider.overrideWithValue('tester'),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: ThemeData(brightness: Brightness.light),
        home: FalconPage(
            scope: 'inventory', refId: null, title: 'اختبار'),
      ),
    ));
    await tester.pump();
    gate.complete();
    await tester.pump(const Duration(milliseconds: 4300));
    await tester.pump(const Duration(milliseconds: 1200));

    await tester.enterText(find.byType(TextField), 'وش وضع المخزون؟');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    // Thinking min (test: 100ms) + morph settle + glide → streaming starts
    await tester.pump(const Duration(milliseconds: 700));
    // Streaming the long answer: many tokens (~60+) → pump generously
    await tester.pump(const Duration(milliseconds: 3000));
    // The answer should now be fully streamed; dock should be running/done.
    expect(find.textContaining('أنا الصقر'), findsOneWidget);
    // SCROLL DURING THE DOCK WINDOW
    await tester.drag(find.byType(ListView).first, const Offset(0, -250));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.drag(find.byType(ListView).first, const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 1500)); // dock + crossfade
    await tester.pump(const Duration(milliseconds: 600));
    // After dock: chips visible again (asking=false), no exceptions.
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Flush remaining timers (second-thinking guard etc.)
    await tester.pump(const Duration(seconds: 2));
  });
}

const _report = {
  'status': 'good',
  'status_line': 'الربح 30% والمخزون يكفي.',
  'attention': ['سكر وصل حد التنبيه.'],
  'recommendations': ['أعد طلب: سكر، أرز.'],
  'opportunity': '',
  'suggested_questions': ['وش أكثر المنتجات ربحًا؟'],
  'product_type': 'بقالة',
  'ai': true,
  'stats': {
    'report_currency': 'USD', 'unified': true,
    'total_sales': 120.0, 'total_profit': 36.0,
    'inventory_value': 80.0, 'total_cogs': 84.0,
    'products_count': 4, 'low_stock': [], 'out_of_stock': [],
    'top_sellers': [], 'top_profit': [], 'bottom_sellers': [],
    'slow_moving': [], 'weak_margin': [],
  },
};
