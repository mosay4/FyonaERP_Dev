import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/profile/presentation/pages/profile_page.dart';

/// «الجلسات والأجهزة» is back in «الأمان والخصوصية» for the account owner in
/// BOTH sections (a session is the whole account).
void main() {
  for (final business in [false, true]) {
    testWidgets('sessions tile in security section business=$business',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = FlutterError.onError;
      FlutterError.onError = (details) {
        if (!details.exceptionAsString().startsWith(
            'ListTile background color or ink splashes may be invisible.')) {
          original?.call(details);
        }
      };
      addTearDown(() => FlutterError.onError = original);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: ProfilePage(business: business),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('الجلسات والأجهزة'), findsOneWidget);
    });
  }
}
