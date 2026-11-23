import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tts_preparation.dart';

/// A sentence pause after a full stop, never inside a number: "19.99" must
/// not be read as two numbers ("19. 99").
void main() {
  test('decimal numbers stay whole; sentences still get their pause', () {
    final out = TtsPreparation.prepare('السعر 19.99 اليوم.التالي', lang: 'ar');
    expect(out, contains('19.99'));
    expect(out, isNot(contains('19. 99')));
    expect(out, contains('اليوم. التالي'));
  });
}
