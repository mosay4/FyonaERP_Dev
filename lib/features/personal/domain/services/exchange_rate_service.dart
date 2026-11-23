import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/utils/currency_formatter.dart' as fmt;

/// Service to fetch and cache exchange rates from multiple sources.
class ExchangeRateService {
  static const _cacheKey = 'exchange_rates_cache';
  static const _cacheTimeKey = 'exchange_rates_cache_time';
  static const _cacheDuration = Duration(hours: 24);

  Map<String, double> _rates = {};
  DateTime? _lastFetch;

  Map<String, double> get rates => Map.unmodifiable(_rates);

  /// Fetch all exchange rates (cached for 1 hour).
  Future<Map<String, double>> fetchRates() async {
    // Try cache first
    final cached = await _loadCache();
    if (cached != null) {
      _rates = cached;
      return _rates;
    }

    // Fetch from APIs
    try {
      await _fetchFromExchangerateApi();
    } catch (e) {
      print('ExchangeRate API failed: $e');
    }

    try {
      await _fetchYerRate();
    } catch (e) {
      print('YER rate fetch failed: $e');
    }

    await _saveCache();
    return _rates;
  }

  /// Convert amount from one currency to another.
  double convert(double amount, String from, String to) {
    if (from == to) return amount;
    final fromRate = _rates[from] ?? 1.0;
    final toRate = _rates[to] ?? 1.0;
    // All rates are relative to USD
    return amount * fromRate / toRate;
  }

  /// Get rate for a currency (relative to USD).
  double getRate(String currency) => _rates[currency] ?? 1.0;

  /// Fetch rates from exchangerate-api.com (free tier, USD base).
  Future<void> _fetchFromExchangerateApi() async {
    final url = Uri.parse('https://open.er-api.com/v6/latest/USD');
    final response = await http.get(url).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['result'] == 'success') {
        final ratesMap = data['rates'] as Map<String, dynamic>;
        _rates = ratesMap.map((k, v) => MapEntry(k, (v as num).toDouble()));
        // YER_OLD uses the same rate as YER
        if (_rates.containsKey('YER') && !_rates.containsKey('YER_OLD')) {
          _rates['YER_OLD'] = _rates['YER']!;
        }
        _lastFetch = DateTime.now();
      }
    }
  }

  /// Fetch YER rate from 2dec.net.
  Future<void> _fetchYerRate() async {
    try {
      final url = Uri.parse('https://www.2dec.net/rate.html');
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        // Try to extract YER rate from the page
        // The page may have different formats, try common patterns
        final body = response.body;

        // Look for YER/USD rate patterns
        final yerPatterns = [
          RegExp(r'YER[^0-9]*([0-9]+\.?[0-9]*)', caseSensitive: false),
          RegExp(r'ريال[^0-9]*([0-9]+\.?[0-9]*)', caseSensitive: false),
          RegExp(r' Yemen[^0-9]*([0-9]+\.?[0-9]*)', caseSensitive: false),
        ];

        for (final pattern in yerPatterns) {
          final match = pattern.firstMatch(body);
          if (match != null) {
            final rate = double.tryParse(match.group(1)!);
            if (rate != null && rate > 0) {
              _rates['YER'] = rate;
              _rates['YER_OLD'] = rate;
              _rates['YER_NEW'] = rate;
              _lastFetch = DateTime.now();
              return;
            }
          }
        }
      }
    } catch (_) {
      // Fallback: use approximate rate
      _rates['YER'] = 250.0;
      _rates['YER_OLD'] = 250.0;
      _rates['YER_NEW'] = 250.0;
    }
  }

  Future<Map<String, double>?> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timeStr = prefs.getString(_cacheTimeKey);
      if (timeStr == null) return null;

      final cacheTime = DateTime.tryParse(timeStr);
      if (cacheTime == null) return null;

      if (DateTime.now().difference(cacheTime) > _cacheDuration) return null;

      final ratesJson = prefs.getString(_cacheKey);
      if (ratesJson == null) return null;

      final ratesMap = json.decode(ratesJson) as Map<String, dynamic>;
      _lastFetch = cacheTime;
      return ratesMap.map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, json.encode(_rates));
      await prefs.setString(_cacheTimeKey, (_lastFetch ?? DateTime.now()).toIso8601String());
    } catch (_) {}
  }

  /// Get supported currencies with their Arabic names.
  static const supportedCurrencies = {
    'SAR': 'ريال سعودي',
    'USD': 'دولار أمريكي',
    'YER': 'ريال يمني جديد',
    'YER_OLD': 'ريال يمني قديم',
    'YER_NEW': 'ريال يمني جديد',
    'EUR': 'يورو',
    'GBP': 'جنيه إسترليني',
    'AED': 'درهم إماراتي',
    'EGP': 'جنيه مصري',
    'KWD': 'دينار كويتي',
    'BHD': 'دينار بحريني',
    'QAR': 'ريال قطري',
    'OMR': 'ريال عماني',
    'JOD': 'دينار أردني',
    'LBP': 'ليرة لبنانية',
    'SYP': 'ليرة سورية',
    'IQD': 'دينار عراقي',
  };

  static String currencySymbol(String code) {
    const symbols = {
      'SAR': 'ر.س', 'USD': r'$', 'YER': 'ر.ي', 'YER_OLD': 'ر.ي', 'YER_NEW': 'ر.ي',
      'EUR': '€', 'GBP': '£', 'AED': 'د.إ', 'EGP': 'ج.م',
      'KWD': 'د.ك', 'BHD': 'د.ب', 'QAR': 'ر.ق', 'OMR': 'ر.ع',
      'JOD': 'د.أ', 'LBP': 'ل.ل', 'SYP': 'ل.س', 'IQD': 'د.ع',
    };
    return symbols[code] ?? code;
  }

  /// Display name / symbol following the current app locale.
  /// (The maps above stay as Arabic reference data.)
  static String localizedName(String code) => fmt.currencyName(code);
  static String localizedSymbol(String code) => fmt.currencySymbol(code);
}

/// Singleton instance.
final exchangeRateService = ExchangeRateService();
