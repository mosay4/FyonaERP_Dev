import '../../../../core/help/help_content.dart';

/// Live screen catalog streamed to Sara with every query: every route the
/// installed app ships, with a bilingual title + summary. This is what lets
/// Sara know (and open) screens added in newer app versions without any
/// backend update — the app itself is the source of truth for its sections.
class SaraScreenCatalog {
  SaraScreenCatalog._();

  static List<Map<String, String>> entries({required bool arabic}) {
    final out = HelpContent.catalog(arabic: arabic);
    final seen = out.map((e) => e['route'] ?? '').toSet();
    for (final extra in (arabic ? _extrasAr : _extrasEn)) {
      if (seen.add(extra['route']!)) out.add(extra);
    }
    return out;
  }

  /// Resolves a mentioned screen title to its route — the fallback used when
  /// an assistant action names a screen without an explicit route.
  /// Case-insensitive; exact matches prefer the personal section when the
  /// same title exists in both modes (e.g. البنوك).
  static String? routeForTitle(String title, {required bool arabic}) {
    final t = title.trim().toLowerCase();
    if (t.isEmpty) return null;
    final all = entries(arabic: arabic);
    final exact = all
        .where((e) => (e['title'] ?? '').trim().toLowerCase() == t)
        .toList();
    if (exact.isNotEmpty) {
      final personal = exact.firstWhere(
        (e) => (e['route'] ?? '').startsWith('/personal'),
        orElse: () => exact.first,
      );
      return personal['route'];
    }
    for (final e in all.reversed) {
      final label = (e['title'] ?? '').trim().toLowerCase();
      if (label.isEmpty) continue;
      if (t.contains(label) || label.contains(t)) {
        return e['route'];
      }
    }
    return null;
  }

  static const List<Map<String, String>> _extrasAr = [
    {
      'route': '/reentry',
      'title': 'إعادة الدخول',
      'summary': 'تأكيد الهوية قبل استئناف الجلسة.',
    },
    {
      'route': '/mfa/setup',
      'title': 'تفعيل التحقق بخطوتين',
      'summary': 'حماية الحساب بخطوة تحقق إضافية.',
    },
    {
      'route': '/mfa/verify',
      'title': 'رمز التحقق',
      'summary': 'إدخال رمز التحقق لإتمام الدخول.',
    },
  ];

  static const List<Map<String, String>> _extrasEn = [
    {
      'route': '/reentry',
      'title': 'Re-entry',
      'summary': 'Confirm your identity before resuming the session.',
    },
    {
      'route': '/mfa/setup',
      'title': 'Set up 2FA',
      'summary': 'Protect your account with an extra verification step.',
    },
    {
      'route': '/mfa/verify',
      'title': 'Verification code',
      'summary': 'Enter the verification code to finish signing in.',
    },
  ];
}
