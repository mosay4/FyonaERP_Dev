import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';

void main() {
  test('device numbers are shown short; others as they are', () {
    expect(
      shortDocumentNumber('PRT-20261124-4DAF502718C45245BA5728D264E50019'),
      'PRT-4DAF5027',
    );
    expect(
      shortDocumentNumber('INV-20261124-0a1b2c3d4e5f60718293a4b5c6d7e8f9'),
      'INV-0A1B2C3D',
    );
    expect(
      shortDocumentNumber('5243e4c5-5733-4fae-b9f9-4261d37042c4', uuidPrefix: 'TRF'),
      'TRF-5243E4C5',
    );
    expect(shortDocumentNumber('INV-2026-0001'), 'INV-2026-0001');
    expect(shortDocumentNumber(null), '');
    // The short code is still part of the full number (search keeps working).
    expect(
      'PRT-20261124-4DAF502718C45245BA5728D264E50019'.contains('4DAF5027'),
      isTrue,
    );
  });
}
