import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/services/currency/public_exchange_rates.dart';

/// Answers like the public sources, with the first source down.
Dio _fake({bool firstDown = true, bool allDown = false}) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain));
  final codes = {
    for (final c in ['EUR', 'SAR', 'AED', 'JPY', 'GBP', 'YER', 'EGP', 'TRY',
        'CNY', 'INR', 'CAD', 'AUD', 'CHF', 'KWD', 'QAR', 'OMR', 'BHD', 'JOD',
        'MAD', 'DZD', 'TND', 'LYD', 'IQD', 'SYP', 'LBP', 'SDG', 'PKR', 'BDT',
        'IDR', 'MYR', 'KRW', 'RUB'])
      c: c == 'SAR' ? 3.75 : 2.0,
  };
  dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
    final url = o.uri.toString();
    Response<String> ok(Object body) =>
        Response(requestOptions: o, statusCode: 200, data: body is String ? body : jsonEncode(body));
    if (allDown || (firstDown && url.contains('open.er-api'))) {
      return h.reject(DioException(requestOptions: o, type: DioExceptionType.connectionError));
    }
    if (url.contains('open.er-api')) return h.resolve(ok({'result': 'success', 'rates': codes}));
    if (url.contains('currency-api')) {
      return h.resolve(ok({'usd': {for (final e in codes.entries) e.key.toLowerCase(): e.value}}));
    }
    if (url.contains('2dec.net')) {
      return h.resolve(ok('''
        <h2 class="city-name">صنعاء</h2><table>
        <tr><td class="currency-name">دولار امريكي</td><td class="price-value">535.00</td><td class="price-value">533.00</td></tr></table>
        <h2 class="city-name">عدن</h2><table>
        <tr><td class="currency-name">دولار امريكي</td><td class="price-value">1558.00</td><td class="price-value">1550.00</td></tr></table>'''));
    }
    return h.reject(DioException(requestOptions: o, type: DioExceptionType.connectionError));
  }));
  return dio;
}

void main() {
  test('a source that is down is replaced by the next one', () async {
    final data = await PublicExchangeRates(dio: _fake()).fetch();
    expect((data!['meta'] as Map)['global_source'], 'currency-api');
    expect((data['global'] as Map)['SAR'], 3.75);
    final yemen = data['yemen'] as Map;
    expect(((yemen['sanaa'] as Map)['USD'] as Map)['average'], 534);
    expect(((yemen['aden'] as Map)['USD'] as Map)['average'], 1554);
  });

  test('every source down: nothing is invented', () async {
    expect(await PublicExchangeRates(dio: _fake(allDown: true)).fetch(), isNull);
  });

  test('the app converts every currency, Yemeni old/new included', () async {
    final engine = CurrencyEngine(public: PublicExchangeRates(dio: _fake(firstDown: false)));
    await engine.load(forceRefresh: true);
    expect(engine.convertSafe(53400, 'YER_OLD', 'USD'), closeTo(100, 0.001));
    expect(engine.getRate('USD', 'YER_NEW'), 1554);
    expect(engine.getRate('USD', 'SAR'), 3.75);
  });
}
