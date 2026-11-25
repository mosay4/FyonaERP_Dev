import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/network_quality_interceptor.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/network_quality_monitor.dart';
import 'package:fyona_flutter/features/subscription/domain/personal_offline_access.dart';

/// Manual clock + timers: tests move time explicitly.
class _FakeTime {
  DateTime now = DateTime(2026, 1, 1, 12);
  final List<_FakeTimer> timers = [];

  Timer create(Duration delay, void Function() cb) {
    final t = _FakeTimer(now.add(delay), cb);
    timers.add(t);
    return t;
  }

  /// Advances time, firing due timers in order.
  Future<void> advance(Duration d) async {
    final end = now.add(d);
    while (true) {
      final due = timers.where((t) => t.active && !t.at.isAfter(end)).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      if (t.at.isAfter(now)) now = t.at;
      t.active = false;
      t.cb();
      await _flush();
    }
    now = end;
    await _flush();
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this.cb);
  final DateTime at;
  final void Function() cb;
  bool active = true;
  @override
  void cancel() => active = false;
  @override
  bool get isActive => active;
  @override
  int get tick => 0;
}

/// Probe answering with a configurable latency (null = failure).
class _FakeProbe {
  Duration? next = const Duration(milliseconds: 200);
  Duration? Function(int call)? sequence;
  int calls = 0;
  Future<Duration?> call() async {
    calls++;
    return sequence != null ? sequence!(calls) : next;
  }
}

ErrorInterceptorHandler _errHandler() {
  final h = ErrorInterceptorHandler();
  // ignore: invalid_use_of_protected_member
  h.future.ignore();
  return h;
}

void main() {
  late _FakeTime time;
  late _FakeProbe probe;
  late NetworkQualityMonitor monitor;
  late ConnectivityService service;
  late List<bool> reported;

  setUp(() {
    time = _FakeTime();
    probe = _FakeProbe();
    monitor = NetworkQualityMonitor(
      probe: probe.call,
      clock: () => time.now,
      timerFactory: time.create,
    );
    service = ConnectivityService(debugOnline: true, quality: monitor);
    reported = [];
    service.onConnectivityChanged.listen(reported.add);
  });

  tearDown(() => service.dispose());

  Future<void> fail(int n) async {
    for (var i = 0; i < n; i++) {
      monitor.recordFailure();
      time.now = time.now.add(const Duration(seconds: 1));
      await _flush();
    }
  }

  Future<void> goPoor() async {
    probe.next = null;
    await fail(3);
    expect(monitor.isPoor, isTrue);
  }

  test('a slightly weak network stays online', () async {
    // Slow (1.5–3.5s) answers and an occasional failure.
    for (var i = 0; i < 12; i++) {
      monitor.recordSuccess(Duration(milliseconds: 1500 + (i % 3) * 1000));
      if (i % 4 == 0) monitor.recordFailure();
      time.now = time.now.add(const Duration(seconds: 2));
      await _flush();
    }
    expect(monitor.quality, NetworkQuality.weak);
    expect(service.isOnline, isTrue);
    expect(reported, isEmpty);
    expect(probe.calls, 0, reason: 'no probe while the link is merely weak');
  });

  test('repeated failures confirmed by a failing probe go offline', () async {
    probe.next = null;
    await fail(2);
    expect(service.isOnline, isTrue, reason: 'two failures are not enough');
    await fail(1);
    expect(probe.calls, 1);
    expect(monitor.isPoor, isTrue);
    expect(service.isOnline, isFalse);
    expect(service.isNetworkPoor, isTrue);
    expect(reported, [false]);
  });

  test('a very slow median confirmed by a slow probe goes offline', () async {
    probe.next = const Duration(seconds: 5);
    for (var i = 0; i < 4; i++) {
      monitor.recordSuccess(const Duration(seconds: 7));
      time.now = time.now.add(const Duration(seconds: 3));
      await _flush();
    }
    expect(monitor.isPoor, isTrue);
    expect(service.isOnline, isFalse);
  });

  test('failures with a fast probe (slow endpoint) stay online', () async {
    probe.next = const Duration(milliseconds: 300);
    await fail(3);
    expect(probe.calls, 1);
    expect(monitor.isPoor, isFalse);
    expect(service.isOnline, isTrue);
    // Further failures right away do not cause a probe storm.
    await fail(3);
    expect(probe.calls, 1);
  });

  test('recovers after sustained good probes, with back-off while poor',
      () async {
    await goPoor();
    expect(probe.calls, 1);
    // Back-off: 5s, 10s, 20s, 30s, 30s… while still bad.
    await time.advance(const Duration(seconds: 5));
    expect(probe.calls, 2);
    await time.advance(const Duration(seconds: 9));
    expect(probe.calls, 2);
    await time.advance(const Duration(seconds: 1));
    expect(probe.calls, 3);
    await time.advance(const Duration(seconds: 20));
    expect(probe.calls, 4);
    await time.advance(const Duration(seconds: 30));
    expect(probe.calls, 5);
    await time.advance(const Duration(seconds: 30));
    expect(probe.calls, 6);
    expect(service.isOnline, isFalse);

    // Network comes back: one good probe is not enough…
    probe.next = const Duration(milliseconds: 400);
    await time.advance(const Duration(seconds: 30));
    expect(probe.calls, 7);
    expect(service.isOnline, isFalse);
    // …the confirming probe 3s later brings the app back online.
    await time.advance(const Duration(seconds: 3));
    expect(probe.calls, 8);
    expect(service.isOnline, isTrue);
    expect(monitor.quality, NetworkQuality.good);
    expect(reported, [false, true]);
    // No probes once healthy.
    await time.advance(const Duration(minutes: 5));
    expect(probe.calls, 8);
  });

  test('does not flap: an intermittent good probe does not recover',
      () async {
    await goPoor();
    // Every other probe succeeds: never two good probes in a row.
    probe.sequence =
        (n) => n.isEven ? const Duration(milliseconds: 300) : null;
    await time.advance(const Duration(minutes: 5));
    expect(probe.calls, greaterThan(8));
    expect(service.isOnline, isFalse);
    expect(reported, [false]);
  });

  test('probes between the good and bad thresholds do not recover',
      () async {
    await goPoor();
    probe.next = const Duration(seconds: 3); // > 2.5s good threshold
    await time.advance(const Duration(minutes: 3));
    expect(service.isOnline, isFalse);
  });

  test('re-entering poor soon after recovery needs more good probes',
      () async {
    await goPoor();
    probe.next = const Duration(milliseconds: 300);
    await time.advance(const Duration(seconds: 8));
    expect(service.isOnline, isTrue);
    await goPoor(); // within the flap window
    expect(monitor.requiredGoodProbes, 3);
    probe.next = const Duration(milliseconds: 300);
    await time.advance(const Duration(seconds: 5));
    await time.advance(const Duration(seconds: 3));
    expect(service.isOnline, isFalse);
    await time.advance(const Duration(seconds: 3));
    expect(service.isOnline, isTrue);
    expect(reported, [false, true, false, true]);
  });

  test('a fast real response while poor pulls the next probe forward',
      () async {
    await goPoor();
    final before = probe.calls;
    probe.next = const Duration(milliseconds: 200);
    monitor.recordSuccess(const Duration(milliseconds: 300));
    await time.advance(Duration.zero);
    expect(probe.calls, before + 1);
  });

  test('user retry probes once and recovers immediately', () async {
    await goPoor();
    probe.next = const Duration(milliseconds: 200);
    expect(await service.recheck(), isTrue);
    expect(service.isOnline, isTrue);
  });

  test('platform change resets the verdict', () async {
    await goPoor();
    service.debugSetOnline(true);
    expect(service.isOnline, isTrue);
    expect(monitor.quality, NetworkQuality.good);
  });

  test('requests started while poor get short timeouts', () {
    final interceptor = NetworkQualityInterceptor(monitor);
    RequestOptions run() {
      final options = RequestOptions(
        path: '/x',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      );
      interceptor.onRequest(options, RequestInterceptorHandler());
      return options;
    }

    final normal = run();
    expect(normal.connectTimeout, const Duration(seconds: 15));
    expect(normal.receiveTimeout, const Duration(seconds: 30));
  });

  test('poor state caps connect/receive timeouts of new requests', () async {
    await goPoor();
    final interceptor = NetworkQualityInterceptor(monitor);
    final options = RequestOptions(
      path: '/x',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    );
    interceptor.onRequest(options, RequestInterceptorHandler());
    expect(options.connectTimeout, const Duration(seconds: 4));
    expect(options.receiveTimeout, const Duration(seconds: 8));
  });

  test('interceptor feeds timeouts as failures and HTTP errors as success',
      () {
    final interceptor = NetworkQualityInterceptor(
      monitor,
      clock: () => time.now,
    );
    probe.next = null;
    for (var i = 0; i < 3; i++) {
      final o = RequestOptions(path: '/x');
      interceptor.onRequest(o, RequestInterceptorHandler());
      interceptor.onError(
        DioException(requestOptions: o, type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 404)),
        _errHandler(),
      );
    }
    expect(monitor.quality, isNot(NetworkQuality.poor));
    expect(probe.calls, 0);
    for (var i = 0; i < 3; i++) {
      final o = RequestOptions(path: '/x');
      interceptor.onRequest(o, RequestInterceptorHandler());
      interceptor.onError(
        DioException(
            requestOptions: o, type: DioExceptionType.connectionTimeout),
        _errHandler(),
      );
    }
    expect(probe.calls, 1);
  });

  test('requests rejected before leaving the device are ignored', () {
    final interceptor = NetworkQualityInterceptor(monitor);
    for (var i = 0; i < 5; i++) {
      interceptor.onError(
        DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: DioExceptionType.connectionError),
        _errHandler(),
      );
    }
    expect(probe.calls, 0);
    expect(monitor.quality, NetworkQuality.good);
  });

  test('navigation in a poor state reads the device, never the network',
      () async {
    await goPoor();
    var liveCalls = 0;
    final hanging = Completer<Map<String, dynamic>>(); // never completes
    final entry = await resolvePersonalEntry(
      connected: service.isOnline,
      live: () {
        liveCalls++;
        return hanging.future;
      },
      local: () async => {'status': 'active'},
    ).timeout(const Duration(milliseconds: 200));
    expect(entry, {'status': 'active'});
    expect(liveCalls, 0);
  });

  test('a disabled monitor (platform offline / not initialised) is inert',
      () async {
    final idle = NetworkQualityMonitor(
      probe: probe.call,
      clock: () => time.now,
      timerFactory: time.create,
    );
    for (var i = 0; i < 10; i++) {
      idle.recordFailure();
    }
    await _flush();
    expect(idle.quality, NetworkQuality.good);
    expect(probe.calls, 0);
    idle.dispose();
  });
}
