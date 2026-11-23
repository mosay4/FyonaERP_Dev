import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/providers/locale_provider.dart';
import 'package:fyona_flutter/shared/widgets/language_transition_overlay.dart';

import 'test_utils.dart';

/// Language-switch globe transition: arming, globe card, locale apply,
/// auto-clear — without touching any other subsystem.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ensureTestLocalization('ar');
    await ensureTestLocalization('en');
    setInitialLocale('ar');
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('request arms once, ignores repeats and same-locale',
      (tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (_, r, __) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(ref.read(languageTransitionProvider), isNull);
    await requestLanguageChange(ref, const Locale('en'));
    expect(ref.read(languageTransitionProvider)?.languageCode, 'en');

    // A second request mid-flight is ignored.
    await requestLanguageChange(ref, const Locale('ar'));
    expect(ref.read(languageTransitionProvider)?.languageCode, 'en');

    ref.read(languageTransitionProvider.notifier).state = null;
    // Same locale as current: no-op.
    await requestLanguageChange(ref, const Locale('ar'));
    expect(ref.read(languageTransitionProvider), isNull);
  });

  testWidgets('globe card appears, applies the locale, then clears',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const Scaffold(
            body: LanguageTransitionOverlay(child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('lang_transition_card')), findsNothing);

    final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold)));
    container.read(languageTransitionProvider.notifier).state =
        const Locale('en');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Globe card with spinning earth is on stage.
    expect(find.byKey(const ValueKey('lang_transition_card')), findsOneWidget);
    expect(find.byKey(const ValueKey('lang_globe')), findsOneWidget);

    // Past the midpoint the new locale is applied...
    await tester.pump(const Duration(milliseconds: 900));
    expect(container.read(localeProvider).languageCode, 'en');

    // ...and when the show ends the overlay clears itself.
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lang_transition_card')), findsNothing);
    expect(container.read(languageTransitionProvider), isNull);
  });
}
