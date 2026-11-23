import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../di/providers.dart';
import '../../network/api_client.dart';
import '../connectivity_service.dart';
import 'public_exchange_rates.dart';

class RateFreshness {
  static const fresh = 'fresh';
  static const stale = 'stale';
  static const expired = 'expired';
  static const unavailable = 'unavailable';
}

class MissingExchangeRate implements Exception {
  const MissingExchangeRate(this.from, this.to);
  final String from, to;
  @override
  String toString() => 'Missing approved exchange rate: $from → $to';
}

class CurrencyEngine {
  CurrencyEngine({
    ApiClient? apiClient,
    void Function()? onChanged,
    PublicExchangeRates? public,
  }) : _apiClient = apiClient,
       _onChanged = onChanged,
       _public = public;
  final ApiClient? _apiClient;
  /// The device fetches world rates itself (free public sources, first that
  /// answers); the FYONA server is only a fallback.
  final PublicExchangeRates? _public;
  final void Function()? _onChanged;
  static const _cacheKey = 'currency_engine_cache';
  static const _cacheTimeKey = 'currency_engine_cache_time';
  Map<String, double> _globalRates = {'USD': 1};
  Map<String, dynamic> _yemenSanaa = {}, _yemenAden = {}, _meta = {};
  DateTime? _fetchedAt, _lastUpdated, _checkedAt;
  String _globalSource = 'unavailable', _yemenSource = 'unavailable';
  bool _cacheLoaded = false;
  bool _lastCheckFailed = false;
  bool get needsReconnectRetry => _lastCheckFailed;
  Future<void>? _loading, _fetching;

  DateTime? get lastUpdated => _lastUpdated;
  DateTime? get fetchedAt => _fetchedAt;
  String get globalSource => _globalSource;
  String get yemenSource => _yemenSource;
  Map<String, double> get globalRates => Map.unmodifiable(_globalRates);
  Map<String, dynamic> get yemenSanaa => Map.unmodifiable(_yemenSanaa);
  Map<String, dynamic> get yemenAden => Map.unmodifiable(_yemenAden);
  Map<String, dynamic> get meta => Map.unmodifiable(_meta);
  String get freshness {
    if (_fetchedAt == null) return RateFreshness.unavailable;
    final age = DateTime.now().difference(_fetchedAt!).inHours;
    if (age < 24) return RateFreshness.fresh;
    if (age < 48) return RateFreshness.stale;
    return RateFreshness.expired;
  }

  Future<void> load({bool forceRefresh = false}) async {
    final existing = _loading;
    if (existing != null) await existing;
    if (!_cacheLoaded) {
      final future = _loadOnce();
      _loading = future;
      try {
        await future;
      } finally {
        if (identical(_loading, future)) _loading = null;
      }
    }
    if (forceRefresh) await _fetch(force: true);
  }

  Future<void> _loadOnce() async {
    await _restore();
    _cacheLoaded = true;
    if (_globalRates.length <= 1 && _yemenSanaa.isEmpty && _yemenAden.isEmpty) {
      await _fetch(force: false);
    }
  }

  Future<void> refreshIfStale({Duration? maxAge, bool refreshSources = true}) async {
    await load();
    final max = maxAge ?? const Duration(hours: 1);
    if (_checkedAt != null &&
        max > Duration.zero &&
        DateTime.now().difference(_checkedAt!) < max)
      return;
    await _fetch(force: refreshSources);
  }

  Future<void> _fetch({required bool force}) async {
    if (_apiClient == null && _public == null) return;
    if (_fetching != null) return _fetching!;
    final future = _fetchSnapshot(force);
    _fetching = future;
    try {
      await future;
    } finally {
      if (identical(_fetching, future)) _fetching = null;
    }
  }

  String _fingerprint() => jsonEncode({
    'global': _globalRates,
    'sanaa': _yemenSanaa,
    'aden': _yemenAden,
    'observations': _meta['observations'],
  });

  static double? _rate(dynamic value) {
    final result = value is num ? value.toDouble() : double.tryParse('$value');
    return result != null && result.isFinite && result > 0 ? result : null;
  }

  void _mergeCity(Map<String, dynamic> city, dynamic raw) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      if (entry.value is! Map) continue;
      final datum = entry.value as Map;
      final avg = _rate(datum['average']);
      if (avg == null) continue;
      city['${entry.key}'.toUpperCase()] = {
        'buy': _rate(datum['buy']) ?? avg,
        'sell': _rate(datum['sell']) ?? avg,
        'average': avg,
      };
    }
  }

  Future<void> _fetchSnapshot(bool force) async {
    try {
      Object? data = await _public?.fetch();
      if (data == null && _apiClient != null) {
        final response = await _apiClient.get(
          '/personal/exchange-rates',
          queryParameters: {'force_refresh': force},
        );
        final body = response.data;
        data = body is Map && body['data'] is Map ? body['data'] as Map : body;
      }
      if (data is! Map) {
        _lastCheckFailed = true;
        return;
      }
      final before = _fingerprint();
      final metadata = data['meta'] is Map
          ? Map<String, dynamic>.from(data['meta'])
          : <String, dynamic>{};
      final source = '${metadata['global_source'] ?? 'backend'}';
      if (!const {
            'fallback',
            'hardcoded',
            'unavailable',
            'unknown',
          }.contains(source) &&
          data['global'] is Map) {
        for (final entry in (data['global'] as Map).entries) {
          final code = '${entry.key}'.trim().toUpperCase();
          final value = _rate(entry.value);
          if (value != null && !code.startsWith('YER'))
            _globalRates[code] = value;
        }
        _globalSource = source;
      }
      _globalRates['USD'] = 1;
      final yemen = data['yemen'] is Map ? data['yemen'] as Map : const {};
      final yerSource = '${yemen['source'] ?? 'unavailable'}';
      if (!const {
        'fallback',
        'hardcoded',
        'unavailable',
        'unknown',
      }.contains(yerSource)) {
        _mergeCity(_yemenSanaa, yemen['sanaa']);
        _mergeCity(_yemenAden, yemen['aden']);
        _yemenSource = yerSource;
        _lastUpdated =
            DateTime.tryParse('${yemen['last_updated'] ?? ''}') ?? _lastUpdated;
      }
      final previousObservations = _meta['observations'] is Map
          ? _meta['observations'] as Map
          : const {};
      final observations = metadata['observations'] is Map
          ? metadata['observations'] as Map
          : const {};
      _meta = {
        ..._meta,
        ...metadata,
        'observations': {...previousObservations, ...observations},
      };
      _fetchedAt =
          DateTime.tryParse('${metadata['fetched_at'] ?? ''}') ?? _fetchedAt;
      _checkedAt = DateTime.now();
      _lastCheckFailed = _globalRates.length <= 1 ||
          _cityRate(_yemenSanaa,'USD') == null ||
          _cityRate(_yemenAden,'USD') == null;
      if (_globalRates.length > 1 ||
          _yemenSanaa.isNotEmpty ||
          _yemenAden.isNotEmpty) {
        if (before != _fingerprint()) await _save();
      }
      if (before != _fingerprint()) _onChanged?.call();
    } catch (_) {
      _lastCheckFailed = true;
      // A failed refresh never clears a previously approved observation.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'version': 2,
          'approved': true,
          'global_rates': _globalRates,
          'yemen_sanaa': _yemenSanaa,
          'yemen_aden': _yemenAden,
          'global_source': _globalSource,
          'source': _yemenSource,
          'fetched_at': _fetchedAt?.toIso8601String(),
          'last_updated': _lastUpdated?.toIso8601String(),
          'meta': _meta,
        }),
      );
      await prefs.setString(_cacheTimeKey, DateTime.now().toIso8601String());
    } catch (_) {}
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(_cacheKey);
      if (text == null) return;
      final data = jsonDecode(text);
      if (data is! Map || data['approved'] != true || data['version'] != 2)
        return;
      if (data['global_rates'] is Map) {
        for (final entry in (data['global_rates'] as Map).entries) {
          final value = _rate(entry.value);
          if (value != null) _globalRates['${entry.key}'] = value;
        }
      }
      _mergeCity(_yemenSanaa, data['yemen_sanaa']);
      _mergeCity(_yemenAden, data['yemen_aden']);
      _globalSource = '${data['global_source'] ?? 'cached'}';
      _yemenSource = '${data['source'] ?? 'cached'}';
      _fetchedAt = DateTime.tryParse('${data['fetched_at'] ?? ''}');
      _lastUpdated = DateTime.tryParse('${data['last_updated'] ?? ''}');
      if (data['meta'] is Map) _meta = Map<String, dynamic>.from(data['meta']);
    } catch (_) {}
  }

  double? _yerUsd(Map<String, dynamic> city) => _cityRate(city, 'USD');
  double? _cityRate(Map<String, dynamic> city, String code) =>
      city[code] is Map ? _rate((city[code] as Map)['average']) : null;

  double? getRate(String from, String to) {
    from = from.trim().toUpperCase();
    to = to.trim().toUpperCase();
    if (from == 'YER') from = 'YER_NEW';
    if (to == 'YER') to = 'YER_NEW';
    if (from == to) return 1;
    final fromCity = from == 'YER_OLD'
        ? _yemenSanaa
        : from == 'YER_NEW'
        ? _yemenAden
        : null;
    final toCity = to == 'YER_OLD'
        ? _yemenSanaa
        : to == 'YER_NEW'
        ? _yemenAden
        : null;
    if (fromCity != null && toCity != null) {
      final a = _yerUsd(fromCity), b = _yerUsd(toCity);
      return a != null && b != null ? b / a : null;
    }
    if (fromCity != null) {
      if (to == 'USD' || to == 'SAR') {
        final direct = _cityRate(fromCity, to);
        if (direct != null) return 1 / direct;
      }
      final base = _yerUsd(fromCity), target = _globalRates[to];
      return base != null && target != null ? target / base : null;
    }
    if (toCity != null) {
      if (from == 'USD' || from == 'SAR') {
        final direct = _cityRate(toCity, from);
        if (direct != null) return direct;
      }
      final base = _yerUsd(toCity), source = _globalRates[from];
      return base != null && source != null ? base / source : null;
    }
    final source = _globalRates[from], target = _globalRates[to];
    return source != null && target != null ? target / source : null;
  }

  double? convertSafe(double amount, String from, String to) {
    final rate = getRate(from, to);
    return rate == null ? null : amount * rate;
  }

  double convert(double amount, String from, String to) =>
      convertSafe(amount, from, to) ?? 0;
  double sumConverted(List<(double, String)> amounts, String targetCurrency) {
    var total = 0.0;
    for (final (amount, currency) in amounts) {
      if (amount == 0) continue;
      final converted = convertSafe(amount, currency, targetCurrency);
      if (converted == null)
        throw MissingExchangeRate(currency, targetCurrency);
      total += converted;
    }
    return total;
  }

  List<String> get availableCurrencies => <String>{
    ..._globalRates.keys,
    if (_yemenSanaa.isNotEmpty) 'YER_OLD',
    if (_yemenAden.isNotEmpty) 'YER_NEW',
  }.toList()..sort();

  static const currencyNames = <String, String>{
    'USD': 'دولار أمريكي',
    'SAR': 'ريال سعودي',
    'EUR': 'يورو',
    'AED': 'درهم إماراتي',
    'EGP': 'جنيه مصري',
    'KWD': 'دينار كويتي',
    'BHD': 'دينار بحريني',
    'QAR': 'ريال قطري',
    'OMR': 'ريال عماني',
    'JOD': 'دينار أردني',
    'GBP': 'جنيه إسترليني',
    'CAD': 'دولار كندي',
    'AUD': 'دولار أسترالي',
    'CHF': 'فرنك سويسري',
    'CNY': 'يوان صيني',
    'INR': 'روبية هندية',
    'TRY': 'ليرة تركية',
    'YER_OLD': 'ريال يمني قديم',
    'YER_NEW': 'ريال يمني جديد',
    'IQD': 'دينار عراقي',
    'SYP': 'ليرة سورية',
    'PKR': 'روبية باكستانية',
    'PHP': 'بيزو فلبيني',
    'JPY': 'ين ياباني',
    'KRW': 'وان كوري',
    'THB': 'بات تايلندي',
    'MYR': 'رينغيت ماليزي',
    'IDR': 'روبية إندونيسية',
    'VND': 'دونغ فيتنامي',
    'BRL': 'ريال برازيلي',
    'MXN': 'بيزو مكسيكي',
    'RUB': 'روبل روسي',
    'ZAR': 'راند جنوب أفريقي',
    'NGN': 'نيرة نيجيرية',
    'DZD': 'دينار جزائري',
    'LYD': 'دينار ليبي',
    'MAD': 'درهم مغربي',
    'TND': 'دينار تونسي',
    'ETB': 'بير إثيوبي',
    'KES': 'شيلينغ كيني',
    'GHS': 'سيدي غاني',
    'DJF': 'فرنك جيبوتي',
  };
}

final rateSnapshotRevisionProvider = StateProvider<int>((ref) => 0);

final currencyEngineProvider = Provider<CurrencyEngine>((ref) {
  ref.watch(dioProvider);
  final connectivity = ref.watch(connectivityServiceProvider);
  var alive = true;
  final engine = CurrencyEngine(
    apiClient: ref.read(apiClientProvider),
    public: PublicExchangeRates(),
    onChanged: () {
      if (alive) ref.read(rateSnapshotRevisionProvider.notifier).state++;
    },
  );
  var wasOnline = connectivity.isOnline;
  final subscription = connectivity.onConnectivityChanged.listen((online) {
    final reconnected = online && !wasOnline;
    wasOnline = online;
    if (reconnected) unawaited(engine.refreshIfStale(maxAge: Duration.zero));
  });
  final timer = Timer.periodic(const Duration(minutes: 1), (_) {
    if (connectivity.isOnline)
      unawaited(
        engine.refreshIfStale(
          // World rates move slowly: the device asks the public sources at
          // most every 30 minutes while online, and at every app start and
          // reconnect. Offline, the last saved table keeps working.
          maxAge: const Duration(minutes: 30),
          refreshSources: false,
        ),
      );
  });
  unawaited(() async {
    try {
      await connectivity.init();
    } catch (_) {}
    wasOnline = connectivity.isOnline;
    await engine.load();
    if (alive && connectivity.isOnline)
      await engine.refreshIfStale(maxAge: Duration.zero, refreshSources: false);
  }());
  ref.onDispose(() {
    alive = false;
    subscription.cancel();
    timer.cancel();
  });
  return engine;
});
