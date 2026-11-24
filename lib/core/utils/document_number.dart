/// The short, readable form of a document number for the screen and the PDF.
///
/// Device documents keep a long, globally unique number (two phones offline
/// can never collide, and the database enforces it). People see a short
/// prefix and the first 8 characters of its unique part instead:
///
///   INV-20261124-4DAF502718C45245BA5728D264E50019  →  INV-4DAF5027
///   5243e4c5-5733-4fae-b9f9-4261d37042c4 (TRF)    →  TRF-5243E4C5
///
/// The short code is part of the full number, so searching by it still finds
/// the document. Any other number (server, manual, legacy) is shown as is.
String shortDocumentNumber(Object? raw, {String? uuidPrefix}) {
  final value = '${raw ?? ''}'.trim();
  if (value.isEmpty || value == 'null') return '';
  final dated = _dated.firstMatch(value);
  if (dated != null) {
    return '${dated[1]!.toUpperCase()}-${dated[2]!.substring(0, 8).toUpperCase()}';
  }
  if (_uuid.hasMatch(value)) {
    final code = value.replaceAll('-', '').substring(0, 8).toUpperCase();
    return uuidPrefix == null || uuidPrefix.isEmpty ? code : '$uuidPrefix-$code';
  }
  return value;
}

final _dated = RegExp(r'^([A-Za-z]{2,5})-\d{8}-([0-9A-Fa-f]{32})$');
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
