import 'dart:ui';

import 'help_content.dart';

/// Decides whether the Information Clicker is allowed to react to a press.
///
/// The clicker draws a border while you hold and then opens an explanation
/// card. Both are gated by this class so the overlay never fires over content
/// it has no curated text for — customer names, account numbers, balances and
/// every other piece of user data must stay quiet.
///
/// A press is allowed when:
///   1. the pressed label is not shaped like user data (digit runs, dates,
///      very long strings), AND
///   2. `HelpContent` has curated text for that label — an exact entry, or a
///      keyword rule whose every word is itself known UI copy (so a bank or
///      customer name never qualifies), OR
///   3. the label is empty (icon-only tap) and the current route has its own
///      curated explanation, so the card shows screen text and not guesswork,
///   4. the label sits on a screen made purely of app chrome, where the card
///      falls back to the route's own curated title/body.
///
/// Otherwise nothing happens at all: no border, no card.
class HelpAllowlist {
  HelpAllowlist._();

  /// Screens built only from application chrome (settings, profile, billing…).
  /// On these a tap may fall back to the route's curated explanation even when
  /// the pressed label itself has no entry. Screens that render user records
  /// (dashboard, banks, transactions, customers, lists…) are deliberately
  /// absent.
  static const Set<String> staticUiRoutes = {
    '/profile',
    '/sessions',
    '/settings',
    '/settings/company',
    '/settings/taxes',
    '/settings/currencies',
    '/settings/customization',
    '/settings/custom-fields',
    '/settings/files',
    '/settings/email-templates',
    '/settings/email-logs',
    '/subscription',
    '/subscription/pay',
    '/subscription/pending',
    '/subscription/rejected',
    '/subscription/update-card',
    '/personal/backup',
    '/personal/analytics',
    '/personal/reports-center',
    '/import',
    '/design-studio',
    '/ai',
    '/ai-suggestions',
    '/personal/ai',
    '/personal/transfer',
    '/personal/account-tree',
    '/onboarding',
    '/choose-usage',
    '/forgot-password',
    '/change-password',
    '/verify-email',
    '/reentry',
    '/login',
    '/register',
  };

  /// Data screens whose big structural cards (bank cards, debt/goal/budget
  /// rows, home cards) are covered with the section's own curated text when
  /// the pressed label itself has no entry. The card NEVER shows the raw
  /// record text as its title — the caller must force route content.
  /// Transaction rows are safe to list: their native long-press wins the
  /// gesture arena first, so the clicker never fires there anyway.
  static const Set<String> cardRoutes = {
    '/',
    '/personal',
    '/personal/banks',
    '/personal/debts',
    '/personal/savings',
    '/personal/budget',
    '/personal/recurring',
    '/personal/transactions',
  };

  static bool allows({
    required String route,
    required String label,
    required bool arabic,
  }) {
    final text = label.trim();
    if (looksLikeUserData(text)) return false;
    if (text.isEmpty) {
      return HelpContent.hasRouteInfo(route);
    }
    if (HelpContent.hasExactLabel(text, arabic: arabic)) return true;
    if (HelpContent.hasRuleMatch(text, arabic: arabic) &&
        HelpContent.isCoveredPhrase(text, arabic: arabic)) {
      return true;
    }
    if (_isStaticUi(route)) return true;
    return false;
  }

  /// A big structural card on a covered route with no curated label of its
  /// own (e.g. a bank card showing only a name + balance): allowed, but the
  /// caller must render the SECTION content instead of the raw label.
  static bool allowsSectionCard({
    required String route,
    required Rect? rect,
  }) {
    if (rect == null) return false;
    if (rect.width < 200 || rect.height < 56) return false;
    final path = route.split('?').first;
    if (path.isEmpty || !cardRoutes.contains(path)) return false;
    return HelpContent.hasRouteInfo(route);
  }

  /// True when [raw] reads as something the user typed rather than as UI copy
  /// — account numbers, amounts, dates, ids, free-form names of any length.
  static bool looksLikeUserData(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return false;
    if (s.length > 30) return true;
    // 1,250 · 123456 · 2018 · 1250.75
    if (RegExp(r'\d{3,}').hasMatch(s)) return true;
    // 12:30 · 2026/09 · 9-5 · 07:45
    if (RegExp(r'\d{1,2}[:/\-]\d{1,2}').hasMatch(s)) return true;
    // A few digits are fine ("خطوة 2"), but a digit-heavy fragment inside a
    // longer string is not UI copy ("تحويل 450 ريال").
    final digits = RegExp(r'\d').allMatches(s).length;
    if (digits >= 2 && digits * 3 >= s.length) return true;
    return false;
  }

  static bool _isStaticUi(String route) {
    final path = route.split('?').first;
    if (path.isEmpty) return false;
    return staticUiRoutes.contains(path);
  }
}
