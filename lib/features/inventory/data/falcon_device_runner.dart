import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../domain/falcon_device_summary.dart';

/// The phone's per-product Falcon figures (`falconFigures`).
typedef FalconFigures = ({List<Map<String, dynamic>> items, String? category});

/// Above the network-quality caps (they skip requests over 60 s) and above
/// the server's bounded model call, so a slow narrative never ends in
/// «تعذّر تشغيل التحليل» — the server answers with its own report instead.
const Duration kFalconReceiveTimeout = Duration(seconds: 70);

/// Process memory only (never written to disk, gone with the app): the
/// figures read for the instant preview — reused by the analysis right
/// after — and the last reports for unchanged figures, so reopening the
/// Falcon on the same data costs no network and no model call.
class FalconDeviceCache {
  FalconDeviceCache._();
  static final FalconDeviceCache instance = FalconDeviceCache._();

  static const Duration figuresTtl = Duration(seconds: 45);
  static const int maxReports = 16;
  DateTime Function() clock = DateTime.now;

  final Map<String, (DateTime, FalconFigures)> _figures = {};
  final LinkedHashMap<String, Map<String, dynamic>> _reports = LinkedHashMap();

  void putFigures(String key, FalconFigures figures) =>
      _figures[key] = (clock(), figures);

  /// The figures just read for the preview, once.
  FalconFigures? takeFigures(String key) {
    final hit = _figures.remove(key);
    if (hit == null || clock().difference(hit.$1) > figuresTtl) return null;
    return hit.$2;
  }

  Map<String, dynamic>? report(String key) {
    final hit = _reports.remove(key);
    if (hit == null) return null;
    _reports[key] = hit; // most recent last
    return _copy(hit);
  }

  void putReport(String key, Map<String, dynamic> report) {
    _reports.remove(key);
    _reports[key] = _copy(report);
    while (_reports.length > maxReports) {
      _reports.remove(_reports.keys.first);
    }
  }

  void clear() {
    _figures.clear();
    _reports.clear();
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> m) =>
      Map<String, dynamic>.from(jsonDecode(_encode(m)) as Map);
}

String _encode(Object? value) => jsonEncode(value, toEncodable: (o) => '$o');

/// The Falcon for a device-ledger source (one branch or «جميع الفروع»):
/// the figures are read on the phone, the deterministic summary is computed
/// on the phone, and only that compact summary goes to the analysis.
class FalconDeviceRunner {
  FalconDeviceRunner({
    required this.network,
    required this.owner,
    required this.read,
    this.extra = const {},
    FalconDeviceCache? cache,
  }) : cache = cache ?? FalconDeviceCache.instance;

  final ApiClient network;

  /// Identifies the data source (branch bridge / all-branches set).
  final Object owner;
  final Future<FalconFigures> Function(String scope, String? refId, String currency)
  read;
  final Map<String, dynamic> extra;
  final FalconDeviceCache cache;

  String _key(String scope, String? refId, String currency) =>
      '${identityHashCode(owner)}|$scope|${refId ?? ''}|$currency';

  static String _currency(String? c) => (c ?? 'USD').trim().toUpperCase();

  Map<String, dynamic> _summary(
    FalconFigures f,
    String scope,
    String? refId,
    String currency,
  ) => falconDeviceSummary(
    f.items,
    currency: currency,
    scope: scope,
    refId: refId,
    category: f.category,
  );

  /// The key numbers at once (no network): shown while the narrative runs.
  Future<Map<String, dynamic>> preview(
    String scope,
    String? refId, {
    String? reportCurrency,
  }) async {
    final currency = _currency(reportCurrency);
    final figures = await read(scope, refId, currency);
    cache.putFigures(_key(scope, refId, currency), figures);
    return _summary(figures, scope, refId, currency);
  }

  Future<Map<String, dynamic>> analyze(
    String scope,
    String? refId, {
    String? reportCurrency,
  }) async {
    final currency = _currency(reportCurrency);
    final key = _key(scope, refId, currency);
    final figures = cache.takeFigures(key) ?? await read(scope, refId, currency);
    final summary = _summary(figures, scope, refId, currency);
    final reportKey = '$key|${_encode(summary)}';
    final cached = cache.report(reportKey);
    if (cached != null) return cached;
    final report = await _post('/inventory/falcon/analyze', {
      ...extra,
      'scope': scope,
      if (refId != null) 'ref_id': refId,
      'report_currency': currency,
      'device_summary': summary,
      if (figures.category != null) 'device_category': figures.category,
    });
    // Only a full answer is kept: after a model timeout the next open asks
    // again.
    if (report['ai'] == true) cache.putReport(reportKey, report);
    return report;
  }

  Future<Map<String, dynamic>> chat(
    String scope,
    String? refId,
    String question,
    List<Map<String, dynamic>> history, {
    String? reportCurrency,
  }) async {
    final currency = _currency(reportCurrency);
    final figures = await read(scope, refId, currency);
    return _post('/inventory/falcon/chat', {
      ...extra,
      'question': question,
      'history': history,
      'scope': scope,
      if (refId != null) 'ref_id': refId,
      'report_currency': currency,
      'device_items': falconActiveRows(figures.items, scope),
      if (figures.category != null) 'device_category': figures.category,
    });
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await network.post(
      path,
      data: body,
      options: Options(receiveTimeout: kFalconReceiveTimeout),
    );
    final data = r.data;
    final inner = data is Map && data['data'] is Map ? data['data'] : data;
    return inner is Map ? Map<String, dynamic>.from(inner) : <String, dynamic>{};
  }
}
