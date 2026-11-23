import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/di/providers.dart' show apiClientProvider;
import '../../../core/config/directory_pilot_build.dart';
import '../../../core/network/api_client.dart' show serverBaseUrlProvider;
import '../../../core/services/connectivity_service.dart';
import '../../../shared/providers/current_user_provider.dart';
import '../../core_business/data/local_directory/directory_pilot.dart';
import '../../core_business/data/local_directory/directory_scope.dart';
import '../../core_business/data/local_ledger/business_report_fx.dart';

final businessReportRateRevisionProvider = StateProvider<int>((_) => 0);

final businessReportRatesProvider = Provider<BusinessReportRates?>((ref) {
  var workspace = ref.watch(
    businessLocalLedgerScopeProvider.select(
      (scope) => scope?.workspace.storageId,
    ),
  );
  if (workspace == null &&
      DirectoryPilotBuild.enabled &&
      const bool.fromEnvironment('FYONA_BUSINESS_LEDGER_QA')) {
    // The setup wizard can run before the first branch grant is installed.
    // Warm only public rate observations, never open a ledger here.
    final user = ref.watch(currentUserProvider);
    final server = ref.watch(serverBaseUrlProvider);
    final org = user?.organizationId;
    if (server == DirectoryPilotBuild.baseUrl &&
        org != null &&
        user!.isActive &&
        user.role == 'owner' &&
        isDirectoryId(user.id) &&
        isDirectoryId(org)) {
      workspace = DirectoryWorkspace(
        server: server,
        accountId: user.id,
        organizationId: org,
      ).storageId;
    }
  }
  if (workspace == null) return null;
  final store = BusinessReportRates(
    workspace,
    onChanged: () =>
        ref.read(businessReportRateRevisionProvider.notifier).state++,
  );
  ref.onDispose(store.close);
  return store;
});

/// Keep the approved publication warm at Business setup/entry and while
/// viewing reports. Reads of the ledger never await this provider's network
/// work. The existing Personal exchange screen and cache are not changed.
final businessReportRateWarmupProvider = Provider.autoDispose<void>((ref) {
  final store = ref.watch(businessReportRatesProvider);
  if (store == null) return;
  final connectivity = ref.watch(connectivityServiceProvider);
  var active = true;
  var online = connectivity.isOnline;
  Future<void> refresh() async {
    if (!active || !connectivity.isOnline) return;
    await store.refresh(() async {
      final response = await ref
          .read(apiClientProvider)
          .get(
            '/personal/exchange-rates',
            queryParameters: {'force_refresh': false},
          );
      final body = response.data;
      return body is Map ? body['data'] as Map? : null;
    });
  }

  final subscription = connectivity.onConnectivityChanged.listen((next) {
    final reconnected = next && !online;
    online = next;
    if (reconnected) unawaited(refresh());
  });
  final timer = Timer.periodic(const Duration(minutes: 1), (_) {
    unawaited(refresh());
  });
  unawaited(() async {
    try {
      await connectivity.init();
    } catch (_) {
      // A desktop/test platform may not supply the connectivity plugin.
    }
    online = connectivity.isOnline;
    await refresh();
  }());
  ref.onDispose(() {
    active = false;
    subscription.cancel();
    timer.cancel();
  });
});

final class BusinessReportRates {
  BusinessReportRates(String workspace, {void Function()? onChanged})
    : _key = 'business_report_approved_rates_v1_$workspace',
      _onChanged = onChanged;

  final String _key;
  final void Function()? _onChanged;
  Future<void>? _restoreTask;
  Future<bool>? _refreshTask;
  bool _closed = false;
  List<BusinessFxObservation> _rows = [];
  Map<(String, String), int> _observedThrough = {};
  BusinessReportFx _snapshot = const BusinessReportFx.empty();

  void close() => _closed = true;

  Future<BusinessReportFx> read() async {
    await (_restoreTask ??= _restore());
    final fallback = await _deviceRates();
    if (fallback.isEmpty) return _snapshot;
    // Read-only last resort: a pair this store never received is valued with
    // the rate already saved on this device by the app's exchange screen.
    // The Personal cache itself is never written here.
    final known = {for (final row in _rows) (row.$1, row.$2)};
    final extra = [
      for (final row in fallback)
        if (!known.contains((row.$1, row.$2))) row,
    ];
    return extra.isEmpty ? _snapshot : BusinessReportFx([..._rows, ...extra]);
  }

  static Future<List<BusinessFxObservation>> _deviceRates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString('currency_engine_cache');
      if (text == null) return const [];
      final data = jsonDecode(text);
      if (data is! Map || data['approved'] != true) return const [];
      final rows = <BusinessFxObservation>[];
      final global = data['global_rates'];
      if (global is Map) {
        for (final entry in global.entries) {
          final code = '${entry.key}'.trim().toUpperCase();
          final value = _decimal(entry.value);
          if (value != null &&
              !code.startsWith('YER') &&
              _validPair('USD', code)) {
            rows.add(('USD', code, value, null));
          }
        }
      }
      for (final (key, code) in [
        ('yemen_sanaa', 'YER_OLD'),
        ('yemen_aden', 'YER_NEW'),
      ]) {
        final city = data[key];
        if (city is! Map) continue;
        final usd = _average(city['USD']);
        final sar = _average(city['SAR']);
        if (usd != null) rows.add(('USD', code, usd, null));
        if (sar != null) rows.add(('SAR', code, sar, null));
      }
      return rows;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(prefs.getString(_key) ?? '{}');
      if (decoded is! Map || _closed) return;
      _rows = [
        for (final row in decoded['rows'] as List? ?? const [])
          if (row case [
            final String base,
            final String code,
            final value,
            final at,
          ])
            if (_validPair(base, code) &&
                (value is String && BusinessReportFx.validDecimal(value) ||
                    value == null && base == 'SAR') &&
                (at == null || at is int && at > 0))
              (base, code, value as String?, at as int?),
      ];
      _observedThrough = {
        for (final row in decoded['observed_through'] as List? ?? const [])
          if (row case [final String base, final String code, final int at])
            if (_validPair(base, code) && at > 0) (base, code): at,
      };
      _snapshot = BusinessReportFx(_rows);
    } catch (_) {
      // An absent/unreadable publication must not prevent reading the facts.
    }
  }

  Future<bool> refresh(Future<Map?> Function() fetch, {DateTime? now}) async {
    if (_closed) return false;
    final existing = _refreshTask;
    if (existing != null) {
      await existing;
      return false; // only the caller that published should emit a revision
    }
    final task = _refresh(fetch, now);
    _refreshTask = task;
    try {
      return await task;
    } finally {
      _refreshTask = null;
    }
  }

  Future<bool> _refresh(Future<Map?> Function() fetch, DateTime? now) async {
    try {
      await read();
      if (_closed) return false;
      final data = await fetch();
      if (data == null || _closed) return false;
      final clock = (now ?? DateTime.now()).microsecondsSinceEpoch;
      final rows = [..._rows];
      final watermark = {..._observedThrough};
      var changed = false;
      final meta = data['meta'];
      final observations = meta is Map ? meta['observations'] : null;
      final latest = <(String, String), BusinessFxObservation>{
        for (final row in rows) (row.$1, row.$2): row,
      };

      void add(String base, String code, String? value, int? at) {
        final pair = (base, code);
        if (watermark[pair] case final dated?) {
          if (at == null || at <= dated) return;
        }
        if (at != null) {
          watermark[pair] = at;
          changed = true;
        }
        final previous = latest[pair];
        if (previous != null &&
            previous.$3 == value &&
            (previous.$4 != null || at == null))
          return;
        final row = (base, code, value, at);
        rows.add(row);
        latest[pair] = row;
        changed = true;
      }

      final admin = <(String, String), Map>{
        for (final row
            in (data['admin_rates'] as List? ?? const []).whereType<Map>())
          (
            '${row['base_currency'] ?? 'USD'}'.toUpperCase(),
            '${row['currency_code']}'.toUpperCase(),
          ): row,
      };

      int? observed(String code) {
        if (admin[('USD', code)] case final manual?) {
          return _timestamp(manual['updated_at'], clock);
        }
        final row = observations is Map ? observations[code] : null;
        // An administrator's SAR/YER quote must not date an unrelated
        // USD/YER observation. The endpoint exposes one entry per currency.
        if (row is Map &&
            row['provider'] == 'admin' &&
            admin.containsKey(('SAR', code))) {
          return null;
        }
        return row is Map && _approved(row['source'])
            ? _timestamp(row['observed_at'], clock)
            : null;
      }

      bool acceptable(String code) {
        final row = observations is Map ? observations[code] : null;
        // An unparseable time leaves the approved rate undated; it does not
        // discard the rate.
        return row is! Map || _approved(row['source']);
      }

      final global = data['global'];
      if (meta is Map && _approved(meta['global_source']) && global is Map) {
        for (final entry in global.entries) {
          final code = '${entry.key}'.trim().toUpperCase();
          if (code.startsWith('YER') ||
              !_validPair('USD', code) ||
              !acceptable(code)) {
            continue;
          }
          final value = _decimal(entry.value);
          if (value != null) add('USD', code, value, observed(code));
        }
      }
      final yemen = data['yemen'];
      if (yemen is Map && _approved(yemen['source'])) {
        for (final (city, code) in [
          ('sanaa', 'YER_OLD'),
          ('aden', 'YER_NEW'),
        ]) {
          final book = yemen[city];
          if (book is! Map || !acceptable(code)) continue;
          final seen = watermark[('USD', code)];
          final at = observed(code);
          final usd = _average(book['USD']);
          final sar = _average(book['SAR']);
          if (usd != null &&
              !(admin.containsKey(('USD', code)) && at == null)) {
            add('USD', code, usd, at);
          }
          // The backend publication gives a per-currency timestamp, not
          // a timestamp for this independent pair. Count it as documented
          // only from the moment it was received, never retroactively.
          final manual = admin[('SAR', code)];
          final sarPair = ('SAR', code);
          final priorPair = latest[sarPair];
          final stale = seen != null && (at == null || at < seen);
          if (manual != null && sar != null) {
            final effective = _timestamp(manual['updated_at'], clock);
            if (effective != null) add('SAR', code, sar, effective);
          } else if (!stale &&
              (sar != null || (usd != null && priorPair?.$3 != null)) &&
              (priorPair == null || sar != priorPair.$3)) {
            add('SAR', code, sar, clock);
          }
        }
      }
      if (!changed) return false;
      final prefs = await SharedPreferences.getInstance();
      if (_closed) return false;
      final saved = await prefs.setString(
        _key,
        jsonEncode({
          'rows': [
            for (final (a, b, c, d) in rows) [a, b, c, d],
          ],
          'observed_through': [
            for (final entry in watermark.entries)
              [entry.key.$1, entry.key.$2, entry.value],
          ],
        }),
      );
      if (!saved || _closed) return false;
      _observedThrough = watermark;
      final newValuation = rows.length != _rows.length;
      _rows = rows;
      if (newValuation) {
        _snapshot = BusinessReportFx(rows);
        _onChanged?.call();
      }
      return newValuation;
    } catch (_) {
      return false; // A failed refresh must never discard the last approval.
    }
  }

  static bool _validPair(String base, String code) =>
      (base == 'USD' || base == 'SAR' && code.startsWith('YER_')) &&
      code != base &&
      (code == 'YER_OLD' ||
          code == 'YER_NEW' ||
          code != 'YER' && RegExp(r'^[A-Z]{3}$').hasMatch(code));

  static bool _approved(Object? source) =>
      source is String &&
      source.trim().isNotEmpty &&
      !const {
        'fallback',
        'hardcoded',
        'unknown',
        'unavailable',
        'seed',
      }.contains(source.toLowerCase().trim());

  static String? _decimal(Object? value) {
    final raw = '$value';
    return BusinessReportFx.validDecimal(raw) ? raw : null;
  }

  static String? _average(Object? value) =>
      value is Map ? _decimal(value['average']) : null;

  static int? _timestamp(Object? value, int clock) {
    if (value is! String) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    // The backend stores UTC; a naive ISO string is UTC without its suffix.
    final utc = parsed.isUtc ? parsed : DateTime.tryParse('${value}Z');
    if (utc == null) return null;
    final at = utc.microsecondsSinceEpoch;
    return at > 0 && at <= clock ? at : null;
  }
}
