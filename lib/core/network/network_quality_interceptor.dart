import 'dart:io';

import 'package:dio/dio.dart';

import '../services/network_quality_monitor.dart';

/// Feeds every real request into the [NetworkQualityMonitor] (latency and
/// network-level failures) and, while the link is very poor, shortens the
/// timeouts of requests that start so that nothing waits 15s/30s on a dead
/// link.
///
/// Must be the LAST interceptor: its request timing then starts right
/// before the request leaves the device (after any branch-choice dialog),
/// and it sees gateway errors already mapped to connection errors.
class NetworkQualityInterceptor extends Interceptor {
  NetworkQualityInterceptor(this.monitor, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final NetworkQualityMonitor monitor;
  final DateTime Function() _clock;

  static const _startKey = 'networkQualityStartUs';

  /// Set `extra[skipKey] = true` on a request to keep it out of the stats.
  static const skipKey = 'networkQualitySkip';

  /// Requests whose duration says nothing about the network (uploads,
  /// downloads, long-running AI calls): only connection-level failures count.
  static bool _isLong(RequestOptions o) {
    final receive = o.receiveTimeout;
    return o.data is FormData ||
        o.responseType == ResponseType.bytes ||
        o.responseType == ResponseType.stream ||
        (receive != null && receive > const Duration(seconds: 60));
  }

  static Duration? _min(Duration? current, Duration cap) =>
      current == null || current == Duration.zero || current > cap
          ? cap
          : current;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.extra[skipKey] != true) {
      final caps = monitor.timeoutCaps;
      if (caps != null) {
        options.connectTimeout = _min(options.connectTimeout, caps.connect);
        if (!_isLong(options)) {
          options.receiveTimeout = _min(options.receiveTimeout, caps.receive);
        }
      }
      options.extra[_startKey] = _clock().microsecondsSinceEpoch;
    }
    handler.next(options);
  }

  Duration? _elapsed(RequestOptions o) {
    final start = o.extra.remove(_startKey);
    if (start is! int) return null;
    return Duration(microseconds: _clock().microsecondsSinceEpoch - start);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final o = response.requestOptions;
    final elapsed = _elapsed(o);
    if (elapsed != null) monitor.recordSuccess(_isLong(o) ? null : elapsed);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final o = err.requestOptions;
    final elapsed = _elapsed(o);
    // No start mark: rejected before it left the device (offline guard,
    // branch scope, cancelled dialog) — not a network signal.
    if (elapsed != null) {
      switch (_classify(err, long: _isLong(o))) {
        case _Signal.failure:
          monitor.recordFailure();
        case _Signal.success:
          monitor.recordSuccess(_isLong(o) ? null : elapsed);
        case _Signal.none:
          break;
      }
    }
    handler.next(err);
  }

  static _Signal _classify(DioException err, {bool long = false}) {
    switch (err.type) {
      case DioExceptionType.cancel:
        return _Signal.none;
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.connectionError:
        return _Signal.failure;
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return long ? _Signal.none : _Signal.failure;
      case DioExceptionType.badResponse:
        // The server answered: the network works.
        return _Signal.success;
      case DioExceptionType.unknown:
        final e = err.error;
        return e is SocketException || e is HttpException
            ? _Signal.failure
            : _Signal.none;
      default:
        return _Signal.none;
    }
  }
}

enum _Signal { success, failure, none }
