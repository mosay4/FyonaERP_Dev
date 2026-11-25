import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/ai/domain/services/sara_speech.dart';

/// Sara voice: the phone recognizes the speech and the TEXT is sent — no
/// upload, no server speech-to-text. The recorded-audio upload stays the
/// fallback when the recognizer cannot listen.
class _FakeBackend implements SaraSpeechBackend {
  final events$ = StreamController<SaraSpeechEvent>.broadcast();
  bool available = true;
  String? locale;
  int stops = 0;
  bool finalOnStop = true;

  @override
  Stream<SaraSpeechEvent> get events => events$.stream;

  @override
  Future<bool> start(String l) async {
    locale = l;
    return available;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (finalOnStop) events$.add(const SaraSpeechEvent('final', 'افتح البنوك'));
  }

  @override
  Future<void> cancel() async {}

  void emit(String type, [Object? v]) => events$.add(SaraSpeechEvent(type, v));
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeBackend backend;
  setUp(() => backend = _FakeBackend());

  test('partials stream, then the final text is the result', () async {
    final s = SaraSpeechSession(backend);
    expect(await s.start('ar'), isTrue);
    expect(backend.locale, 'ar-SA');
    backend.emit('partial', 'افتح');
    await _tick();
    expect(s.partial.value, 'افتح');
    final r = await s.stop();
    expect(r.end, SaraSpeechEnd.text);
    expect(r.text, 'افتح البنوك');
  });

  test('speech ending by itself (pause) completes without a tap', () async {
    final s = SaraSpeechSession(backend);
    await s.start('en');
    expect(backend.locale, 'en-US');
    backend.emit('partial', 'open the');
    backend.emit('final', 'open the banks');
    final r = await s.result;
    expect(r.text, 'open the banks');
    expect(backend.stops, 0);
  });

  test('no final after stop → the last partial is used', () async {
    backend.finalOnStop = false;
    final s = SaraSpeechSession(backend);
    await s.start('ar');
    backend.emit('partial', 'كم رصيدي');
    await _tick();
    final r = await s.stop(grace: const Duration(milliseconds: 20));
    expect(r.end, SaraSpeechEnd.text);
    expect(r.text, 'كم رصيدي');
  });

  test('recognizer missing or failing before any speech → record + upload', () async {
    backend.available = false;
    expect(await SaraSpeechSession(backend).start('ar'), isFalse);

    final b2 = _FakeBackend();
    final s = SaraSpeechSession(b2);
    await s.start('ar');
    b2.emit('error', 13); // language unavailable
    expect((await s.result).end, SaraSpeechEnd.useRecording);
  });

  test('heard but not recognized → nothing heard (no empty message sent)', () async {
    backend.finalOnStop = false;
    final s = SaraSpeechSession(backend);
    await s.start('ar');
    backend.emit('level', 8.0);
    backend.emit('error', 7); // no match
    final r = await s.result;
    expect(r.end, SaraSpeechEnd.nothingHeard);
    expect(r.text, isEmpty);
  });
}
