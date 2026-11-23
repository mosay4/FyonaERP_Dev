import 'dart:async';
import 'package:flutter/foundation.dart';

enum FalconReplyPhase { idle, thinking, handoff, streaming, docking, completed }

/// One response identity for its entire lifetime. Only the visible prefix
/// is observable by the bubble; the buffered response is private to the cycle.
class FalconResponseMessage extends ChangeNotifier {
  final String id;
  String _displayed = '';
  FalconReplyPhase _phase = FalconReplyPhase.handoff;
  FalconResponseMessage(this.id);
  String get displayedText => _displayed;
  FalconReplyPhase get phase => _phase;
  void append(String token) { _displayed += token; notifyListeners(); }
  void transition(FalconReplyPhase phase) {
    _phase = phase;
    notifyListeners();
  }
}

/// Owns the only reply state machine and the only scheduling timer.
/// Geometry/animation callbacks are awaited, so tokens cannot outrun handoff.
/// Uses a monotonic elapsed clock; never adds four seconds after the network.
class FalconReplyController extends ChangeNotifier {
  final Future<void> Function(FalconResponseMessage) onHandoff;
  final VoidCallback onToken;
  final Future<void> Function() onDock;
  final VoidCallback onCompleted;
  final Duration Function() elapsed;
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;
  int _generation = 0;
  bool _disposed = false, _ready = false, _docking = false;
  Duration _due = Duration.zero;
  String _bufferedFullResponse = '';
  List<String> _tokens = [];
  int _next = 0;
  FalconReplyPhase phase = FalconReplyPhase.idle;
  FalconResponseMessage? message;
  FalconReplyController({required this.onHandoff, required this.onToken,
    required this.onDock, required this.onCompleted,
    Duration Function()? elapsed}) : elapsed = elapsed ?? (() => Duration.zero) {
    _externalClock = elapsed != null;
  }
  late final bool _externalClock;
  Duration get _now => _externalClock ? elapsed() : _clock.elapsed;
  bool get busy => phase != FalconReplyPhase.idle && phase != FalconReplyPhase.completed;

  /// Preserve every code unit, newline, list marker and Markdown delimiter.
  static List<String> tokenizePreservingWhitespace(String text) =>
      RegExp(r'\s+|\S+\s*', unicode: true).allMatches(text)
          .map((m) => m.group(0)!).toList();

  static Duration delayFor(String token) {
    final word = token.trimRight();
    var ms = 70;
    if (RegExp(r'[.!?؟…]["»\)\]]*$').hasMatch(word)) { ms += 180; }
    else if (RegExp(r'[,،;؛:]["»\)\]]*$').hasMatch(word)) { ms += 80; }
    if (token.contains('\n')) ms += 100;
    return Duration(milliseconds: ms);
  }

  void start(Future<String> Function() request, {required String failureText}) {
    if (busy || _disposed) return;
    final generation = ++_generation;
    _clock..reset()..start();
    phase = FalconReplyPhase.thinking;
    _ready = false;
    _docking = false;
    _next = 0;
    message = null;
    notifyListeners();
    Future<String>.sync(request).then((text) {
      if (_disposed || generation != _generation) return;
      _bufferedFullResponse = text;
      _ready = true;
    }, onError: (Object _, StackTrace __) {
      if (_disposed || generation != _generation) return;
      _bufferedFullResponse = failureText;
      _ready = true;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick(generation));
  }

  void _tick(int generation) {
    if (_disposed || generation != _generation) return;
    if (phase == FalconReplyPhase.thinking && _ready && _now >= const Duration(seconds: 4)) {
      phase = FalconReplyPhase.handoff;
      message = FalconResponseMessage('reply-$generation-${DateTime.now().microsecondsSinceEpoch}');
      _tokens = tokenizePreservingWhitespace(_bufferedFullResponse);
      notifyListeners();
      _handoff(generation);
    } else if (phase == FalconReplyPhase.streaming && _now >= _due) {
      if (_next < _tokens.length) {
        final token = _tokens[_next++];
        message!.append(token);
        onToken();
        _due = _now + delayFor(token);
      } else {
        phase = FalconReplyPhase.docking;
        message!.transition(phase);
        _due = _now + const Duration(milliseconds: 200);
        notifyListeners();
      }
    } else if (phase == FalconReplyPhase.docking && !_docking && _now >= _due) {
      _docking = true;
      _dock(generation);
    }
  }

  Future<void> _handoff(int generation) async {
    await onHandoff(message!);
    if (_disposed || generation != _generation) return;
    phase = FalconReplyPhase.streaming;
    message!.transition(phase);
    _due = _now;
    notifyListeners();
  }

  Future<void> _dock(int generation) async {
    await onDock();
    if (_disposed || generation != _generation) return;
    // Only a status change: no final-text assignment, no second append.
    assert(message!.displayedText == _bufferedFullResponse);
    phase = FalconReplyPhase.completed;
    _ticker?.cancel();
    _clock.stop();
    message!.transition(phase);
    onCompleted();
    notifyListeners();
  }

  void cancel() {
    ++_generation;
    _ticker?.cancel();
    _clock.stop();
    phase = FalconReplyPhase.idle;
  }

  @override
  void dispose() { _disposed = true; cancel(); super.dispose(); }
}
