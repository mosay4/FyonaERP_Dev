import 'package:flutter/widgets.dart';

import '../../localization/app_localizations.dart';
import '../help_detector.dart';
import 'help_entry.dart';

/// The explanation the card shows for one press.
class HelpMatch {
  final HelpEntry entry;
  final String title;
  final String body;
  final List<String> how;

  /// How the element was recognised: id / key / text / icon / row.
  final String via;
  const HelpMatch({
    required this.entry,
    required this.title,
    required this.body,
    required this.how,
    required this.via,
  });
}

/// Normalises a visible label for matching (diacritics, tatweel, emoji,
/// trailing ':' / '*', whitespace, latin case).
String helpNormalize(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp('[ؗ-ًؚ-ْٰـ]'), '');
  s = s.replaceAll(
      RegExp(
          '[☀-➿←-⇿⬀-⯿︀-️‍‎‏\u{1F300}-\u{1FAFF}]',
          unicode: true),
      '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // '+ إضافة صورة', '• خيار'
  s = s.replaceFirst(RegExp(r'^[+•·\-–]\s*'), '');
  while (s.endsWith('*') || s.endsWith(':') || s.endsWith('…')) {
    s = s.substring(0, s.length - 1).trim();
  }
  while (s.endsWith('...')) {
    s = s.substring(0, s.length - 3).trim();
  }
  return s.toLowerCase();
}

/// Reverse index of the ARB tables: visible text → ARB key(s).
class HelpLabelIndex {
  HelpLabelIndex._();

  static final Map<String, Map<String, List<String>>> _exact = {};
  static final Map<String, List<(RegExp, String)>> _patterns = {};
  static final Map<String, Object?> _built = {};

  static void _ensure(String lang) {
    final table = AppLocalizations.cachedTable(lang);
    if (table == null) return;
    if (identical(_built[lang], table)) return;
    final exact = <String, List<String>>{};
    final patterns = <(RegExp, String)>[];
    table.forEach((key, value) {
      if (key.startsWith('@') || value is! String) return;
      if (value.contains('{')) {
        final parts = value.split(RegExp(r'\{[^}]*\}'));
        final src = parts.map((p) => RegExp.escape(helpNormalize(p))).join('.+?');
        if (src.replaceAll('.+?', '').trim().length < 2) return;
        try {
          patterns.add((RegExp('^$src\$'), key));
        } catch (_) {}
        return;
      }
      final n = helpNormalize(value);
      if (n.isEmpty) return;
      (exact[n] ??= <String>[]).add(key);
    });
    _exact[lang] = exact;
    _patterns[lang] = patterns;
    _built[lang] = table;
  }

  /// ARB keys whose text (in any loaded language) reads exactly [label].
  static List<String> keysFor(String label) {
    final n = helpNormalize(label);
    if (n.isEmpty) return const [];
    final out = <String>[];
    for (final lang in const ['ar', 'en']) {
      _ensure(lang);
      final hit = _exact[lang]?[n];
      if (hit != null) {
        for (final k in hit) {
          if (!out.contains(k)) out.add(k);
        }
      }
    }
    if (out.isNotEmpty) return out;
    // Labels with a live count: 'حفظ (3)', 'عرض الدفعات (2)', 'الكل · 12'.
    final bare = n
        .replaceAll(RegExp(r'\s*[(\[][^()\[\]]*[)\]]\s*$'), '')
        .replaceAll(RegExp(r'\s*[·•:]\s*[\d٠-٩.,]+\s*$'), '')
        .replaceAll(RegExp(r'\s+[\d٠-٩.,]+$'), '')
        .trim();
    if (bare.isNotEmpty && bare != n) {
      for (final lang in const ['ar', 'en']) {
        final hit = _exact[lang]?[bare];
        if (hit != null) {
          for (final k in hit) {
            if (!out.contains(k)) out.add(k);
          }
        }
      }
      if (out.isNotEmpty) return out;
    }
    for (final lang in const ['ar', 'en']) {
      for (final (re, key) in _patterns[lang] ?? const <(RegExp, String)>[]) {
        if (re.hasMatch(n) && !out.contains(key)) out.add(key);
      }
    }
    return out;
  }

  /// Current-language text of [key] (null when unknown).
  static String? textOf(String key, {required bool arabic}) {
    final t = AppLocalizations.cachedTable(arabic ? 'ar' : 'en') ??
        AppLocalizations.cachedTable('ar');
    final v = t?[key];
    return v is String ? v : null;
  }
}

/// Resolves a [HelpProbe] to curated help — or to nothing at all.
class HelpCatalog {
  final List<HelpEntry> entries;
  final Map<String, List<HelpEntry>> _byKey = {};
  final Map<String, List<HelpEntry>> _byText = {};
  final Map<String, HelpEntry> _byId = {};
  final List<HelpEntry> _iconEntries = [];
  final List<HelpEntry> _rowEntries = [];

  HelpCatalog(this.entries) {
    for (final e in entries) {
      _byId[e.id] = e;
      for (final id in e.ids) {
        _byId[id] = e;
      }
      for (final k in e.keys) {
        (_byKey[k] ??= <HelpEntry>[]).add(e);
      }
      for (final t in e.texts) {
        (_byText[helpNormalize(t)] ??= <HelpEntry>[]).add(e);
      }
      if (e.icons.isNotEmpty) _iconEntries.add(e);
      if (e.row) _rowEntries.add(e);
    }
  }

  HelpEntry? byId(String id) => _byId[id];

  static String _path(String route) {
    final p = route.split('?').first.split('#').first;
    return p.isEmpty ? '/' : p;
  }

  /// Scoped entries first (most specific scope wins), then global ones.
  static HelpEntry? _pick(Iterable<HelpEntry> list, String path) {
    HelpEntry? scoped;
    var scopedLen = -1;
    HelpEntry? global;
    for (final e in list) {
      if (e.row) continue;
      if (e.isScoped) {
        if (!e.appliesTo(path)) continue;
        final len = e.scopes
            .where((s) => s == path || path.startsWith(s))
            .fold<int>(0, (m, s) => s.length > m ? s.length : m);
        if (len > scopedLen) {
          scoped = e;
          scopedLen = len;
        }
      } else {
        global ??= e;
      }
    }
    return scoped ?? global;
  }

  static bool _iconEq(Object a, Object b) {
    if (identical(a, b)) return true;
    if (a is IconData && b is IconData) {
      return a.codePoint == b.codePoint &&
          a.fontFamily == b.fontFamily &&
          a.fontPackage == b.fontPackage;
    }
    return a == b;
  }

  static final RegExp _letters = RegExp(r'[A-Za-z؀-ۿ]');

  HelpEntry? _forLabel(String label, String path) {
    final n = helpNormalize(label);
    if (n.isEmpty) return null;
    final byText = _byText[n];
    if (byText != null) {
      final e = _pick(byText, path);
      if (e != null) return e;
    }
    final keys = HelpLabelIndex.keysFor(label);
    final hits = <HelpEntry>[];
    for (final k in keys) {
      hits.addAll(_byKey[k] ?? const []);
    }
    return _pick(hits, path);
  }

  HelpMatch? resolve(
    HelpProbe probe, {
    required String route,
    required bool arabic,
  }) {
    final path = _path(route);
    HelpMatch build(HelpEntry e, String via, String? shown) {
      var title = arabic ? e.arTitle : e.enTitle;
      if (title == null || title.isEmpty) {
        final s = shown?.trim() ?? '';
        if (s.isNotEmpty && s.length <= 40) {
          title = s;
        } else if (e.keys.isNotEmpty) {
          title = HelpLabelIndex.textOf(e.keys.first, arabic: arabic);
        }
      }
      return HelpMatch(
        entry: e,
        title: (title == null || title.isEmpty)
            ? (arabic ? 'معلومة' : 'Info')
            : title,
        body: arabic ? e.ar : e.en,
        how: arabic ? e.arHow : e.enHow,
        via: via,
      );
    }

    // 1. Explicit registration.
    final id = probe.explicitId;
    if (id != null) {
      final e = _byId[id];
      if (e != null) return build(e, 'id', null);
    }

    final lettered = probe.texts.where(_letters.hasMatch).toList();

    // 2. Record rows: a wide tile whose leading text is user data.
    HelpEntry? row;
    if (probe.wide) {
      for (final e in _rowEntries) {
        if (e.appliesTo(path)) {
          row = e;
          break;
        }
      }
    }
    if (row != null &&
        (lettered.isEmpty || _forLabel(lettered.first, path) == null)) {
      return build(row, 'row', null);
    }

    // 3. Visible labels and tooltips, in order.
    for (final label in [...probe.texts, ...probe.tooltips]) {
      final e = _forLabel(label, path);
      if (e != null) {
        final shown = probe.texts.contains(label) ? label : null;
        return build(e, 'key', shown);
      }
    }

    // 4. Icon-only elements (or a scoped icon entry for this screen).
    final iconHits = <HelpEntry>[];
    for (final ic in probe.icons) {
      for (final e in _iconEntries) {
        if (e.icons.any((x) => _iconEq(x, ic))) iconHits.add(e);
      }
    }
    if (iconHits.isNotEmpty) {
      final e = _pick(iconHits, path);
      if (e != null && (lettered.isEmpty || e.isScoped)) {
        return build(e, 'icon', null);
      }
    }
    return null;
  }
}
