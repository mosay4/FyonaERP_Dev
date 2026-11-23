import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';

enum SaraAmbientPhase {
  idle, focus, typing, sending, waiting, thinking, responding,
  completed, executing, success, error, cancelling, hidden,
}

enum SaraAmbientActivity { none, waiting, thinking, responding, executing }

@immutable
class SaraAmbientGeometry {
  const SaraAmbientGeometry({this.input, this.avatar, this.user, this.reply});
  final Rect? input, avatar, user, reply;

  static SaraAmbientGeometry lerp(SaraAmbientGeometry a, SaraAmbientGeometry b, double t) =>
      SaraAmbientGeometry(input: _rect(a.input, b.input, t),
        avatar: _rect(a.avatar, b.avatar, t), user: _rect(a.user, b.user, t),
        reply: _rect(a.reply, b.reply, t));

  static Rect? _rect(Rect? a, Rect? b, double t) => b == null ? null : a == null ? b : Rect.lerp(a, b, t);

  @override
  bool operator ==(Object other) => other is SaraAmbientGeometry &&
      input == other.input && avatar == other.avatar && user == other.user && reply == other.reply;
  @override
  int get hashCode => Object.hash(input, avatar, user, reply);
}

/// Presentation only. No network, persistence, audio, financial or agent calls.
/// Time comes from the visible scene's ticker (or a deterministic test clock).
/// Durations settle real gestures/results; they never fabricate an AI result.
class SaraAmbientController extends ChangeNotifier {
  SaraAmbientPhase _phase = SaraAmbientPhase.idle;
  SaraAmbientPhase _from = SaraAmbientPhase.idle;
  Map<SaraAmbientPhase, double> _fromWeights = const {SaraAmbientPhase.idle: 1};
  SaraAmbientActivity _activity = SaraAmbientActivity.none;
  SaraAmbientGeometry _geometry = const SaraAmbientGeometry();
  SaraAmbientGeometry _oldGeometry = const SaraAmbientGeometry();
  final Map<String, ({int generation, double created})> _replies = {};
  // Freshness guard for a reply first built later by scrolling. This clock
  // never schedules a frame, timer, network request or animation.
  final Stopwatch _ageClock = Stopwatch()..start();
  final Set<String> _revealing = {};
  bool _disposed = false, _visible = true, _reduced = false;
  bool _focused = false, _hasRequest = false, _operation = false, _cancelled = false;
  bool _awaitingResponse = false;
  int _characters = 0, _generation = 0, _layoutRevision = 0;
  int _operationSerial = 0;
  int? _operationToken;
  double _time = 0, _phaseAge = 0, _morphAge = .35, _geometryAge = .25;
  double _editAge = 100, _sendAge = 100, _touchAge = 100;
  double _flow = 0;
  double _fluidFlow = 0;
  int _revealWords = 0;
  double _typingTarget = 0, _typingEnergy = 0, _wordEnergy = 0, _contraction = 0;
  double _scroll = 0, _scrollTarget = 0;
  double _focusGlow = 0, _focusAge = 100;
  bool _deleting = false;
  Offset? _touch;
  int _paintCount = 0;

  SaraAmbientPhase get phase => _phase;
  SaraAmbientPhase get fromPhase => _from;
  SaraAmbientActivity get activity => _activity;
  int get generation => _generation;
  int get layoutRevision => _layoutRevision;
  int get paintCount => _paintCount;
  bool get visible => _visible;
  bool get reducedMotion => _reduced;
  bool get operationActive => _operation;
  bool get focused => _focused;
  bool get hasRequest => _hasRequest;
  double get time => _time;
  // Shader clocks are integrated, never multiplied by a changing phase speed.
  double get fluidFlow => _fluidFlow;
  double get sendImpulse => _reduced ? 0 : math.pow(1 - fluidSendProgress, 2).toDouble();
  double get fluidSendProgress => (_sendAge / 2).clamp(0, 1);
  double _weight(SaraAmbientPhase p) => phaseWeights[p] ?? 0;
  double get typingAmp => (_weight(SaraAmbientPhase.typing) * .4 + typingEnergy * .6).clamp(0, 1);
  double get thinkingFocus => (_weight(SaraAmbientPhase.thinking) +
      _weight(SaraAmbientPhase.executing) + _weight(SaraAmbientPhase.waiting) * .4).clamp(0, 1);
  double get respondFlow => _weight(SaraAmbientPhase.responding);
  double get completedBalance => (_weight(SaraAmbientPhase.idle) +
      _weight(SaraAmbientPhase.completed) + _weight(SaraAmbientPhase.success)).clamp(0, 1);
  // Each actual reveal callback advances the swell, with ticker-driven decay.
  // No guessed word cadence, wall clock, or per-word timers.
  double get revealPulse => wordEnergy * (.65 + .35 * math.pow(math.sin(_revealWords * 1.618), 2));
  double get phaseAge => _phaseAge;
  double get morph => _reduced ? 1 : _smooth((_morphAge / (_phase == SaraAmbientPhase.cancelling ? .25 : .32)).clamp(0, 1));
  Map<SaraAmbientPhase, double> get phaseWeights {
    if (_reduced) return {_phase: 1};
    final t = morph;
    final weights = <SaraAmbientPhase, double>{};
    for (final entry in _fromWeights.entries) {
      final weight = entry.value * (1 - t);
      if (weight > .00001) weights[entry.key] = weight;
    }
    weights[_phase] = (weights[_phase] ?? 0) + t;
    return weights;
  }
  double get typingEnergy => _reduced ? 0 : _typingEnergy * _smooth((1 - _editAge / .5).clamp(0, 1));
  double get flowPhase => _reduced ? 0 : _flow;
  double get wordEnergy => _reduced ? 0 : _wordEnergy;
  double get contraction => _reduced ? 0 : _contraction;
  double get parallax => _reduced ? 0 : _scroll;
  double get sendProgress => _reduced ? 1 : (_sendAge / .44).clamp(0, 1);
  double get touchProgress => _reduced ? 1 : (_touchAge / .48).clamp(0, 1);
  Offset? get touchOrigin => _touch;
  double get focusGlow => _reduced ? (_focused ? 1 : 0) : _focusGlow;
  double get focusProgress => (_focusAge / .25).clamp(0, 1);
  bool get canAnimate => !_disposed && _visible && !_reduced && _phase != SaraAmbientPhase.hidden;
  bool get active => !const {SaraAmbientPhase.idle, SaraAmbientPhase.focus}.contains(_phase) ||
      _typingEnergy > .02 || _wordEnergy > .02 || _morphAge < .32 || _geometryAge < .25 || _focusAge < .25;
  SaraAmbientGeometry get geometry => SaraAmbientGeometry.lerp(
      _oldGeometry, _geometry, _reduced ? 1 : _smooth((_geometryAge / .25).clamp(0, 1)));

  static double _smooth(double t) => t * t * (3 - 2 * t);
  double get _now => math.max(_time, _ageClock.elapsedMicroseconds / 1000000);
  void _notify() { if (!_disposed) notifyListeners(); }

  void _set(SaraAmbientPhase next) {
    if (_disposed || next == _phase) return;
    _fromWeights = phaseWeights;
    _from = _phase;
    _phase = next;
    _phaseAge = 0;
    _morphAge = _reduced ? .32 : 0;
    _notify();
  }

  void setGeometry(SaraAmbientGeometry next) {
    if (_disposed || next == _geometry) return;
    _oldGeometry = geometry;
    _geometry = next;
    _geometryAge = _reduced ? .25 : 0;
    _notify();
  }

  void setReducedMotion(bool value) {
    if (_disposed || value == _reduced) return;
    _reduced = value;
    _morphAge = .32;
    _geometryAge = .25;
    _typingEnergy = _wordEnergy = _contraction = 0;
    _sendAge = _touchAge = 100;
    if (value && _transient(_phase)) _set(_base());
    _notify();
  }

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    if (!value) {
      _generation++;
      _replies.clear();
      _revealing.clear();
      _hasRequest = _operation = false;
      _activity = SaraAmbientActivity.none;
      _typingTarget = _typingEnergy = _wordEnergy = 0;
      _focusGlow = _contraction = 0;
      _editAge = _focusAge = 100;
      _sendAge = _touchAge = 100;
      _set(SaraAmbientPhase.hidden);
      // A stopped ticker cannot finish a hidden morph. Commit invisibility
      // now so returning never blends from the previous request's shape.
      _fromWeights = const {SaraAmbientPhase.hidden: 1};
      _morphAge = .32;
    } else {
      _cancelled = false;
      _set(_focused ? SaraAmbientPhase.focus : SaraAmbientPhase.idle);
    }
    _notify();
  }

  void focus(bool value) {
    if (_disposed || value == _focused) return;
    _focused = value;
    if (value) _focusAge = 0;
    _layoutRevision++;
    if (_visible && !_hasRequest && !_transient(_phase)) _set(_base());
    _notify();
  }

  void touchInput() {
    if (_disposed || !_visible) return;
    _focusAge = 0;
    _notify();
  }

  void edit(String text) {
    if (_disposed) return;
    final length = text.runes.length;
    if (length == _characters && length == 0) return;
    _deleting = length < _characters;
    _characters = length;
    _editAge = 0;
    _typingTarget = length == 0 ? 0 : (_typingTarget + (_deleting ? .12 : .22)).clamp(.20, 1);
    _cancelled = false;
    _layoutRevision++;
    if (_visible && !_hasRequest && !_transient(_phase)) {
      _set(length == 0 ? (_focused ? SaraAmbientPhase.focus : SaraAmbientPhase.idle) : SaraAmbientPhase.typing);
    }
    _notify();
  }

  void send() {
    if (_disposed || !_visible) return;
    final keepTouch = _touchAge < .12;
    _generation++;
    _replies.clear();
    _revealing.clear();
    _hasRequest = true;
    _awaitingResponse = true;
    _operation = _cancelled = false;
    _activity = SaraAmbientActivity.none;
    _characters = 0;
    _typingTarget = 0;
    _sendAge = 0;
    _revealWords = 0;
    if (!keepTouch) _touchAge = 100;
    _layoutRevision++;
    _set(_reduced ? SaraAmbientPhase.idle : SaraAmbientPhase.sending);
    _notify();
  }

  void suggestion(Offset point) {
    if (_disposed || !_visible || _reduced) return;
    _touch = point;
    _touchAge = 0;
    _notify();
  }

  void scroll(double pixels) {
    if (_disposed || !_visible) return;
    final x = pixels / 600;
    _scrollTarget = x / (1 + x.abs());
    _layoutRevision++;
    _notify();
  }

  void setActivity(SaraAmbientActivity value) {
    if (_disposed) return;
    if (!_visible || _cancelled || (!_hasRequest && !_operation)) return;
    if (value == SaraAmbientActivity.responding && _revealing.isEmpty) value = SaraAmbientActivity.none;
    if (value == SaraAmbientActivity.executing && !_operation) value = SaraAmbientActivity.thinking;
    if (value == SaraAmbientActivity.thinking && !_awaitingResponse) {
      value = _revealing.isEmpty ? SaraAmbientActivity.waiting : SaraAmbientActivity.responding;
    }
    if (value == _activity) return;
    _activity = value;
    if (_terminal(_phase)) return;
    if (_phase == SaraAmbientPhase.sending && value != SaraAmbientActivity.responding && value != SaraAmbientActivity.executing) return;
    _set(_base());
  }

  void responseReady(int generation) {
    if (_disposed || !_visible || _cancelled || !_hasRequest || generation != _generation) return;
    _awaitingResponse = false;
    if (!_operation && _revealing.isEmpty && !_terminal(_phase)) {
      _activity = SaraAmbientActivity.waiting;
      _set(SaraAmbientPhase.waiting);
    }
  }

  bool registerReply(String id, {int? generation}) {
    if (_disposed || !_visible || _cancelled || !_hasRequest ||
        (generation != null && generation != _generation)) { return false; }
    _replies[id] = (generation: _generation, created: _now);
    if (_replies.length > 64) _replies.remove(_replies.keys.first);
    _layoutRevision++;
    _notify();
    return true;
  }

  void replyStarted(String id, {bool visible = true}) {
    if (!_acceptReply(id)) return;
    if (!visible || _now - _replies[id]!.created > 3) {
      _replies.remove(id);
      return;
    }
    _revealing.add(id);
    _hasRequest = true;
    _layoutRevision++;
    if (!_operation && !_terminal(_phase)) _set(SaraAmbientPhase.responding);
    _notify();
  }

  void word(String id) {
    if (!_acceptReply(id) || !_revealing.contains(id)) return;
    _revealWords++;
    _wordEnergy = (_wordEnergy + .16).clamp(0, 1);
    _layoutRevision++;
    _notify();
  }

  void replyFinished(String id, {bool visible = true}) {
    if (!_acceptReply(id) || !_revealing.remove(id)) return;
    _replies.remove(id);
    _layoutRevision++;
    if (_revealing.isEmpty && !_operation && !_terminal(_phase)) {
      _activity = SaraAmbientActivity.none;
      _set(_reduced || !visible ? _base() : SaraAmbientPhase.completed);
    }
    _notify();
  }

  bool _acceptReply(String id) => !_disposed && _visible && !_cancelled && _replies[id]?.generation == _generation;

  int? beginOperation() {
    if (_disposed || !_visible) return null;
    _operationToken = ++_operationSerial;
    _hasRequest = _operation = true;
    _awaitingResponse = false;
    _cancelled = false;
    _activity = SaraAmbientActivity.executing;
    _set(SaraAmbientPhase.executing);
    return _operationToken;
  }

  void finishOperation({required bool confirmed, bool failed = false, int? token}) {
    if (_disposed || !_visible || !_operation || _cancelled) return;
    if (token != null && token != _operationToken) return;
    _operation = false;
    _operationToken = null;
    _activity = SaraAmbientActivity.none;
    if (failed) { error(); }
    else if (confirmed) { _set(_reduced ? _base() : SaraAmbientPhase.success); }
    else { _hasRequest = false; _set(_base()); }
  }

  void error({int? generation}) {
    if (_disposed || !_visible || _cancelled) return;
    if (generation != null && (generation != _generation || !_hasRequest)) return;
    _activity = SaraAmbientActivity.none;
    _operation = false;
    _hasRequest = false;
    _cancelled = true;
    _typingTarget = 0;
    _focusAge = 100;
    _replies.clear();
    _revealing.clear();
    _sendAge = _touchAge = 100;
    _set(_reduced ? _base() : SaraAmbientPhase.error);
  }

  void cancel() {
    if (_disposed) return;
    _generation++;
    _replies.clear();
    _revealing.clear();
    _cancelled = true;
    _hasRequest = _operation = false;
    _activity = SaraAmbientActivity.none;
    _typingTarget = 0;
    _focusAge = 100;
    _sendAge = _touchAge = 100;
    _set(!_visible ? SaraAmbientPhase.hidden : _reduced ? _base() : SaraAmbientPhase.cancelling);
  }

  SaraAmbientPhase _base() {
    if (!_visible) return SaraAmbientPhase.hidden;
    if (_operation) return SaraAmbientPhase.executing;
    if (_hasRequest && !_cancelled) {
      switch (_activity) {
        case SaraAmbientActivity.executing: return SaraAmbientPhase.executing;
        case SaraAmbientActivity.responding: return _revealing.isEmpty ? SaraAmbientPhase.idle : SaraAmbientPhase.responding;
        case SaraAmbientActivity.thinking: return SaraAmbientPhase.thinking;
        case SaraAmbientActivity.waiting: return SaraAmbientPhase.waiting;
        case SaraAmbientActivity.none: break;
      }
    }
    if (!_cancelled && _characters > 0 && _editAge < .5) return SaraAmbientPhase.typing;
    return _focused ? SaraAmbientPhase.focus : SaraAmbientPhase.idle;
  }

  static bool _terminal(SaraAmbientPhase p) => const {SaraAmbientPhase.completed, SaraAmbientPhase.success,
      SaraAmbientPhase.error, SaraAmbientPhase.cancelling}.contains(p);
  static bool _transient(SaraAmbientPhase p) => _terminal(p) || p == SaraAmbientPhase.sending;

  /// Advance physical time; caller repaints at most once per vsync. No timers.
  void advance(Duration delta) {
    if (!canAnimate) return;
    final dt = math.max(0.0, delta.inMicroseconds / 1000000);
    _time += dt;
    _phaseAge += dt;
    _morphAge += dt;
    _geometryAge += dt;
    _editAge += dt;
    _sendAge += dt;
    _touchAge += dt;
    _focusAge += dt;
    final focusTarget = _focused && _phase != SaraAmbientPhase.cancelling ? 1.0 : 0.0;
    _focusGlow += (focusTarget - _focusGlow) * (1 - math.exp(-dt / .07));
    if (_editAge >= .5) _typingTarget = 0;
    final settle = 1 - math.exp(-dt / .14);
    _typingEnergy += (_typingTarget - _typingEnergy) * settle;
    _wordEnergy *= math.exp(-dt / .28);
    _contraction += ((_deleting && _editAge < .5 ? -1.0 : 0.0) - _contraction) * settle;
    _scroll += (_scrollTarget - _scroll) * (1 - math.exp(-dt / .12));
    _flow += dt * (.12 + typingEnergy * .10 + wordEnergy * .12);
    _fluidFlow += dt * (.035 + typingAmp * .075 + respondFlow * .025);
    if (_phase == SaraAmbientPhase.sending && _phaseAge >= .44) {
      if (_hasRequest && _activity == SaraAmbientActivity.thinking) { _set(SaraAmbientPhase.waiting); }
      else { _set(_base()); }
    } else if (_phase == SaraAmbientPhase.waiting && _phaseAge >= .25 && _activity == SaraAmbientActivity.thinking) {
      _set(SaraAmbientPhase.thinking);
    } else if (_phase == SaraAmbientPhase.typing && _editAge >= .5) {
      _set(_base());
    } else if (_terminal(_phase)) {
      final end = _phase == SaraAmbientPhase.cancelling ? .25 : _phase == SaraAmbientPhase.error ? .30 : .50;
      if (_phaseAge >= end) {
        if (_activity == SaraAmbientActivity.none) _hasRequest = false;
        _set(_base());
      }
    }
  }

  void paintFrame() {
    if (_disposed) return;
    _paintCount++;
    _notify();
  }

  @override
  void dispose() { _disposed = true; _ageClock.stop(); _replies.clear(); _revealing.clear(); super.dispose(); }
}
