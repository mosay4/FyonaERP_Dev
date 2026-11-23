import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/home_promo_banner.dart';

import 'test_utils.dart';

/// Proves per-banner carousel timing: each banner stays visible for exactly
/// its own `carousel_seconds` before flipping — never a fixed global tick.
///
/// Banner A = 3s, banner B = 2s:
///   t=0..3 -> A | t=3..5 -> B | t=5.. -> A again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    // Repo-wide FakeAsync fix lives in test_utils.dart: preload ARB with
    // real async I/O here, or localization trees never mount in tests.
    return ensureTestLocalization();
  });

  Dio makeFakeDio() {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: <String, dynamic>{
            'success': true,
            'data': <String, dynamic>{
              'entities': <dynamic>[],
              'server_time': DateTime.now().toUtc().toIso8601String(),
              'banners': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'banner-a',
                  'title_key': 'A',
                  'color_start': '#111111',
                  'color_end': '#222222',
                  'carousel_seconds': 3,
                  'is_active': true,
                },
                <String, dynamic>{
                  'id': 'banner-b',
                  'title_key': 'B',
                  'color_start': '#333333',
                  'color_end': '#444444',
                  'carousel_seconds': 2,
                  'is_active': true,
                },
              ],
            },
          },
        ));
      },
    ));
    return dio;
  }

  int currentPage(WidgetTester tester) {
    final pv = tester.widget<PageView>(find.byType(PageView));
    return ((pv.controller?.page ?? 0).toDouble()).round();
  }

  testWidgets('each banner shows for its own carousel_seconds', (tester) async {
    await pumpLocalizedWidget(
      tester,
      const HomePromoBanners(),
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: makeFakeDio())),
      ],
    );
    // Flush async loads + post-frame flip scheduling.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PageView), findsOneWidget);
    expect(currentPage(tester), 0, reason: 'starts on banner A');

    // t=2: A (3s) still showing.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(currentPage(tester), 0, reason: 'A must stay its full 3s');

    // t=4.5: A flipped to B at t=3 (plus 400ms animation).
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(currentPage(tester), 1, reason: 'must flip to B after A\'s 3s');

    // t=7: B (2s) flipped back to A at t=5.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(currentPage(tester), 0, reason: 'must flip back after B\'s 2s');
  });
}
