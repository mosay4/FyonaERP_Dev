import 'dart:async';
import 'dart:math' as math;

/// How usable the current network is for talking to the FYONA server.
///
/// * [good]  — normal.
/// * [weak]  — slow or with occasional failures. The app STAYS online.
/// * [poor]  — the link is connected but practically unusable (repeated
///   timeouts / connection failures, or multi-second round trips confirmed by
///   an active probe). The app reports itself OFFLINE, exactly as if the phone
///   had no network, until probes show a sustained recovery.
enum NetworkQuality { good, weak, poor }

/// Active probe: returns the round-trip time of a tiny request to the
/// server, or `null` when it failed / timed out.
typedef NetworkProbe = Future<Duration?> Function();

/// Schedules [callback] after [delay]; injectable so tests drive time.
typedef QualityTimerFactory = Timer Function(
    Duration delay, void Function() callback);

/// Timeouts applied to requests that START while the network is poor, so
/// nothing waits 15s/30s on a dead link.
class QualityTimeoutCaps {
  final Duration connect;
  final Duration receive;
  const QualityTimeoutCaps({required this.connect, required this.receive});
}

/// Thresholds. Defaults are tuned so that a slightly weak link (1–3s round
/// trips, an occasional failure) stays online, while a link where requests
/// keep timing out or take 6s+ goes offline.
class NetworkQualityConfig {
  /// Passive samples older than this are forgotten.
  final Duration window;
  final int maxSamples;

  /// Consecutive real network failures (timeouts / connection errors) that
  /// make the link *suspect*.
  final int failureStreakSuspect;

  /// Failure ratio over at least [minSamplesForRatio] samples in the window.
  final double failureRatioSuspect;
  final int minSamplesForRatio;

  /// Median request latency (over at least [minLatencySamples]) that makes
  /// the link suspect.
  final Duration slowMedianSuspect;
  final int minLatencySamples;

  /// Median latency at or above this marks the link as merely [weak].
  final Duration weakLatency;

  /// A probe slower than this (or failing) confirms "very poor".
  final Duration probeBadLatency;

  /// A probe at or below this counts as a good (recovery) probe.
  final Duration probeGoodLatency;

  /// Hard cap on one probe.
  final Duration probeTimeout;

  /// Minimum spacing between two "is it really that bad?" probes while
  /// online, so a burst of failures does not trigger a probe storm.
  final Duration suspectProbeSpacing;

  /// Back-off between probes while poor (last value repeats).
  final List<Duration> poorProbeBackoff;

  /// Delay before the confirming probe after a good one.
  final Duration confirmProbeDelay;

  /// Consecutive good probes needed to leave poor.
  final int goodProbesToRecover;

  /// Re-entering poor within this time after recovering counts as a flap
  /// and raises the number of good probes needed next time (max +2).
  final Duration flapWindow;

  final QualityTimeoutCaps poorTimeouts;

  const NetworkQualityConfig({
    this.window = const Duration(seconds: 60),
    this.maxSamples = 20,
    this.failureStreakSuspect = 3,
    this.failureRatioSuspect = 0.6,
    this.minSamplesForRatio = 5,
    this.slowMedianSuspect = const Duration(seconds: 6),
    this.minLatencySamples = 4,
    this.weakLatency = const Duration(milliseconds: 2500),
    this.probeBadLatency = const Duration(seconds: 4),
    this.probeGoodLatency = const Duration(milliseconds: 2500),
    this.probeTimeout = const Duration(seconds: 5),
    this.suspectProbeSpacing = const Duration(seconds: 10),
    this.poorProbeBackoff = const [
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 20),
      Duration(seconds: 30),
    ],
    this.confirmProbeDelay = const Duration(seconds: 3),
    this.goodProbesToRecover = 2,
    this.flapWindow = const Duration(minutes: 2),
    this.poorTimeouts = const QualityTimeoutCaps(
      connect: Duration(seconds: 4),
      receive: Duration(seconds: 8),
    ),
  });
}

class _Sample {
  final DateTime at;
  final bool ok;
  final int? latencyMs;
  const _Sample(this.at, this.ok, this.latencyMs);
}

/// Classifies network quality from passive signals (real app requests) and
/// a cheap active probe used only when needed:
///
/// * online → *suspect* when the passive signals trip (streak / ratio /
///   median latency); one probe then decides: bad → [NetworkQuality.poor],
///   fine → samples cleared and the app stays online (a slow endpoint is not
///   a bad network).
/// * poor → probes with back-off (5s, 10s, 20s, 30s…); it takes
///   [NetworkQualityConfig.goodProbesToRecover] consecutive good probes (more
///   after a recent flap) to go back online. A fast real response while poor
///   only pulls the next probe forward.
class NetworkQualityMonitor {
  NetworkQualityMonitor({
    this.config = const NetworkQualityConfig(),
    NetworkProbe? probe,
    DateTime Function()? clock,
    QualityTimerFactory? timerFactory,
  })  : _probe = probe, // ignore: prefer_initializing_formals
        _clock = clock ?? DateTime.now,
        _timer = timerFactory ?? Timer.new;

  final NetworkQualityConfig config;
  final DateTime Function() _clock;
  final QualityTimerFactory _timer;
  NetworkProbe? _probe;

  final _changes = StreamController<NetworkQuality>.broadcast(sync: true);
  final List<_Sample> _samples = [];
  NetworkQuality _quality = NetworkQuality.good;
  int _failureStreak = 0;
  bool _probing = false;
  DateTime? _lastSuspectProbe;
  DateTime? _lastRecovery;
  int _flaps = 0;
  int _goodProbes = 0;
  int _backoffIndex = 0;
  DateTime? _lastPassiveGood;
  Timer? _probeTimer;
  int _generation = 0;
  bool _disposed = false;

  /// While false every signal is ignored (no platform network, or the
  /// service was never initialised — e.g. in widget tests).
  bool enabled = false;

  NetworkQuality get quality => _quality;
  bool get isPoor => _quality == NetworkQuality.poor;
  Stream<NetworkQuality> get changes => _changes.stream;
  bool get hasProbe => _probe != null;
  set probe(NetworkProbe? value) => _probe = value;

  /// Caps for requests that start now, or null when no cap applies.
  QualityTimeoutCaps? get timeoutCaps =>
      enabled && isPoor ? config.poorTimeouts : null;

  int get requiredGoodProbes =>
      config.goodProbesToRecover + math.min(_flaps, 2);

  /// A real request reached the server (any HTTP status). [latency] is null
  /// when the duration says nothing about the network (uploads, downloads,
  /// long AI calls).
  void recordSuccess([Duration? latency]) {
    if (!_active) return;
    final now = _clock();
    if (isPoor) {
      if (latency != null && latency <= config.probeGoodLatency) {
        if (_probe != null) {
          _pullProbeForward();
        } else {
          _passiveGood(now);
        }
      }
      return;
    }
    _failureStreak = 0;
    _add(_Sample(now, true, latency?.inMilliseconds));
    _evaluate();
  }

  /// A real request failed at the network level (timeout, connection error,
  /// gateway reporting the server unreachable).
  void recordFailure() {
    if (!_active) return;
    if (isPoor) return;
    _failureStreak++;
    _add(_Sample(_clock(), false, null));
    _evaluate();
  }

  /// The platform network changed (Wi-Fi ↔ data, lost, regained): whatever
  /// was learnt about the previous link no longer applies.
  void reset() {
    _generation++;
    _probeTimer?.cancel();
    _probeTimer = null;
    _probing = false;
    _samples.clear();
    _failureStreak = 0;
    _goodProbes = 0;
    _backoffIndex = 0;
    _lastSuspectProbe = null;
    _flaps = 0;
    _set(NetworkQuality.good);
  }

  /// Runs a probe right away (user tapped «retry»). One good probe is
  /// enough here because the user asked explicitly. Returns true when the
  /// link is no longer poor.
  Future<bool> recheck() async {
    if (!_active || !isPoor) return !isPoor;
    final latency = await _runProbe();
    if (_disposed || !isPoor) return !isPoor;
    if (latency != null && latency <= config.probeGoodLatency) {
      _recover();
      return true;
    }
    return false;
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _probeTimer?.cancel();
    _changes.close();
  }

  bool get _active => enabled && !_disposed;

  void _add(_Sample sample) {
    _samples.add(sample);
    _prune(sample.at);
    while (_samples.length > config.maxSamples) {
      _samples.removeAt(0);
    }
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(config.window);
    _samples.removeWhere((s) => s.at.isBefore(cutoff));
  }

  int? _medianLatencyMs() {
    final values = [
      for (final s in _samples)
        if (s.ok && s.latencyMs != null) s.latencyMs!,
    ];
    if (values.length < config.minLatencySamples) return null;
    values.sort();
    final mid = values.length ~/ 2;
    return values.length.isOdd
        ? values[mid]
        : ((values[mid - 1] + values[mid]) / 2).round();
  }

  bool get _suspect {
    if (_failureStreak >= config.failureStreakSuspect) return true;
    if (_samples.length >= config.minSamplesForRatio) {
      final failures = _samples.where((s) => !s.ok).length;
      if (failures / _samples.length >= config.failureRatioSuspect) {
        return true;
      }
    }
    final median = _medianLatencyMs();
    return median != null &&
        median >= config.slowMedianSuspect.inMilliseconds;
  }

  void _evaluate() {
    if (isPoor) return;
    if (_suspect) {
      _confirmSuspect();
    }
    if (isPoor) return;
    final median = _medianLatencyMs();
    final weak = _samples.any((s) => !s.ok) ||
        (median != null && median >= config.weakLatency.inMilliseconds);
    _set(weak ? NetworkQuality.weak : NetworkQuality.good);
  }

  void _confirmSuspect() {
    if (_probing) return;
    final now = _clock();
    final last = _lastSuspectProbe;
    if (last != null && now.difference(last) < config.suspectProbeSpacing) {
      return;
    }
    if (_probe == null) {
      // No probe available: the passive evidence alone decides.
      _enterPoor();
      return;
    }
    _lastSuspectProbe = now;
    final generation = _generation;
    _runProbe().then((latency) {
      if (_disposed || generation != _generation || isPoor) return;
      if (latency == null || latency > config.probeBadLatency) {
        _enterPoor();
      } else {
        // The server answers quickly: a slow endpoint, not a bad network.
        _samples.clear();
        _failureStreak = 0;
        _evaluate();
      }
    });
  }

  Future<Duration?> _runProbe() async {
    final probe = _probe;
    if (probe == null) return null;
    _probing = true;
    try {
      return await probe().timeout(
        config.probeTimeout + const Duration(seconds: 1),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      _probing = false;
    }
  }

  void _enterPoor() {
    final now = _clock();
    final recovered = _lastRecovery;
    _flaps = recovered != null && now.difference(recovered) < config.flapWindow
        ? _flaps + 1
        : 0;
    _samples.clear();
    _failureStreak = 0;
    _goodProbes = 0;
    _backoffIndex = 0;
    _lastPassiveGood = null;
    _set(NetworkQuality.poor);
    _scheduleProbe(config.poorProbeBackoff.first);
  }

  void _recover() {
    _generation++;
    _probeTimer?.cancel();
    _probeTimer = null;
    _samples.clear();
    _failureStreak = 0;
    _goodProbes = 0;
    _backoffIndex = 0;
    _lastRecovery = _clock();
    _lastSuspectProbe = null;
    _set(NetworkQuality.good);
  }

  void _scheduleProbe(Duration delay) {
    _probeTimer?.cancel();
    final generation = _generation;
    _probeTimer = _timer(delay, () {
      _probeTimer = null;
      if (generation == _generation) _poorProbe();
    });
  }

  /// Recovery without a probe: good responses that are spread over time
  /// (a burst of parallel responses counts once).
  void _passiveGood(DateTime now) {
    final last = _lastPassiveGood;
    if (last != null && now.difference(last) < config.confirmProbeDelay) {
      return;
    }
    _lastPassiveGood = now;
    _goodProbes++;
    if (_goodProbes >= requiredGoodProbes) _recover();
  }

  void _pullProbeForward() {
    if (_probing) return;
    _scheduleProbe(Duration.zero);
  }

  Future<void> _poorProbe() async {
    if (!_active || !isPoor || _probing) return;
    final generation = _generation;
    final latency = await _runProbe();
    if (_disposed || generation != _generation || !isPoor) return;
    if (_probe == null) return; // passive signals end this state
    if (latency != null && latency <= config.probeGoodLatency) {
      _goodProbes++;
      if (_goodProbes >= requiredGoodProbes) {
        _recover();
        return;
      }
      _scheduleProbe(config.confirmProbeDelay);
      return;
    }
    _goodProbes = 0;
    _scheduleProbe(_nextBackoff());
  }

  Duration _nextBackoff() {
    final list = config.poorProbeBackoff;
    _backoffIndex = math.min(_backoffIndex + 1, list.length - 1);
    return list[_backoffIndex];
  }

  void _set(NetworkQuality next) {
    if (_quality == next) return;
    _quality = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}
