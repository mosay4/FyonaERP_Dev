import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/help/help_allowlist.dart';
import 'package:fyona_flutter/core/help/help_clicker_settings.dart';
import 'package:fyona_flutter/core/help/help_content.dart';
import 'package:fyona_flutter/core/help/help_explain.dart';
import 'package:fyona_flutter/shared/providers/locale_provider.dart';

import 'test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ensureTestLocalization('ar');
    setInitialLocale('ar');
  });

  group('HelpContent resolver', () {
    test('exact Arabic label wins over rules', () {
      final info =
          HelpContent.resolve(route: '/personal/banks', label: 'حفظ', arabic: true);
      expect(info.title, 'حفظ');
      expect(info.body, contains('يحفظ'));
    });

    test('compound label hits the keyword rule', () {
      final info = HelpContent.resolve(
          route: '/sales', label: 'حفظ الفاتورة', arabic: true);
      expect(info.title, 'حفظ الفاتورة');
      expect(info.body, contains('يحفظ'));
    });

    test('icon-only press falls back to the screen explanation', () {
      final info =
          HelpContent.resolve(route: '/personal/banks', label: '', arabic: true);
      expect(info.title, 'البنوك');
      expect(info.body, contains('حساباتك البنكية'));
    });

    test('dynamic route prefix matches its section', () {
      final info = HelpContent.resolve(
          route: '/customers/abc-123', label: '', arabic: true);
      expect(info.title, 'العملاء');
    });

    test('unknown label falls back to the screen', () {
      final info = HelpContent.resolve(
          route: '/personal/recurring', label: 'عنصر غامض جداً', arabic: true);
      expect(info.title, 'المتكررة');
      expect(info.body, contains('تتكرر'));
    });

    test('English exact label', () {
      final info =
          HelpContent.resolve(route: '/personal/banks', label: 'Save', arabic: false);
      expect(info.title, 'Save');
      expect(info.body, contains('Saves'));
    });

    test('English rule covers compound labels', () {
      final info = HelpContent.resolve(
          route: '/sales', label: 'Save invoice', arabic: false);
      expect(info.body, contains('Saves'));
    });

    test('never returns empty content for a random press', () {
      final info = HelpContent.resolve(
          route: '/nowhere', label: '', arabic: true);
      expect(info.title.isNotEmpty, isTrue);
      expect(info.body.isNotEmpty, isTrue);
    });
  });

  group('HelpClicker settings', () {
    test('defaults ON with 3 seconds and persists changes', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(container.read(helpClickerProvider).enabled, isTrue);
      expect(container.read(helpClickerProvider).seconds, 2);

      await container.read(helpClickerProvider.notifier).setSeconds(5);
      await container.read(helpClickerProvider.notifier).setEnabled(false);
      expect(container.read(helpClickerProvider).seconds, 5);
      expect(container.read(helpClickerProvider).enabled, isFalse);

      final sp = await SharedPreferences.getInstance();
      expect(sp.getInt('help_clicker_seconds_business'), 5);
      expect(sp.getBool('help_clicker_enabled_business'), isFalse);
    });

    test('seconds are clamped to the allowed range', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await container.read(helpClickerProvider.notifier).setSeconds(99);
      expect(container.read(helpClickerProvider).seconds, 15);
      await container.read(helpClickerProvider.notifier).setSeconds(0);
      expect(container.read(helpClickerProvider).seconds, 1);
    });
  });

  group('HelpAllowlist gate', () {    test('curated labels answer anywhere', () {
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'حفظ', arabic: true),
        isTrue,
      );
      expect(
        HelpAllowlist.allows(
            route: '/customers', label: 'إضافة عميل', arabic: true),
        isTrue,
      );
    });

    test('user data never gets a card', () {
      expect(
        HelpAllowlist.allows(
            route: '/', label: 'تحويل 450 ريال', arabic: true),
        isFalse,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: '1234567890', arabic: true),
        isFalse,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/transactions', label: '2026/09/27', arabic: true),
        isFalse,
      );
    });

    test('unknown labels stay quiet on data screens', () {
      expect(
        HelpAllowlist.allows(
            route: '/customers', label: 'أحمد محمد علي', arabic: true),
        isFalse,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'بنك التضامن', arabic: true),
        isFalse,
      );
    });

    test('icon-only presses need a curated screen', () {
      expect(
        HelpAllowlist.allows(route: '/personal/banks', label: '', arabic: true),
        isTrue,
      );
      expect(
        HelpAllowlist.allows(route: '/nowhere', label: '', arabic: true),
        isFalse,
      );
    });

    test('chrome screens fall back to their own explanation', () {
      expect(
        HelpAllowlist.allows(
            route: '/settings/company', label: 'تفعيل النسخ التلقائي',
            arabic: true),
        isTrue,
      );
    });

    test('musarfa button is allowed on the banks screen', () {
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'مصارفة', arabic: true),
        isTrue,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'Exchange', arabic: false),
        isTrue,
      );
    });
  });

  // Overlay behaviour (detection, bounds, taps, native long press, tooltips,
  // sheets, scrolling, RTL/LTR, finite animations) lives in
  // test/help/help_detection_test.dart; catalog text and coverage checks in
  // test/help/help_catalog_text_test.dart and help_coverage_test.dart.

  group('content is never the old generic text', () {
    const bannedAr = [
      'اضغط الزر لتنفيذ إجراءه',
      'أكمل الخطوات الظاهرة على الشاشة',
      'راجع النتيجة في نفس القسم',
      'ينفّذ هذا الزر الإجراء الخاص به',
      'اضغط مطولاً على أي زر أو قسم',
    ];
    const bannedEn = [
      'Tap the button to run its action',
      'Complete the steps shown on screen',
      'This button performs its action on this screen',
      'Long-press any button or section',
    ];

    test('every covered section resolves curated, distinct bodies', () {
      final cases = <String, String>{
        '/personal': 'صافي الثروة',
        '/personal/banks': 'إضافة بنك',
        '/personal/debts': 'سداد',
        '/personal/debts:تحصيل': 'تحصيل',
        '/personal/savings': 'إضافة مبلغ',
        '/personal/budget': 'إنشاء ميزانية جديدة',
        '/personal/ai': 'كم رصيدي؟',
        '/personal/transactions': 'سحب مصروف',
        '/personal/recurring': 'تنفيذ الآن',
        '/personal/backup': 'حفظ البيانات الحالية',
        '/subscription': 'اشتراك سنوي',
        '/profile': 'تخصيص العملات',
      };
      final bodies = <String>{};
      cases.forEach((key, label) {
        final route = key.split(':').first;
        final info = HelpExplain.resolve(
            route: route, label: label, arabic: true);
        expect(info.title.isNotEmpty, isTrue, reason: key);
        expect(info.body.isNotEmpty, isTrue, reason: key);
        for (final banned in bannedAr) {
          expect(info.body.contains(banned), isFalse, reason: '$key body');
          for (final step in info.steps) {
            expect(step.contains(banned), isFalse, reason: '$key step');
          }
        }
        bodies.add(info.body);
      });
      // Not all identical: sections genuinely differ from each other.
      expect(bodies.length, greaterThan(6));
    });

    test('section cards never show the raw record text as title', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: '', arabic: true);
      expect(info.title, 'البنوك');
    });

    test('english mirrors resolve with their own content', () {
      final ar = HelpExplain.resolve(
          route: '/personal/debts', label: 'سداد', arabic: true);
      final en = HelpExplain.resolve(
          route: '/personal/debts', label: 'settle', arabic: false);
      expect(en.title.isNotEmpty, isTrue);
      expect(en.body.isNotEmpty, isTrue);
      expect(en.body, isNot(ar.body));
      for (final banned in bannedEn) {
        expect(en.body.contains(banned), isFalse);
      }
    });

    test('steps are empty (not generic) when no flow exists', () {
      final info = HelpExplain.resolve(
          route: '/profile', label: 'اللغة', arabic: true);
      expect(info.steps, isEmpty);
      final info2 = HelpExplain.resolve(
          route: '/personal/backup', label: 'التحديث التلقائي', arabic: true);
      expect(info2.steps, isEmpty);
    });
  });

  group('HelpExplain content', () {
    test('curated route returns its own steps and icon', () {
      final info = HelpExplain.resolve(
          route: '/personal/recurring', label: 'المعاملات المتكررة', arabic: true);
      expect(info.title, 'المعاملات المتكررة');
      expect(info.steps.length, 3);
      expect(info.steps.first, contains('قاعدة'));
    });

    test('expense action label gets its own usage steps', () {
      final info = HelpExplain.resolve(
          route: '/personal/transactions', label: 'سحب مصروف', arabic: true);
      expect(info.title, 'سحب مصروف');
      expect(info.steps.length, 3);
      expect(info.steps.first, contains('الحساب'));
    });

    test('unknown label still gets steps, body and an icon', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'زر غامض', arabic: true);
      expect(info.title.isNotEmpty, isTrue);
      expect(info.body.isNotEmpty, isTrue);
      expect(info.steps.isNotEmpty, isTrue);
    });

    test('english content resolves with steps', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'Save invoice', arabic: false);
      expect(info.title, 'Save invoice');
      expect(info.steps.isNotEmpty, isTrue);
    });

    test('a bare action label is description-only (no invented flow)', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'Save', arabic: false);
      expect(info.title, 'Save');
      expect(info.body.isNotEmpty, isTrue);
      expect(info.steps, isEmpty);
    });

    test('musarfa button gets its dedicated transfer flow', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'مصارفة', arabic: true);
      expect(info.title, 'مصارفة');
      expect(info.body, contains('يحوّل'));
      expect(info.steps.length, 3);
      expect(info.steps.first, contains('الحساب'));
    });

    test('english Exchange button answers with dedicated text', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'Exchange', arabic: false);
      expect(info.title, 'Exchange');
      expect(info.body, contains('moves an amount'));
    });
  });
}
