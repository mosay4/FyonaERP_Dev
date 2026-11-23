import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/ai/domain/agent/param_normalizer.dart';

void main() {
  group('compound numbers - exact or ask (P3.1)', () {
    test('ألفان وثلاثمائة -> ask (null) not wrong', () {
      expect(ParamNormalizer.extractWordNumber('ألفان وثلاثمائة'), isNull);
    });
    test('ألف وخمسمائة -> ask', () {
      expect(ParamNormalizer.extractWordNumber('ألف وخمسمائة'), isNull);
    });
    test('خمسة آلاف ومائتان -> ask', () {
      expect(ParamNormalizer.extractWordNumber('خمسة آلاف ومائتان'), isNull);
    });
    test('مليون ونصف = 1500000', () {
      expect(ParamNormalizer.extractWordNumber('مليون ونصف'), 1500000);
    });
    test('مليون ومائتان ألف -> ask', () {
      expect(ParamNormalizer.extractWordNumber('مليون ومائتان ألف'), isNull);
    });
    test('مليون وخمسة آلاف -> ask', () {
      expect(ParamNormalizer.extractWordNumber('مليون وخمسة آلاف'), isNull);
    });
    test('مئتان وخمسون -> ask', () {
      expect(ParamNormalizer.extractWordNumber('مئتان وخمسون'), isNull);
    });
    test('ثلاثة ملايين وخمسمائة ألف -> ask', () {
      expect(ParamNormalizer.extractWordNumber('ثلاثة ملايين وخمسمائة ألف'), isNull);
    });
    test('5 آلاف via digits', () {
      expect(ParamNormalizer.extractFirstNumber('دفعت 5 آلاف'), 5000);
    });
    test('ambiguous returns null', () {
      expect(ParamNormalizer.extractWordNumber('مليون و حاجة غريبة'), isNull);
    });
  });
}
