import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/reports/data/reports_api.dart';
import 'package:fyona_flutter/features/reports/presentation/pages/report_view_page.dart';
import 'package:fyona_flutter/features/reports/presentation/widgets/report_widgets.dart';

class _PendingReports extends BusinessReportsApi {
  _PendingReports() : super(ApiClient(dio: Dio()));
  final requests = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> salesPurchases(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) {
    final request = Completer<Map<String, dynamic>>();
    requests.add(request);
    return request.future;
  }
}

Map<String, dynamic> report(int total) => {
  'currency': 'SAR',
  'totals_complete': true,
  'sales': {
    'total': total,
    'paid': 0,
    'remaining': 0,
    'count': 1,
    'gaps': [],
    'chart': [],
    'returns': {'total': 0, 'count': 0},
  },
  'purchases': {
    'total': 0,
    'paid': 0,
    'remaining': 0,
    'count': 0,
    'gaps': [],
    'chart': [],
    'returns': {'total': 0, 'count': 0},
  },
  'top_products': [],
  'invoices': [],
};

void main() {
  testWidgets('rapid filter changes never relabel old or out-of-order totals', (
    tester,
  ) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final api = _PendingReports();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [businessReportsApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ReportViewPage(kind: 'sales', autoStart: true),
        ),
      ),
    );
    await tester.pump();
    expect(api.requests.length, 1);
    api.requests[0].complete(report(111));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('111'), findsWidgets);
    var chips = tester.widget<RefPeriodChips>(find.byType(RefPeriodChips));
    chips.onSelect('today');
    chips.onSelect('week');
    await tester.pump();
    expect(api.requests.length, 3);
    expect(find.textContaining('111'), findsNothing);
    api.requests[2].complete(report(333));
    await tester.pumpAndSettle();
    expect(find.textContaining('333'), findsWidgets);
    api.requests[1].complete(report(222));
    await tester.pumpAndSettle();
    expect(find.textContaining('333'), findsWidgets);
    expect(find.textContaining('222'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
