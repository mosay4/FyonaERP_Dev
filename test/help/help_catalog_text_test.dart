import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fyona_flutter/core/help/catalog/help_catalog.dart';
import 'package:fyona_flutter/core/help/catalog/help_entry.dart';
import 'package:fyona_flutter/core/help/catalog/help_registry.dart';

import '../test_utils.dart';

/// Every registered help entry must have real, short, plain text in BOTH
/// Arabic and English — a missing or broken text fails the build.
void main() {
  final entries = HelpRegistry.all;
  final ar = json.decode(File('assets/l10n/app_ar.arb').readAsStringSync())
      as Map<String, dynamic>;
  final en = json.decode(File('assets/l10n/app_en.arb').readAsStringSync())
      as Map<String, dynamic>;
  final arabicLetters = RegExp(r'[؀-ۿ]');

  setUpAll(() async {
    await ensureTestLocalization('ar');
    await ensureTestLocalization('en');
  });

  test('labels resolve by ARB key, also with live counts and prefixes', () {
    expect(HelpLabelIndex.keysFor('حفظ'), contains('save'));
    expect(HelpLabelIndex.keysFor('Save'), contains('save'));
    expect(HelpLabelIndex.keysFor('حفظ (3)'), contains('save'));
    expect(HelpLabelIndex.keysFor('+ حفظ'), contains('save'));
    expect(HelpLabelIndex.keysFor('مؤسسة النخيل للتجارة'), isEmpty);
  });

  test('catalog is not empty', () {
    expect(entries.length, greaterThan(300));
  });

  test('ids are unique (entry ids and explicit HelpTarget ids)', () {
    final seen = <String>{};
    final dup = <String>[];
    for (final e in entries) {
      for (final id in [e.id, ...e.ids]) {
        if (!seen.add(id)) dup.add(id);
      }
    }
    expect(dup, isEmpty, reason: 'duplicate ids: $dup');
  });

  test('every entry has Arabic AND English text', () {
    final bad = <String>[];
    for (final e in entries) {
      if (e.ar.trim().isEmpty || !arabicLetters.hasMatch(e.ar)) {
        bad.add('${e.id}: ar missing');
      }
      if (e.en.trim().isEmpty || arabicLetters.hasMatch(e.en)) {
        bad.add('${e.id}: en missing or not English');
      }
      if (e.arHow.length != e.enHow.length) {
        bad.add('${e.id}: arHow/enHow differ in length');
      }
      for (final s in e.arHow) {
        if (s.trim().isEmpty || !arabicLetters.hasMatch(s)) {
          bad.add('${e.id}: empty Arabic step');
        }
      }
      for (final s in e.enHow) {
        if (s.trim().isEmpty || arabicLetters.hasMatch(s)) {
          bad.add('${e.id}: empty/Arabic English step');
        }
      }
      if ((e.arTitle == null) != (e.enTitle == null)) {
        bad.add('${e.id}: title in one language only');
      }
      if (e.arTitle != null && !arabicLetters.hasMatch(e.arTitle!)) {
        bad.add('${e.id}: arTitle not Arabic');
      }
      if (e.enTitle != null && arabicLetters.hasMatch(e.enTitle!)) {
        bad.add('${e.id}: enTitle not English');
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('texts stay short: one idea sentence, at most 3 short steps', () {
    final bad = <String>[];
    for (final e in entries) {
      if (e.ar.length > 140) bad.add('${e.id}: ar ${e.ar.length} chars');
      if (e.en.length > 160) bad.add('${e.id}: en ${e.en.length} chars');
      if (e.arHow.length > 3) bad.add('${e.id}: ${e.arHow.length} steps');
      for (final s in [...e.arHow, ...e.enHow]) {
        if (s.length > 90) bad.add('${e.id}: long step "$s"');
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('no accounting jargon in the Arabic help', () {
    const jargon = ['مدين', 'دائن', 'قيد يومية', 'القيود', 'ترحيل', 'الذمم', 'ذمم'];
    final bad = <String>[];
    for (final e in entries) {
      for (final s in [e.ar, ...e.arHow]) {
        for (final j in jargon) {
          if (s.contains(j)) bad.add('${e.id}: "$j" in "$s"');
        }
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('every matcher is valid: keys exist in AR and EN, icon/row entries '
      'carry titles, every entry can be matched', () {
    final bad = <String>[];
    for (final e in entries) {
      for (final k in e.keys) {
        if (ar[k] is! String) bad.add('${e.id}: key "$k" missing in app_ar');
        if (en[k] is! String) bad.add('${e.id}: key "$k" missing in app_en');
      }
      final matchable = e.keys.isNotEmpty ||
          e.texts.isNotEmpty ||
          e.icons.isNotEmpty ||
          e.ids.isNotEmpty ||
          e.row;
      if (!matchable) bad.add('${e.id}: nothing can match it');
      final needsTitle = e.keys.isEmpty && e.texts.isEmpty;
      if (needsTitle && (e.arTitle == null || e.enTitle == null)) {
        bad.add('${e.id}: icon/row/explicit entry without a title');
      }
      if (e.row && e.scopes.isEmpty) bad.add('${e.id}: row entry without scope');
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('a label key is never claimed by two global entries', () {
    final owner = <String, String>{};
    final bad = <String>[];
    for (final e in entries.where((e) => !e.isScoped && !e.row)) {
      for (final k in e.keys) {
        final prev = owner[k];
        if (prev != null && prev != e.id) bad.add('$k: $prev vs ${e.id}');
        owner[k] = e.id;
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('every HelpTarget id used in lib/ has an entry', () {
    final known = <String>{
      for (final HelpEntry e in entries) ...[e.id, ...e.ids],
    };
    final used = <String>{};
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r"""HelpTarget\(\s*id:\s*'([^']+)'""")
          .allMatches(f.readAsStringSync())) {
        used.add(m.group(1)!);
      }
    }
    final missing = used.difference(known);
    expect(missing, isEmpty, reason: 'HelpTarget ids without text: $missing');
  });
}
