/// Shadow sync-integrity layer (additive, non-blocking).
///
/// Phase 1 (current): stamp metadata at stage time and verify it at replay
/// time in SHADOW mode — results are observed/logged only. Replay payloads,
/// conflict resolution and sync behavior are byte-for-byte identical with or
/// without this layer.
///
/// Safety contract (non-negotiable):
///  * [verifyStagedIntegrity] NEVER throws and NEVER fails closed: legacy
///    rows without a hash pass, and even a mismatch only reports `false` for
///    logging — the caller MUST still replay the operation unchanged.
///  * [fingerprintPayload] is deterministic: canonical JSON (recursively
///    sorted keys) hashed with FNV-1a 64, so stage-time and replay-time maps
///    compare equal regardless of key insertion order.
library;

/// Recursively canonicalises a JSON-compatible value: map keys sorted,
/// list order preserved, scalars passed through.
dynamic canonicalJson(dynamic value) {
  if (value is Map) {
    final sortedKeys =
        value.keys.map((k) => k.toString()).toList()..sort();
    final out = <String, dynamic>{};
    for (final k in sortedKeys) {
      final entry =
          value.entries.firstWhere((e) => e.key.toString() == k);
      out[k] = canonicalJson(entry.value);
    }
    return out;
  }
  if (value is List) {
    return value.map(canonicalJson).toList();
  }
  if (value is num || value is bool || value == null) return value;
  return value.toString();
}

/// Deterministic fingerprint of a staged payload map: exactly 16 lowercase
/// hex chars (FNV-1a 64 over the canonical JSON encoding; multiply wraps
/// mod 2^64 and the bits are rendered unsigned via two 32-bit halves —
/// `int.toUnsigned(64)` is a no-op on the VM and must not be used here).
///
/// The 64-bit state is carried as four 16-bit limbs ([_Fnv1a64]) instead of a
/// single Dart `int` literal. A literal like `0xcbf29ce484222325` compiles on
/// the VM but is rejected by dart2js ("can't be represented exactly in
/// JavaScript"), which broke `flutter build web`; 16-bit limbs keep every
/// intermediate product at or below ~2^32, exact in JS doubles, and produce
/// bit-identical hashes to the previous VM-only arithmetic — so fingerprints
/// already stored in `sync_queue.payload_hash` keep verifying unchanged.
String fingerprintPayload(Map<String, dynamic> data) {
  final canonical = canonicalJson(data);
  final bytes = _utf8(canonicalToString(canonical));
  final h = _Fnv1a64();
  for (final b in bytes) {
    h.xorByte(b);
    h.multiplyPrime();
  }
  final hi = h.hi32();
  final lo = h.lo32();
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

/// 64-bit FNV-1a accumulator held as four 16-bit limbs (least-significant
/// first) so the multiply never leaves the exact-integer range of a JS double.
class _Fnv1a64 {
  /// FNV-1a 64 offset basis, little-endian 16-bit limbs.
  static const int _basis0 = 0x2325;
  static const int _basis1 = 0x8422;
  static const int _basis2 = 0x9ce4;
  static const int _basis3 = 0xcbf2;

  /// FNV-1a 64 prime `0x100000001b3`, little-endian 16-bit limbs.
  static const int _prime0 = 0x01b3;
  static const int _prime1 = 0x0000;
  static const int _prime2 = 0x0100;
  static const int _prime3 = 0x0000;

  static const int _mask16 = 0xFFFF;

  int _l0 = _basis0;
  int _l1 = _basis1;
  int _l2 = _basis2;
  int _l3 = _basis3;

  /// XORs a single byte into the low limb (FNV-1a's mix step).
  void xorByte(int b) {
    _l0 ^= b;
  }

  /// Multiplies the 64-bit state by the FNV-1a prime, wrapping mod 2^64.
  void multiplyPrime() {
    final a0 = _l0, a1 = _l1, a2 = _l2, a3 = _l3;
    // Raw partial products; limbs 4..6 exist only to absorb carries and are
    // discarded, which is exactly the mod 2^64 wrap.
    final raw0 = a0 * _prime0;
    final raw1 = a1 * _prime0 + a0 * _prime1;
    final raw2 = a2 * _prime0 + a1 * _prime1 + a0 * _prime2;
    final raw3 = a3 * _prime0 + a2 * _prime1 + a1 * _prime2 + a0 * _prime3;
    var carry0 = raw0 >> 16;
    final l0 = raw0 & _mask16;
    final raw1c = raw1 + carry0;
    carry0 = raw1c >> 16;
    final l1 = raw1c & _mask16;
    final raw2c = raw2 + carry0;
    carry0 = raw2c >> 16;
    final l2 = raw2c & _mask16;
    _l3 = (raw3 + carry0) & _mask16;
    _l0 = l0;
    _l1 = l1;
    _l2 = l2;
  }

  /// Upper 32 bits, unsigned.
  int hi32() => (_l3 << 16) | _l2;

  /// Lower 32 bits, unsigned.
  int lo32() => (_l1 << 16) | _l0;
}

String canonicalToString(dynamic canonical) {
  if (canonical is Map) {
    final parts = <String>[];
    for (final k in (canonical.keys.toList()..sort())) {
      parts.add('${_escape(k)}:${canonicalToString(canonical[k])}');
    }
    return '{${parts.join(',')}}';
  }
  if (canonical is List) {
    return '[${canonical.map(canonicalToString).join(',')}]';
  }
  if (canonical is String) return '"${_escape(canonical)}"';
  if (canonical == null) return 'null';
  return canonical.toString();
}

String _escape(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

List<int> _utf8(String s) {
  // Minimal UTF-8 encoder (avoids dart:convert dependency here).
  final out = <int>[];
  for (final unit in s.codeUnits) {
    var cp = unit;
    if (cp >= 0xD800 && cp <= 0xDBFF) continue; // surrogates: best-effort
    if (cp < 0x80) {
      out.add(cp);
    } else if (cp < 0x800) {
      out.add(0xC0 | (cp >> 6));
      out.add(0x80 | (cp & 0x3F));
    } else {
      out.add(0xE0 | (cp >> 12));
      out.add(0x80 | ((cp >> 6) & 0x3F));
      out.add(0x80 | (cp & 0x3F));
    }
  }
  return out;
}

/// Shadow verification of one staged operation.
///
/// Returns `true` for legacy rows without a hash AND on any internal error
/// (never fail closed). A `false` means "staged bytes differ from replay
/// bytes" and is for LOGGING ONLY — replay must proceed unchanged.
bool verifyStagedIntegrity({
  required Map<String, dynamic> data,
  String? expectedHash,
}) {
  if (expectedHash == null || expectedHash.isEmpty) return true;
  try {
    return fingerprintPayload(data) == expectedHash;
  } catch (_) {
    return true;
  }
}
