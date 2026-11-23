import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fyona_flutter/core/localization/app_localizations.dart';

/// Shared widget-test helpers (repo-wide fix for the FakeAsync wall).
///
/// Background: `testWidgets` runs inside FakeAsync, where real I/O never
/// completes — so `rootBundle` ARB loading hangs forever and any tree under
/// localization delegates never mounts (no error, just an empty tree).
/// [ensureTestLocalization] preloads the ARB table with REAL async I/O in
/// `setUpAll` (outside FakeAsync); every delegate `load()` afterwards
/// completes via microtask and trees mount normally.
///
/// Usage in any future widget test:
/// ```dart
/// setUpAll(() => ensureTestLocalization()); // 'ar' by default
///
/// testWidgets('...', (tester) async {
///   await pumpLocalizedWidget(tester, MyWidget(), overrides: [...]);
///   ...
/// });
/// ```


/// Preloads the localization table. MUST be called from `setUpAll` (real
/// async), never from inside a `testWidgets` body (FakeAsync).
Future<void> ensureTestLocalization([String languageCode = 'ar']) {
  // Plain `test()` files have no binding yet; without it rootBundle throws
  // and preload silently keeps raw keys.
  TestWidgetsFlutterBinding.ensureInitialized();
  return AppLocalizations.preload(languageCode);
}

/// Pumps [widget] with the app locale/delegates plus optional Riverpod
/// overrides, wrapped in Scaffold (many widgets need a Scaffold ancestor).
Future<void> pumpLocalizedWidget(
  WidgetTester tester,
  Widget widget, {
  List<Override> overrides = const [],
  Locale locale = const Locale('ar'),
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: widget),
      ),
    ),
  );
}
