import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/auth/presentation/auth_forced_dark.dart';

class _Probe extends StatelessWidget {
  const _Probe(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Text('$label:${b.name}:${AppColors.isLightMode ? 'L' : 'D'}'),
    );
  }
}

void main() {
  tearDown(() => AppColors.setLightMode(false));

  test('effective mode: sign-in routes forced dark, others follow the user', () {
    for (final p in [
      RouteNames.login,
      RouteNames.register,
      RouteNames.verifyEmail,
      RouteNames.forgotPassword,
    ]) {
      expect(AuthForcedDark.effectiveMode(ThemeMode.light, p), ThemeMode.dark, reason: p);
    }
    expect(AuthForcedDark.effectiveMode(ThemeMode.light, '/dashboard'), ThemeMode.light);
    expect(AuthForcedDark.effectiveMode(ThemeMode.light, RouteNames.reentry), ThemeMode.light);
    expect(AuthForcedDark.effectiveMode(ThemeMode.dark, '/dashboard'), ThemeMode.dark);
  });

  testWidgets('login renders dark under a light preference; leaving restores light',
      (tester) async {
    final router = GoRouter(
      initialLocation: RouteNames.login,
      routes: [
        GoRoute(path: RouteNames.login, builder: (_, _) => const _Probe('login')),
        GoRoute(path: '/home', builder: (_, _) => const _Probe('home')),
      ],
    );
    const userMode = ThemeMode.light; // the saved preference — never changed
    await tester.pumpWidget(ValueListenableBuilder<bool>(
      valueListenable: AuthForcedDark.listenable(router),
      builder: (_, forceDark, _) {
        final mode = forceDark ? ThemeMode.dark : userMode;
        AppColors.setLightMode(mode == ThemeMode.light);
        return MaterialApp.router(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: mode,
          routerConfig: router,
        );
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('login:dark:D'), findsOneWidget);

    router.go('/home');
    await tester.pumpAndSettle();
    expect(find.text('home:light:L'), findsOneWidget);

    router.go(RouteNames.login);
    await tester.pumpAndSettle();
    expect(find.text('login:dark:D'), findsOneWidget);
  });
}
