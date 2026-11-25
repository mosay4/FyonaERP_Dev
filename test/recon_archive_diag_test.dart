import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_detail_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_archive_page.dart';

void main() {
  Future<void> open(WidgetTester tester, ReconciliationApi api) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(ProviderScope(
      overrides: [reconciliationApiProvider.overrideWithValue(api)],
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: GoRouter(routes: [
          GoRoute(path: '/', builder: (_, _) => const ReconArchivePage()),
          GoRoute(
              path: '/reconciliation/detail',
              builder: (_, _) => const Scaffold(body: Text('DETAIL'))),
        ]),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 200),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 8));
  }

  testWidgets('REGRESSION: archive renders items (no endless spinner)',
      (tester) async {
    await open(tester, ArchiveApi(ApiClient(dio: Dio()), mode: 'items'));
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'still loading!');
    expect(find.textContaining('RCN-1'), findsWidgets,
        reason: 'items missing');
    // ONLY the result chip: اختلاف (difference) / سليم (clear).
    expect(find.text('اختلاف'), findsOneWidget);
    expect(find.text('سليم'), findsOneWidget);
    expect(find.text('تمت'), findsNothing);
    expect(find.text('جاهزة'), findsNothing);
    // Newest first: RCN-1 (2026-10-12) must be ABOVE RCN-2 (2026-10-11).
    final y1 = tester.getTopLeft(find.textContaining('RCN-1')).dy;
    final y2 = tester.getTopLeft(find.textContaining('RCN-2')).dy;
    expect(y1 < y2, true, reason: 'newest must come first');
    expect(find.text('فحص البنوك والكاش'), findsOneWidget);
    expect(find.text('الكل'), findsOneWidget);
    expect(find.text('هذا الشهر'), findsOneWidget);
    expect(find.text('هذه السنة'), findsOneWidget);
    expect(find.text('بين تاريخين'), findsOneWidget);
  });

  testWidgets('REGRESSION: archive empty shows the empty text',
      (tester) async {
    await open(tester, ArchiveApi(ApiClient(dio: Dio()), mode: 'empty'));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('لا توجد فحوصات محفوظة'), findsOneWidget);
  });

  testWidgets('REGRESSION: archive failure clears loading (never hangs)',
      (tester) async {
    await open(tester, ArchiveApi(ApiClient(dio: Dio()), mode: 'throw'));
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'a failed fetch must NOT spin forever');
  });
}

class ArchiveApi extends ReconciliationApi {
  final String mode;
  ArchiveApi(super.client, {required this.mode});

  @override
  Future<List<Map<String, dynamic>>> archive({
    String? rtype,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
    int page = 1,
  }) async {
    if (mode == 'throw') {
      throw DioException(requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError);
    }
    if (mode == 'empty') return const [];
    return [
      {
        'id': 'r1', 'ref_code': 'RCN-1', 'rtype': 'bank', 'scope': 'accounts',
        'status': 'approved', 'created_at': '2026-10-12T10:00:00Z',
        'has_diff': true, 'result': {'settled': 2},
      },
      {
        'id': 'r2', 'ref_code': 'RCN-2', 'rtype': 'inventory',
        'scope': 'product', 'status': 'approved',
        'created_at': '2026-10-11T10:00:00Z', 'has_diff': false, 'result': {},
      },
    ];
  }
}

class DetailApprovedApi extends ReconciliationApi {
  DetailApprovedApi(super.client);
  @override
  Future<Map<String, dynamic>> detail(String reconId) async {
    return {
      'id': reconId,
      'ref_code': 'RCN-A1',
      'rtype': 'bank',
      'status': 'approved',
      'measured_at': '2026-10-12T10:00:00',
      'approved_at': '2026-10-12T10:05:00',
      'lines': [
        {'currency': 'USD', 'name': 'دولار أمريكي', 'bank_name': 'بنك',
         'system': 1000, 'actual': 900, 'diff': -100, 'status': 'short',
         'account_type': 'checking'},
      ],
      'settlements': [
        {'name': 'دولار أمريكي', 'currency': 'USD', 'before': 1000,
         'after': 900, 'diff': -100, 'applied': true},
      ],
    };
  }
}

class ReconDetailApi extends ReconciliationApi {
  ReconDetailApi(super.client);
  @override
  Future<Map<String, dynamic>> detail(String reconId) async {
    // A CHECKED (not equalized) record WITH differences — the old detail page
    // lied here with «كل شي مطابق».
    return {
      'id': reconId,
      'ref_code': 'RCN-D1',
      'rtype': 'bank',
      'status': 'checked',
      'measured_at': '2026-10-12T10:00:00',
      'lines': [
        {'currency': 'USD', 'name': 'دولار أمريكي', 'bank_name': 'بنك',
         'system': 1000, 'actual': 900, 'diff': -100, 'status': 'short'},
      ],
      'settlements': [],
    };
  }
}
