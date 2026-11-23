import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/utils/server_image_url.dart';

void main() {
  test(
    'relative logos resolve at the server root regardless of API suffix',
    () {
      for (final base in [
        'https://example.test/api/v1',
        'https://example.test/api/v1/',
      ]) {
        for (final image in [
          'uploads/logo.png',
          '/uploads/logo.png',
          '  /uploads/logo.png  ',
        ]) {
          expect(
            serverImageUrl(image, baseUrl: base),
            'https://example.test/uploads/logo.png',
          );
        }
        expect(
          serverImageUrl('//cdn.test/logo.png', baseUrl: base),
          'https://cdn.test/logo.png',
        );
        expect(
          serverImageUrl('https://cdn.test/logo.png', baseUrl: base),
          'https://cdn.test/logo.png',
        );
      }
    },
  );
  test('empty and unsupported image URLs use the stable placeholder', () {
    for (final value in [
      null,
      '',
      '  ',
      'file:///private/logo.png',
      'javascript:alert(1)',
      'http:missing-host',
    ]) {
      expect(serverImageUrl(value), isNull);
    }
  });
}
