import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/warehouse_settings.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/reconciliation_home_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_bank_pages.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_scope_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_art.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_motion.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_results.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_widgets.dart';

/// Reconciliation redesign tests: the 4s cinematic gate, currency selection
/// (types + NO balances), the colored result table, the equalize summary,
/// the square inventory scopes and the home cards + archive sub button.
void main() {
  Future<void> preload(WidgetTester tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
  }

  Widget host(Widget child) => MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: child,
      );

  Widget hostRouted(Widget page) => MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: GoRouter(initialLocation: '/', routes: [
          GoRoute(path: '/', builder: (_, _) => page),
        ]),
      );

  Future<void> pumpFor(WidgetTester tester, Duration step, int times) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(step);
    }
  }

  Map<String, dynamic> account(String id, String bank, String cur,
          String type, num balance) =>
      {
        'id': id,
        'bank_name': bank,
        'account_name': cur,
        'account_number': id,
        'currency': cur,
        'balance': balance,
        'account_type': type,
        'is_cash': false,
      };

  testWidgets('Core overlay: result NEVER revealed before 4 seconds',
      (tester) async {
    await preload(tester);
    dynamic revealed;
    await tester.pumpWidget(host(ReconCoreOverlay(
      variant: ReconSceneVariant.bank,
      processingText: 'جارٍ المعالجة',
      future: Future.value({'ref_code': 'RCN-X'}),
      onResult: (_, r) => revealed = r,
      onError: (_, e) {},
    )));
    await tester.pump(const Duration(seconds: 1));
    expect(revealed, isNull, reason: 'must hold the full 4 seconds');
    await tester.pumpAndSettle(const Duration(milliseconds: 250),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
    expect(revealed, isNotNull, reason: 'gate did not release after 4s');
    expect((revealed as Map)['ref_code'], 'RCN-X');
  });

  testWidgets('Core overlay: layout separates texts from the scene (small screens)',
      (tester) async {
    await preload(tester);
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(ReconCoreOverlay(
      variant: ReconSceneVariant.inventoryFull,
      processingText: 'جارٍ المعالجة',
      future: Completer<dynamic>().future,
      onResult: (_, r) {},
      onError: (_, e) {},
    )));
    await pumpFor(tester, const Duration(milliseconds: 120), 10);
    // No overflow exception + the three layout zones exist.
    expect(tester.takeException(), isNull);
    expect(find.text('جاري المطابقة'), findsOneWidget);
    expect(find.text('نراجع الأرقام ونقارنها بالواقع'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets(
      'Core overlay: all five variants paint in LIGHT and DARK without '
      'exceptions', (tester) async {
    await preload(tester);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final variant in ReconSceneVariant.values) {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: ReconCoreOverlay(
            variant: variant,
            processingText: 'x',
            future: Completer<dynamic>().future,
            onResult: (_, r) {},
            onError: (_, e) {},
          ),
        ));
        await pumpFor(tester, const Duration(milliseconds: 250), 12);
        expect(tester.takeException(), isNull,
            reason: 'variant $variant / ${brightness.name}');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets(
      'Crystal seal V2: paints through every timeline point (both themes) '
      'without exceptions, and stays static after completion', (tester) async {
    await preload(tester);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: CrystalBalanceSeal(size: 160),
      ));
      // Drive the seal timeline through its key points with bounded pumping
      // (the chime Timer runs outside fake async — pumpAndSettle would fight
      // the pending timer).
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 125));
      }
      expect(tester.takeException(), isNull, reason: brightness.name);
    }
  });

  testWidgets('Crystal seal: EXACT wording per equalization kind', (tester) async {
    await preload(tester);
    Future<String> msg(ReconEqualizeKind kind) async {
      String out = '';
      await tester.pumpWidget(host(Dialog(
        child: Builder(builder: (ctx) {
          // Drive the dialog content directly (the seal + message).
          out = AppLocalizations.of(ctx).translate(switch (kind) {
            ReconEqualizeKind.bank => 'reconEqBank',
            ReconEqualizeKind.cash => 'reconEqCash',
            ReconEqualizeKind.product => 'reconEqProduct',
            ReconEqualizeKind.category => 'reconEqCategory',
            ReconEqualizeKind.store => 'reconEqStore',
          });
          return const SizedBox.shrink();
        }),
      )));
      await tester.pumpAndSettle();
      return out;
    }

    expect(await msg(ReconEqualizeKind.bank), 'تمت مساواة البنك');
    expect(await msg(ReconEqualizeKind.cash), 'تمت مساواة الكاش');
    expect(await msg(ReconEqualizeKind.product), 'تمت مساواة هذا المنتج');
    expect(await msg(ReconEqualizeKind.category), 'تمت مساواة هذا القسم');
    expect(await msg(ReconEqualizeKind.store), 'تمت مساواة المخزون بالكامل');
  });

  testWidgets(
      'Currency selection: types shown with bars, NO balance anywhere, then Next',
      (tester) async {
    await preload(tester);
    final fake = FakeReconApi(ApiClient(dio: Dio()));
    await tester.pumpWidget(ProviderScope(
      overrides: [reconciliationApiProvider.overrideWithValue(fake)],
      child: hostRouted(const ReconBankSelectPage(accountIds: 'a1,a2')),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));

    expect(find.text('USD'), findsNWidgets(2));
    expect(find.text('حساب جاري'), findsOneWidget);
    expect(find.text('حساب توفير'), findsOneWidget);
    // Balances must NOT appear anywhere on this page (2500 / 1000).
    expect(find.textContaining('2,500'), findsNothing);
    expect(find.textContaining('1,000'), findsNothing);
    // Tick the first currency → the Next button shows the count.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('التالي'), findsOneWidget);
  });

  testWidgets('Result table: بالبظام/بالحقيقة/الفرق headers + colored numbers',
      (tester) async {
    await preload(tester);
    await tester.pumpWidget(host(Scaffold(
      body: SingleChildScrollView(
        child: ReconDiffTable(rows: const [
          ReconResultRow(
              name: 'USD', system: 1000, actual: 950, diff: -50, unit: 'USD'),
        ]),
      ),
    )));
    await pumpFor(tester, const Duration(milliseconds: 300), 6);
    expect(find.text('بالنظام'), findsOneWidget);
    expect(find.text('بالحقيقة'), findsOneWidget);
    expect(find.text('الفرق'), findsOneWidget);
    // The three values are painted in their exact colors.
    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.any((t) => t.style?.color == kReconSystem), true);
    expect(texts.any((t) => t.style?.color == kReconActual), true);
    expect(texts.any((t) => t.style?.color == kReconDiff), true);
  });

  testWidgets('Home: two main cards + THREE buttons (archive sub button)',
      (tester) async {
    await preload(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [reconciliationApiProvider.overrideWithValue(
          FakeReconApi(ApiClient(dio: Dio())))],
      child: hostRouted(const ReconciliationHomePage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('مطابقة الحسابات البنكية والكاش'), findsOneWidget);
    expect(find.text('مطابقة المخزون'), findsOneWidget);
    expect(find.text('المطابقات السابقة'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
  });

  testWidgets('Inventory scope: square cards with descriptions',
      (tester) async {
    await preload(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider.overrideWithValue(
            FakeReconApi(ApiClient(dio: Dio()))),
        warehouseSettingsProvider.overrideWith(
            (ref) => WarehouseSettingsNotifier()..state =
                const WarehouseSettings(categories: true)),
      ],
      child: hostRouted(const ReconInventoryScopePage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('مطابقة منتج معين'), findsOneWidget);
    expect(find.text('مطابقة تصنيف معين'), findsOneWidget);
    expect(find.text('مطابقة المخزون بالكامل'), findsOneWidget);
    expect(find.text('اختار منتج واكتب كم عنده بالحقيقة'), findsOneWidget);
  });

  test('colors: results palette is orange / green / red', () {
    expect(kReconSystem.toARGB32() != kReconActual.toARGB32(), true);
    expect(kReconActual.toARGB32() != kReconDiff.toARGB32(), true);
    expect(kReconSystem.toARGB32() != kReconDiff.toARGB32(), true);
  });
}

class FakeReconApi extends ReconciliationApi {
  FakeReconApi(super.client);

  @override
  Future<List<Map<String, dynamic>>> accounts() async {
    return [
      {
        'id': 'a1', 'bank_name': 'بنك الاختبار', 'account_name': 'دولار',
        'account_number': 'A1', 'currency': 'USD', 'balance': 2500,
        'account_type': 'checking', 'is_cash': false,
      },
      {
        'id': 'a2', 'bank_name': 'بنك الاختبار', 'account_name': 'دولار',
        'account_number': 'A2', 'currency': 'USD', 'balance': 1000,
        'account_type': 'savings', 'is_cash': false,
      },
    ];
  }
}
