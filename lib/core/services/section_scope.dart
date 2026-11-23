import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two completely separate sections whose preferences are isolated.
enum AppSection { personal, business }

/// Maps the current usage mode to its section. Anything that is not explicitly
/// 'personal' is treated as the Business section (matches the router/shell).
AppSection sectionFromMode(String? mode) =>
    mode == 'personal' ? AppSection.personal : AppSection.business;

/// Which section is ACTIVE right now. Kept as a LIGHT StateProvider updated by
/// the app when the auth/usage mode changes, so preference providers (theme,
/// language, help clicker, money format, section profile) do NOT force the
/// heavy auth provider to initialize just to know the section. Switching usage
/// mode re-evaluates it and every section-scoped preference re-applies.
final activeSectionProvider =
    StateProvider<AppSection>((ref) => AppSection.business);

/// Account-scoped section history, independent of server profile refreshes.
class SectionHistory {
  static Future<void> save(String userId, String section) async {
    if (userId.isEmpty || !{'personal', 'business'}.contains(section)) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('last_section_$userId') != section) {
      await prefs.setString('last_section_$userId', section);
    }
  }

  static Future<String> restore(String userId,
      {required bool business, required bool personal}) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('last_section_$userId');
    if (last == 'personal' && personal) return 'personal';
    if (last == 'business' && business) return 'business';
    return business ? 'business' : 'personal';
  }
}
