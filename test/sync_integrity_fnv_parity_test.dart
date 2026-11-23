import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/offline/sync_integrity.dart';

/// Verbatim copy of the pre-refactor VM-only arithmetic, used as the oracle.
String legacyFingerprint(Map<String, dynamic> data) {
  final canonical = canonicalJson(data);
  final bytes = <int>[];
  for (final unit in canonicalToString(canonical).codeUnits) {
    var cp = unit;
    if (cp >= 0xD800 && cp <= 0xDBFF) continue;
    if (cp < 0x80) {
      bytes.add(cp);
    } else if (cp < 0x800) {
      bytes.add(0xC0 | (cp >> 6));
      bytes.add(0x80 | (cp & 0x3F));
    } else {
      bytes.add(0xE0 | (cp >> 12));
      bytes.add(0x80 | ((cp >> 6) & 0x3F));
      bytes.add(0x80 | (cp & 0x3F));
    }
  }
  final mask = BigInt.parse('0xFFFFFFFFFFFFFFFF');
  final prime = BigInt.parse('0x100000001b3');
  BigInt hash = BigInt.parse('0xcbf29ce484222325');
  for (final b in bytes) {
    hash ^= BigInt.from(b);
    hash = (hash * prime) & mask;
  }
  final hi = (hash >> 32) & BigInt.parse('0xFFFFFFFF');
  final lo = hash & BigInt.parse('0xFFFFFFFF');
  String hex(BigInt v, int width) =>
      v.toRadixString(16).padLeft(width, '0');
  return '${hex(hi, 8)}${hex(lo, 8)}';
}

void main() {
  final rnd = Random(20261001);
  final payloads = <Map<String, dynamic>>[
    <String, dynamic>{},
    <String, dynamic>{'a': 1},
    <String, dynamic>{'amount': 500.5, 'currency': 'SAR'},
    <String, dynamic>{'z': 1, 'a': 2, 'm': <String, dynamic>{'q': true}},
    <String, dynamic>{'list': <dynamic>[1, 2, <String, dynamic>{'b': null}]},
    <String, dynamic>{'unicode': 'مرحبا بالعالم'},
    <String, dynamic>{'quote': 'a"b\\c\nd\te'},
    <String, dynamic>{'big': 9007199254740991},
    <String, dynamic>{'neg': -42, 'zero': 0},
  ];
  for (var i = 0; i < 400; i++) {
    final m = <String, dynamic>{};
    final n = 1 + rnd.nextInt(6);
    for (var j = 0; j < n; j++) {
      final key = 'k${rnd.nextInt(1000)}';
      m[key] = switch (rnd.nextInt(5)) {
        0 => rnd.nextInt(1 << 30),
        1 => rnd.nextDouble() * 10000,
        2 => 'v${rnd.nextInt(1 << 20)}',
        3 => rnd.nextBool(),
        _ => null,
      };
    }
    payloads.add(m);
  }

  test('limb arithmetic is bit-identical to the previous VM-only hash', () {
    for (final p in payloads) {
      expect(
        fingerprintPayload(p),
        legacyFingerprint(p),
        reason: 'mismatch for $p',
      );
    }
  });

  test('fingerprints stay 16 lowercase hex chars', () {
    for (final p in payloads) {
      expect(fingerprintPayload(p), matches(RegExp(r'^[0-9a-f]{16}$')));
    }
  });

  test('empty payload hash is stable and locked to the canonical "{}"', () {
    // canonicalToString({}) is '{}', not the empty string, so the hash is
    // FNV-1a 64 of "{}" rather than the bare offset basis.
    expect(fingerprintPayload(<String, dynamic>{}), '08f44b07b5901a25');
  });

  test('known vectors are unchanged', () {
    expect(
      fingerprintPayload(<String, dynamic>{'a': 1}),
      legacyFingerprint(<String, dynamic>{'a': 1}),
    );
  });

  test('key order does not affect the fingerprint', () {
    final a = fingerprintPayload(<String, dynamic>{'x': 1, 'y': 2});
    final b = fingerprintPayload(<String, dynamic>{'y': 2, 'x': 1});
    expect(a, b);
  });

  test('Uint8List payloads do not change the encoding path', () {
    final p = <String, dynamic>{'raw': Uint8List.fromList([1, 2, 3]).toList()};
    expect(fingerprintPayload(p), legacyFingerprint(p));
  });
}
