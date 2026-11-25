import 'package:flutter/widgets.dart';

/// One curated explanation for the Information Clicker (long-press help).
///
/// An entry is matched to the pressed element by WHAT the element shows,
/// never by guessing from screen text:
///
///  * [keys]   — ARB keys (assets/l10n/app_*.arb) whose text labels the
///               element. Matching goes through the key, so wording changes in
///               the .arb files never break help.
///  * [texts]  — literal labels for the few elements whose copy is written in
///               code (`isAr ? 'حفظ الصلاحيات' : 'Save permissions'`).
///  * [icons]  — for icon-only elements: an [IconData], a HugeIcons list
///               (`HugeIcons.strokeRoundedX`) or a `TwoToneIconData`.
///               Icon entries must carry [arTitle]/[enTitle].
///  * [ids]    — explicit ids used by `HelpTarget(id: …)` wrappers.
///
/// [scopes] limits an entry to route paths ('/customers' matches
/// '/customers' and '/customers/…'; '/' matches only the home route).
/// An empty list means "everywhere". Scoped entries always win over global
/// ones for the same element.
///
/// [row] marks a section fallback for record rows/cards (a customer row,
/// a bank card…) whose visible text is user data: it applies on [scopes]
/// only, to wide tappable tiles that matched nothing else.
@immutable
class HelpEntry {
  final String id;
  final List<String> keys;
  final List<String> texts;
  final List<Object> icons;
  final List<String> ids;
  final List<String> scopes;
  final bool row;

  /// Icon shown (animated) in the help card.
  final IconData icon;

  /// One short sentence: the idea of the element.
  final String ar;
  final String en;

  /// Optional "how to use" steps — only when the element does more than a
  /// plain tap. Keep 1–3 very short steps.
  final List<String> arHow;
  final List<String> enHow;

  /// Card title. Defaults to the label the user actually sees.
  final String? arTitle;
  final String? enTitle;

  const HelpEntry({
    required this.id,
    this.keys = const [],
    this.texts = const [],
    this.icons = const [],
    this.ids = const [],
    this.scopes = const [],
    this.row = false,
    required this.icon,
    required this.ar,
    required this.en,
    this.arHow = const [],
    this.enHow = const [],
    this.arTitle,
    this.enTitle,
  });

  bool get isScoped => scopes.isNotEmpty;

  /// Whether this entry applies on [path] (query already stripped).
  bool appliesTo(String path) {
    if (scopes.isEmpty) return true;
    for (final s in scopes) {
      if (s == '/') {
        if (path == '/') return true;
        continue;
      }
      if (path == s || path.startsWith(s.endsWith('/') ? s : '$s/')) {
        return true;
      }
    }
    return false;
  }
}
