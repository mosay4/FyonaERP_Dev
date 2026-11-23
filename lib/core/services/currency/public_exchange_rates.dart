import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Exchange rates fetched by the device itself from free public sources —
/// no API key, no FYONA server load. Sources are tried in order; the first
/// that answers with a sane table wins, the next is used if one is down.
///
/// The result has the same shape as the server's `/personal/exchange-rates`
/// data, so every existing reader (Personal, Business debts, banks, reports)
/// uses it unchanged, and the last good copy stays on the device offline.
class PublicExchangeRates {
  PublicExchangeRates({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
              followRedirects: true,
              responseType: ResponseType.plain,
              headers: {'Accept': 'application/json, text/html'},
            ),
          );

  final Dio _dio;

  /// Global rates per 1 USD, most complete and fresh sources first.
  static final List<(String, String, Map<String, double>? Function(Object?))>
  _globalSources = [
    ('open.er-api', 'https://open.er-api.com/v6/latest/USD', _openErApi),
    (
      'currency-api',
      'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json',
      _fawaz,
    ),
    (
      'currency-api',
      'https://latest.currency-api.pages.dev/v1/currencies/usd.min.json',
      _fawaz,
    ),
    ('floatrates', 'https://www.floatrates.com/daily/usd.json', _floatRates),
    ('frankfurter', 'https://api.frankfurter.dev/v1/latest?base=USD', _frankfurter),
  ];

  /// Yemen has two market rates (Sana'a = YER_OLD, Aden = YER_NEW).
  static const _yemenSource = 'https://www.2dec.net/rate.html';

  Future<Map<String, dynamic>?> fetch() async {
    final results = await Future.wait([_global(), _yemen()]);
    final global = results[0] as (String, Map<String, double>)?;
    final yemen = results[1] as Map<String, Map<String, Map<String, double>>>?;
    if (global == null && yemen == null) return null;
    final now = DateTime.now().toUtc().toIso8601String();
    final observations = <String, Map<String, Object?>>{
      if (global != null)
        for (final code in global.$2.keys)
          if (!code.startsWith('YER'))
            code: {'observed_at': now, 'provider': global.$1, 'source': global.$1},
      if (yemen?['sanaa']?.isNotEmpty == true)
        'YER_OLD': {'observed_at': now, 'provider': '2dec.net', 'source': '2dec.net'},
      if (yemen?['aden']?.isNotEmpty == true)
        'YER_NEW': {'observed_at': now, 'provider': '2dec.net', 'source': '2dec.net'},
    };
    return {
      'global': {
        if (global != null)
          for (final MapEntry(:key, :value) in global.$2.entries)
            if (!key.startsWith('YER')) key: value,
        'USD': 1.0,
      },
      'yemen': {
        'sanaa': yemen?['sanaa'] ?? const {},
        'aden': yemen?['aden'] ?? const {},
        'last_updated': now,
        'source': yemen == null ? 'unavailable' : '2dec.net',
      },
      'meta': {
        'fetched_at': now,
        'last_checked_at': now,
        'global_source': global?.$1 ?? 'unavailable',
        'yemen_source': yemen == null ? 'unavailable' : '2dec.net',
        'observations': observations,
      },
      'admin_rates': const [],
    };
  }

  Future<(String, Map<String, double>)?> _global() async {
    for (final (name, url, parse) in _globalSources) {
      try {
        final response = await _dio.get<String>(url);
        final rates = parse(_json(response.data));
        if (rates != null && rates.length >= 30 && (rates['EUR'] ?? 0) > 0) {
          return (name, rates);
        }
      } catch (_) {
        // Down or changed: the next source answers.
      }
    }
    return null;
  }

  Future<Map<String, Map<String, Map<String, double>>>?> _yemen() async {
    try {
      final response = await _dio.get<String>(_yemenSource);
      final html = response.data ?? '';
      final sanaa = _city(html, 'صنعاء');
      final aden = _city(html, 'عدن');
      if (sanaa.isEmpty && aden.isEmpty) return null;
      return {'sanaa': sanaa, 'aden': aden};
    } catch (_) {
      return null;
    }
  }

  static final _cityHeader = RegExp(r'<h2\s+class="city-name">\s*([^<]+?)\s*</h2>');
  static const _arabicNames = {
    'دولار امريكي': 'USD',
    'ريال سعودي': 'SAR',
  };

  static Map<String, Map<String, double>> _city(String html, String city) {
    final headers = _cityHeader.allMatches(html).toList();
    final index = headers.indexWhere((m) => m.group(1)!.trim() == city);
    if (index < 0) return const {};
    final start = headers[index].end;
    final end = index + 1 < headers.length ? headers[index + 1].start : html.length;
    final section = html.substring(start, end);
    final out = <String, Map<String, double>>{};
    for (final row in RegExp(r'<tr>(.*?)</tr>', dotAll: true).allMatches(section)) {
      final body = row.group(1)!;
      final name = RegExp(r'class="currency-name"[^>]*>([^<]+)<').firstMatch(body);
      final code = name == null ? null : _arabicNames[name.group(1)!.trim()];
      if (code == null) continue;
      final prices = [
        for (final m in RegExp(r'class="price-value[^"]*">\s*([\d,.]+)\s*<').allMatches(body))
          double.tryParse(m.group(1)!.replaceAll(',', '')),
      ];
      if (prices.length < 2 || prices[0] == null || prices[1] == null) continue;
      final sell = prices[0]!, buy = prices[1]!;
      if (sell <= 0 || buy <= 0) continue;
      out[code] = {'buy': buy, 'sell': sell, 'average': (sell + buy) / 2};
    }
    return out;
  }

  static Object? _json(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static Map<String, double>? _numbers(Object? map, {bool lower = false}) {
    if (map is! Map) return null;
    final out = <String, double>{};
    for (final MapEntry(:key, :value) in map.entries) {
      final code = '$key'.toUpperCase();
      if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) continue;
      final rate = value is num ? value.toDouble() : double.tryParse('$value');
      if (rate != null && rate.isFinite && rate > 0) out[code] = rate;
    }
    return out;
  }

  static Map<String, double>? _openErApi(Object? json) =>
      json is Map && json['result'] == 'success' ? _numbers(json['rates']) : null;

  static Map<String, double>? _fawaz(Object? json) =>
      json is Map ? _numbers(json['usd']) : null;

  static Map<String, double>? _frankfurter(Object? json) =>
      json is Map ? _numbers({...?json['rates'] as Map?, 'USD': 1}) : null;

  static Map<String, double>? _floatRates(Object? json) {
    if (json is! Map) return null;
    return _numbers({
      for (final MapEntry(:key, :value) in json.entries)
        if (value is Map) key: value['rate'],
    });
  }
}
