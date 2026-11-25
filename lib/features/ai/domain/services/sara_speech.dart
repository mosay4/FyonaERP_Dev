import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────
// SaraSpeech — Sara's voice input through the phone's own recognizer.
//
// Android: android.speech.SpeechRecognizer (MainActivity, channel
// `com.fyona.erp/speech`) with EXTRA_PREFER_OFFLINE — on-device when the
// language pack is installed, the platform's streaming service otherwise.
// iOS: SFSpeechRecognizer (AppDelegate), on-device when supported.
//
// Partial results stream while the user speaks; the recognized TEXT is
// sent to Sara the moment speech ends — no audio upload, no server
// speech-to-text. When the recognizer is missing or fails before hearing
// anything, the caller falls back to the recorded-audio upload path.
// No plugin: zero APK size added.
// ─────────────────────────────────────────────────────────────

/// One event from the platform recognizer.
class SaraSpeechEvent {
  /// ready | partial | final | level | end | error
  final String type;
  final Object? value;
  const SaraSpeechEvent(this.type, [this.value]);
}

/// The platform side (a MethodChannel in the app; a fake in tests).
abstract class SaraSpeechBackend {
  Future<bool> start(String locale);
  Future<void> stop();
  Future<void> cancel();
  Stream<SaraSpeechEvent> get events;
}

class MethodChannelSpeechBackend implements SaraSpeechBackend {
  MethodChannelSpeechBackend() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onSpeech') return;
      final args = call.arguments is Map ? call.arguments as Map : const {};
      _events.add(SaraSpeechEvent('${args['type'] ?? ''}', args['value']));
    });
  }

  static const MethodChannel _channel = MethodChannel('com.fyona.erp/speech');
  final _events = StreamController<SaraSpeechEvent>.broadcast();

  @override
  Stream<SaraSpeechEvent> get events => _events.stream;

  @override
  Future<bool> start(String locale) async {
    try {
      return await _channel.invokeMethod<bool>('start', {'lang': locale}) ?? false;
    } catch (_) {
      return false; // no native side (older build, desktop): upload path
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }
}

/// How a voice request ended.
enum SaraSpeechEnd {
  /// Recognized text is ready to send.
  text,

  /// The recognizer failed before hearing anything: record and upload.
  useRecording,

  /// Speech was heard but nothing could be recognized.
  nothingHeard,
}

class SaraSpeechResult {
  final SaraSpeechEnd end;
  final String text;
  const SaraSpeechResult(this.end, [this.text = '']);
}

/// One voice request: start → partials → result (on silence or stop).
class SaraSpeechSession {
  SaraSpeechSession(this._backend);

  final SaraSpeechBackend _backend;

  static SaraSpeechBackend? _shared;

  /// Test seam: the backend new sessions use.
  @visibleForTesting
  static SaraSpeechBackend? debugBackend;

  /// The phone recognizer exists on Android and iOS; elsewhere (Windows,
  /// web) Sara keeps the recorded-audio path.
  static bool get supported =>
      debugBackend != null || (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  factory SaraSpeechSession.platform() =>
      SaraSpeechSession(debugBackend ?? (_shared ??= MethodChannelSpeechBackend()));

  /// BCP-47 locale for Sara's chat language (Arabic or English).
  static String localeFor(String language) => language == 'en' ? 'en-US' : 'ar-SA';

  final _done = Completer<SaraSpeechResult>();
  StreamSubscription<SaraSpeechEvent>? _sub;
  String _partial = '';
  bool _heard = false;
  bool _stopping = false;

  /// Live transcript while the user speaks.
  final ValueNotifier<String> partial = ValueNotifier('');

  /// Input level 0..1 (for the waveform).
  final ValueNotifier<double> level = ValueNotifier(0);

  /// Completes once with the outcome — also when the recognizer ends by
  /// itself after a pause (the text is sent without waiting for a tap).
  Future<SaraSpeechResult> get result => _done.future;

  bool get isDone => _done.isCompleted;

  /// Starts listening. False → the recognizer is unavailable: record.
  Future<bool> start(String language) async {
    _sub = _backend.events.listen(_onEvent);
    final ok = await _backend.start(localeFor(language));
    if (!ok) {
      await _sub?.cancel();
      _sub = null;
    }
    return ok;
  }

  void _onEvent(SaraSpeechEvent e) {
    if (_done.isCompleted) return;
    switch (e.type) {
      case 'partial':
        final t = '${e.value ?? ''}'.trim();
        if (t.isNotEmpty) {
          _heard = true;
          _partial = t;
          partial.value = t;
        }
      case 'level':
        final db = (e.value is num) ? (e.value as num).toDouble() : 0.0;
        // Android reports roughly -2..10 dB.
        level.value = ((db + 2) / 12).clamp(0.0, 1.0);
        if (db > 3) _heard = true;
      case 'final':
        final t = '${e.value ?? ''}'.trim();
        _finish(t.isNotEmpty ? t : _partial);
      case 'error':
        if (_partial.isNotEmpty) {
          _finish(_partial);
        } else {
          _complete(SaraSpeechResult(
              _heard || _stopping ? SaraSpeechEnd.nothingHeard : SaraSpeechEnd.useRecording));
        }
    }
  }

  void _finish(String text) => _complete(text.isEmpty
      ? const SaraSpeechResult(SaraSpeechEnd.nothingHeard)
      : SaraSpeechResult(SaraSpeechEnd.text, text));

  void _complete(SaraSpeechResult r) {
    if (_done.isCompleted) return;
    _done.complete(r);
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// The user tapped stop: the recognizer finalizes what it heard. If no
  /// final result arrives within [grace], the last partial is used.
  Future<SaraSpeechResult> stop({Duration grace = const Duration(milliseconds: 1500)}) async {
    if (_done.isCompleted) return _done.future;
    _stopping = true;
    await _backend.stop();
    return _done.future.timeout(grace, onTimeout: () {
      _finish(_partial);
      unawaited(_backend.cancel());
      return _done.future;
    });
  }

  Future<void> cancel() async {
    _complete(const SaraSpeechResult(SaraSpeechEnd.nothingHeard));
    await _backend.cancel();
  }

  void dispose() {
    partial.dispose();
    level.dispose();
    unawaited(_sub?.cancel());
  }
}
