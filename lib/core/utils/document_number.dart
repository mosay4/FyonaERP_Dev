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
  // In order of creation (owner, 28-11): OPEN-208, INV-15 — known once the
  // branch's documents were read (DocumentSerials).
  final serial = dated == null ? null : DocumentSerials.of(value);
  if (serial != null) return '${dated![1]!.toUpperCase()}-$serial';
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

/// Sequential numbers of the branch's device documents, per kind (INV,
/// PUR, OPEN, RET…), in the order they were made. Read from the ledger
/// (the stored number stays the long unique one: two phones offline never
/// collide); the screens show `OPEN-208` instead of a long code.
abstract final class DocumentSerials {
  static final _of = <String, int>{};
  static final _back = <String, String>{};

  static void put(Map<String, int> serials) {
    _of
      ..clear()
      ..addAll(serials);
    _back
      ..clear()
      ..addAll({for (final e in serials.entries) '${e.key.split('-').first}-${e.value}': e.key});
  }

  static int? of(String number) => _of[number.trim().toUpperCase()];

  /// Whether [number] is a device document number not read yet.
  static bool missing(Object? number) {
    final v = '${number ?? ''}'.trim();
    return _dated.hasMatch(v) && !_of.containsKey(v.toUpperCase());
  }

  /// The full number a short one (`OPEN-208`) stands for, for search.
  static String? full(String short) => _back[short.trim().toUpperCase()];
}
