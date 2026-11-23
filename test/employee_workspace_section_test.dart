import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/router/role_config.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employer_workspace_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_profile_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/home_header.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/employee_avatar.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/features/profile/presentation/providers/section_profile_provider.dart';
import 'package:fyona_flutter/features/subscription/domain/section_access.dart';
import 'package:fyona_flutter/features/suggestions/di/suggestions_providers.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:fyona_flutter/shared/widgets/app_drawer.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'employee_employment_test.dart' as employment;

const user = UserModel(
  id: 'self',
  role: 'owner',
  fullName: 'Account Name',
  organizationId: 'own',
  preferredUsageMode: 'personal',
);
final companies = <Map<String, dynamic>>[
  {
    'organization_id': 'merchant',
    'organization_name': 'Merchant Store',
    'role': 'member',
    'all_branches': false,
    'branches': [
      {'id': 'm1', 'name': 'Merchant First'},
      {'id': 'm2', 'name': 'Merchant Second'},
    ],
  },
  {
    'organization_id': 'own',
    'organization_name': 'Own Company',
    'role': 'owner',
    'all_branches': true,
    'branches': [
      {'id': 'o1', 'name': 'Own First'},
      {'id': 'o2', 'name': 'Own Second'},
    ],
  },
  {
    'organization_id': 'full',
    'organization_name': 'Full Merchant',
    'role': 'member',
    'all_branches': true,
    'branches': [
      {'id': 'f1', 'name': 'Full First'},
      {'id': 'f2', 'name': 'Full Second'},
    ],
  },
];

class CapturingBranches extends BranchApi {
  CapturingBranches() : super(ApiClient(dio: Dio()));
  final selections = <Map<String, dynamic>>[];
  @override
  Future<void> selectFromDrawer({
    required String organizationId,
    required String? branchId,
    required bool all,
    required bool connected,
  }) async {
    await select(organizationId: organizationId, branchId: branchId, all: all);
  }

  @override
  Future<Map<String, dynamic>> select({
    String? branchId,
    bool all = false,
    String? organizationId,
  }) async {
    selections.add({
      'branchId': branchId,
      'all': all,
      'organizationId': organizationId,
    });
    await BranchScope.save(
      token: 'selected',
      branchId: branchId,
      branchName: branchId,
      allMode: all,
      organizationId: organizationId,
    );
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    employment.translations = AppLocalizations(const Locale('ar'));
    await employment.translations.load();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BranchScope.clear();
  });
  tearDown(() async => BranchScope.clear());

  for (final salary in [0, 2500]) {
    testWidgets('employee identity gradient card with salary $salary', (
      tester,
    ) async {
      // Existing preference sections trigger this SDK ink diagnostic; keep
      // unrelated section styling out of this identity-card regression test.
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().startsWith(
          'ListTile background color or ink splashes may be invisible.',
        )) {
          return;
        }
        originalOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalOnError);
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      BranchScope.organizationId = 'merchant';
      final name = salary > 0
          ? 'اسم موظف طويل للغاية لاختبار بطاقة الهوية دون تجاوز حدود الشاشة'
          : 'اسم الموظف';
      final code = salary > 0 ? 'EMP-123456789012345678901234567890' : 'EMP-42';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeSectionProvider.overrideWith((ref) => AppSection.business),
            myEmployeeProfileForProvider('merchant').overrideWith(
              (ref) async => {
                'employee': {
                  'full_name': name,
                  'employee_code': code,
                  'phone': '777123456',
                  'salary': salary,
                  'salary_currency': 'SAR',
                },
                'organization': {'name': 'متجر الموظف'},
              },
            ),
            myEmployeeProfileProvider.overrideWith(
              (ref) => throw StateError('Must use org profile'),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: const [employment.TestLocalizations()],
            home: const EmployeeProfilePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(name), findsOneWidget);
      expect(find.text('777123456'), findsOneWidget);
      final card = find.byWidgetPredicate((widget) {
        if (widget is! Container) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.gradient is LinearGradient &&
            (decoration.gradient! as LinearGradient).colors.first ==
                const Color(0xFFC01838);
      });
      expect(card, findsOneWidget);
      final gradient =
          (tester.widget<Container>(card).decoration! as BoxDecoration)
                  .gradient!
              as LinearGradient;
      expect(gradient.begin, Alignment.topLeft);
      expect(gradient.end, Alignment.bottomRight);
      expect(gradient.colors, const [
        Color(0xFFC01838),
        AppColors.primary,
        Color(0xFF8A1028),
      ]);
      expect(
        tester.widget<EmployeeAvatar>(find.byType(EmployeeAvatar)).size,
        88,
      );
      expect(
        find.text(fmtNum(salary)),
        salary > 0 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  group('effective section route', () {
    for (final mode in <String?>['personal', 'business', 'both', null]) {
      test('explicit routes override preferred mode $mode', () {
        for (final route in [
          '/dashboard',
          '/sales',
          '/sales/view',
          '/employee-profile',
          '/employee-profile/details',
          '/job-requests',
          '/job-requests/details',
        ]) {
          expect(isPersonalSectionRoute(route, mode), isFalse, reason: route);
        }
        for (final route in ['/personal', '/personal/transactions']) {
          expect(isPersonalSectionRoute(route, mode), isTrue, reason: route);
        }
      });

      test('shared routes fall back to preferred mode $mode', () {
        for (final route in ['/notifications', '/subscription']) {
          expect(
            isPersonalSectionRoute(route, mode),
            mode == 'personal',
            reason: route,
          );
        }
      });
    }
  });

  test(
    'granted staff and personal membership opens business routes only while linked',
    () {
      for (final role in [
        'staff',
        'personal',
        'employee',
        'admin',
        'accountant',
        'viewer',
      ]) {
        BranchScope.hasMembership = false;
        expect(isRouteAllowed('/sales', role), isFalse);
        expect(isRouteAllowed('/dashboard', role), isFalse);
        BranchScope.hasMembership = true;
        expect(isRouteAllowed('/sales', role), isTrue);
        expect(isRouteAllowed('/dashboard', role), isTrue);
      }
      BranchScope.hasMembership = false;
      for (final route in [
        '/job-requests',
        '/employee-profile',
        '/employees/salary',
        '/employees/debts',
      ]) {
        expect(isRouteAllowed(route, 'staff'), isTrue);
      }
    },
  );

  test('invited workspace skips only the merchant business section gate', () {
    bool allowed({
      String? section = 'business',
      bool setup = false,
      String? workspace = 'merchant',
      bool membership = true,
    }) => shouldUseInvitedWorkspaceAccess(
      section: section,
      isSetupRoute: setup,
      workspaceOrganizationId: workspace,
      userOrganizationId: user.organizationId,
      hasMembership: membership,
    );

    expect(allowed(), isTrue);
    expect(allowed(workspace: 'own'), isFalse);
    expect(allowed(workspace: null), isFalse);
    expect(allowed(membership: false), isFalse);
    expect(allowed(setup: true), isFalse);
    expect(allowed(section: 'personal'), isFalse);
    expect(allowed(section: null), isFalse);
  });

  test('raw role normalization preserves owner modes and unknown keys', () {
    expect(isRouteAllowed('/sales', 'owner'), isTrue);
    expect(
      isRouteAllowed('/sales', 'owner', preferredUsageMode: 'personal'),
      isFalse,
    );
    expect(
      isRouteAllowed('/personal', 'owner', preferredUsageMode: 'personal'),
      isTrue,
    );
    expect(
      isRouteAllowed('/sales', 'owner', preferredUsageMode: 'both'),
      isTrue,
    );
    expect(
      isRouteAllowed('/personal', 'owner', preferredUsageMode: 'both'),
      isTrue,
    );
    BranchScope.hasMembership = true;
    expect(isRouteAllowed('/sales', 'unknown'), isFalse);
  });

  Future<GoRouter> drawerHost(
    WidgetTester tester, {
    String route = '/dashboard',
    List<Map<String, dynamic>>? workspaces,
    CapturingBranches? branchApi,
    Future<Map<String, dynamic>>? employeeProfile,
    UserModel drawerUser = user,
  }) async {
    final router = GoRouter(
      initialLocation: route,
      routes: [
        for (final path in ['/dashboard', '/personal'])
          GoRoute(
            path: path,
            builder: (context, state) => Scaffold(
              appBar: AppBar(),
              drawer: AppDrawer(user: drawerUser, currentRoute: state.uri.path),
            ),
          ),
        GoRoute(
          path: '/employee-profile',
          builder: (_, _) => const Scaffold(body: Text('Employee destination')),
        ),
        GoRoute(
          path: '/profile',
          builder: (_, _) => const Scaffold(body: Text('Normal destination')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(drawerUser),
          if (branchApi != null) branchApiProvider.overrideWithValue(branchApi),
          businessAccountsProvider.overrideWith((ref) async => []),
          businessRecentProvider.overrideWith((ref) async => []),
          activeSectionProvider.overrideWith((ref) => AppSection.personal),
          branchAccessProvider.overrideWith(
            (ref) async => workspaces ?? companies,
          ),
          subscriptionStatusProvider.overrideWith((ref) async => {}),
          myInvitationsProvider.overrideWith((ref) async => []),
          suggestionUnreadCountProvider.overrideWith((ref) async => 0),
          myEmployeeProfileForProvider('merchant').overrideWith(
            (ref) async =>
                employeeProfile ??
                Future.value({
                  'employee': {
                    'full_name': 'Employee HR Name',
                    'photo_url': '/hr-photo.png',
                  },
                }),
          ),
          myEmployeeProfileProvider.overrideWith(
            (ref) => throw StateError('Must use org profile'),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [employment.TestLocalizations()],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets(
    'employee drawer header uses app logo and current branch, not HR identity',
    (tester) async {
      BranchScope.organizationId = 'merchant';
      BranchScope.branchId = 'm1';
      await drawerHost(tester);
      expect(find.text('Employee HR Name'), findsNothing);
      expect(find.text('Merchant First'), findsOneWidget);
      expect(find.text(employment.translations.translate('activateSubscription')), findsNothing);
      expect(find.byKey(const ValueKey('drawer-app-logo')), findsOneWidget);
      final photo = find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is NetworkImage &&
            (w.image as NetworkImage).url.endsWith('/hr-photo.png'),
      );
      expect(photo, findsNothing);
    },
  );

  testWidgets('loading employee profile keeps a visible branch header', (
    tester,
  ) async {
    BranchScope.organizationId = 'merchant';
    BranchScope.branchId = 'm1';
    final profile = Completer<Map<String, dynamic>>();
    await drawerHost(tester, employeeProfile: profile.future);
    expect(find.text('Merchant First'), findsOneWidget);
    expect(find.text('Merchant Store • Merchant First'), findsNothing);
    profile.complete({
      'employee': {'full_name': 'Loaded Employee'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Loaded Employee'), findsNothing);
    expect(find.text('Merchant First'), findsOneWidget);
  });

  for (final employee in <Map<String, dynamic>>[
    {},
    {'full_name': '   '},
  ]) {
    testWidgets('empty employee name $employee keeps branch header', (
      tester,
    ) async {
      BranchScope.organizationId = 'merchant';
      BranchScope.branchId = 'm1';
      await drawerHost(
        tester,
        employeeProfile: Future.value({'employee': employee}),
      );
      expect(find.text('Merchant First'), findsOneWidget);
      expect(find.text('Merchant Store • Merchant First'), findsNothing);
    });
  }

  testWidgets(
    'personal drawer restores account identity despite selected merchant',
    (tester) async {
      BranchScope.organizationId = 'merchant';
      await drawerHost(tester, route: '/personal');
      expect(find.text('Employee HR Name'), findsNothing);
      expect(find.text('Account Name'), findsOneWidget);
      expect(find.text(employment.translations.translate('activateSubscription')), findsOneWidget);
      expect(find.byKey(const ValueKey('drawer-app-logo')), findsOneWidget);
    },
  );

  testWidgets('owner header keeps branch identity and not employee profile', (
    tester,
  ) async {
    BranchScope.organizationId = 'own';
    BranchScope.branchId = 'o1';
    await drawerHost(tester);
    expect(find.text('Own First'), findsOneWidget);
    expect(find.text(employment.translations.translate('activateSubscription')), findsOneWidget);
    expect(find.text('Employee HR Name'), findsNothing);
  });

  testWidgets('open personal drawer updates name and avatar without remounting', (tester) async {
    BranchScope.organizationId = 'merchant';
    await drawerHost(tester, route: '/personal');
    final element = tester.element(find.byType(AppDrawer));
    final container = ProviderScope.containerOf(element);
    final identity = container.read(sectionProfileProvider.notifier);
    await identity.setName('Live Personal Name');
    final bytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XcAAAAASUVORK5CYII=');
    await tester.runAsync(() => identity.setAvatarAll(bytes));
    await tester.pumpAndSettle();
    expect(find.text('Live Personal Name'), findsOneWidget);
    expect(find.text('Account Name'), findsNothing);
    expect(find.text('Employee HR Name'), findsNothing);
    final avatar = find.descendant(of: find.byType(AppDrawer), matching:
      find.byWidgetPredicate((widget) => widget is Image && widget.image is MemoryImage));
    expect(avatar, findsOneWidget);
    expect((tester.widget<Image>(avatar).image as MemoryImage).bytes, bytes);
    expect(tester.element(find.byType(AppDrawer)), same(element));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'workspace menu groups own first and offers all only per allowed company',
    (tester) async {
      BranchScope.organizationId = 'merchant';
      BranchScope.branchId = 'm1';
      await drawerHost(tester);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded).first);
      await tester.pumpAndSettle();
      final rows = tester
          .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
          .toList();
      expect(rows.where((r) => r.value == 'own|__all__'), hasLength(1));
      expect(rows.where((r) => r.value == 'full|__all__'), hasLength(1));
      expect(rows.where((r) => r.value == 'merchant|__all__'), hasLength(1));
      expect(
        rows.indexWhere((r) => r.value == 'own|o1'),
        lessThan(rows.indexWhere((r) => r.value == 'merchant|m1')),
      );
      expect(find.text('الفروع حقك'), findsOneWidget);
      expect(find.text('الفروع حق التجار'), findsOneWidget);
      expect(rows.where((r) => r.value == '__personal__'), isEmpty);
    },
  );

  testWidgets('workspace grouping follows own organization rather than roles', (
    tester,
  ) async {
    BranchScope.organizationId = 'merchant';
    BranchScope.branchId = 'm1';
    await drawerHost(
      tester,
      workspaces: [
        {...companies[0], 'role': 'owner'},
        {...companies[1], 'role': 'member'},
      ],
    );
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded).first);
    await tester.pumpAndSettle();
    final rows = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .toList();
    final ownHeader = rows.indexWhere(
      (row) => row.child is Text && (row.child as Text).data == 'الفروع حقك',
    );
    final merchantHeader = rows.indexWhere(
      (row) =>
          row.child is Text && (row.child as Text).data == 'الفروع حق التجار',
    );
    final ownBranch = rows.indexWhere((row) => row.value == 'own|o1');
    final merchantBranch = rows.indexWhere((row) => row.value == 'merchant|m1');
    expect(ownHeader, greaterThanOrEqualTo(0));
    expect(rows.where((r) => r.value == '__personal__'), isEmpty);
    expect(ownBranch, greaterThan(ownHeader));
    expect(ownBranch, lessThan(merchantHeader));
    expect(merchantBranch, greaterThan(merchantHeader));
    final selectedRow = find.byWidgetPredicate(
      (w) => w is PopupMenuItem<String> && w.value == 'merchant|m1',
    );
    expect(
      find.descendant(
        of: selectedRow,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    final ownRow = find.byWidgetPredicate(
      (w) => w is PopupMenuItem<String> && w.value == 'own|o1',
    );
    expect(
      find.descendant(
        of: ownRow,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('personal circle excludes synthetic own branch with merchants', (tester) async {
    await drawerHost(tester, route: '/personal', workspaces: [
      {...companies[1], 'branches': <Map<String, dynamic>>[]}, companies[0],
    ]);
    expect(find.byKey(const ValueKey('drawer-app-logo')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem<String> && w.value == 'own|__main__'), findsNothing);
    expect(find.text('الفروع حقك'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem<String> && w.value == 'merchant|m1'), findsOneWidget);
    expect(find.text('الحساب الشخصي'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('personal circle exposes only member merchant branches', (tester) async {
    await drawerHost(tester, route: '/personal', workspaces: [
      ...companies,
      {...companies[0], 'organization_id': 'not-member', 'role': 'owner'},
    ]);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pumpAndSettle();
    final values = tester.widgetList<PopupMenuItem<String>>(
      find.byType(PopupMenuItem<String>),
    ).map((row) => row.value).whereType<String>();
    expect(values, contains('merchant|m1'));
    expect(values, contains('full|f1'));
    expect(values.any((value) => value.startsWith('own|')), isFalse);
    expect(values.any((value) => value.startsWith('not-member|')), isFalse);
    expect(find.text('الفروع حقك'), findsNothing);
  });

  testWidgets('empty own organization without merchants has no switch arrow', (tester) async {
    await drawerHost(tester, route: '/personal', workspaces: [
      {...companies[1], 'branches': <Map<String, dynamic>>[]},
    ]);
    expect(find.byKey(const ValueKey('drawer-app-logo')), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single workspace and branch keeps circle without switch arrow', (
    tester,
  ) async {
    BranchScope.organizationId = 'own';
    BranchScope.branchId = 'o1';
    await drawerHost(
      tester,
      workspaces: [
        {
          ...companies[1],
          'branches': [
            {'id': 'o1', 'name': 'Own First'},
          ],
        },
      ],
    );
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  for (final drawerUser in [
    user,
    const UserModel(
      id: 'personal-employee',
      role: 'personal',
      fullName: 'Personal Employee',
      preferredUsageMode: 'personal',
    ),
  ]) {
    testWidgets(
      'single merchant branch has no personal account entry for ${drawerUser.role}',
      (tester) async {
        await BranchScope.save(
          token: 'merchant-token',
          branchId: 'm1',
          branchName: 'Merchant First',
          allMode: false,
          organizationId: 'merchant',
        );
        await BranchScope.setHasMembership(true);
        await drawerHost(
          tester,
          drawerUser: drawerUser,
          workspaces: [
            {
              ...companies[0],
              'branches': [
                {'id': 'm1', 'name': 'Merchant First'},
              ],
            },
          ],
        );
        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
        await tester.pumpAndSettle();
        final rows = tester
            .widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>),
            )
            .toList();
        expect(rows.where((r) => r.value == '__personal__'), isEmpty);
        expect(rows.where((r) => r.value == 'merchant|__all__'), isEmpty);
        expect(find.text('الحساب الشخصي'), findsNothing);
        expect(find.text('العودة لحسابك الخاص'), findsNothing);
      },
    );
  }

  testWidgets(
    'own company all selection passes own org and returns to dashboard',
    (tester) async {
      BranchScope.organizationId = 'merchant';
      BranchScope.branchId = 'm1';
      final api = CapturingBranches();
      await drawerHost(tester, branchApi: api);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded).first);
      await tester.pumpAndSettle();
      final ownAll = find.byWidgetPredicate(
        (w) => w is PopupMenuItem<String> && w.value == 'own|__all__',
      );
      await tester.ensureVisible(ownAll);
      await tester.tap(ownAll);
      await tester.pumpAndSettle();
      expect(api.selections, [
        {'branchId': null, 'all': true, 'organizationId': 'own'},
      ]);
      expect(BranchScope.organizationId, 'own');
      expect(BranchScope.allMode, isTrue);
      expect(find.byType(AppDrawer), findsNothing);
    },
  );

  testWidgets(
    'merchant selection from personal sets business section and dashboard',
    (tester) async {
      final api = CapturingBranches();
      final router = await drawerHost(
        tester,
        route: '/personal',
        branchApi: api,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppDrawer)),
      );
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded).first);
      await tester.pumpAndSettle();
      final merchant = find.byWidgetPredicate(
        (w) => w is PopupMenuItem<String> && w.value == 'merchant|m1',
      );
      await tester.ensureVisible(merchant);
      await tester.tap(merchant);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/dashboard');
      expect(container.read(activeSectionProvider), AppSection.business);
      expect(BranchScope.organizationId, 'merchant');
      expect(BranchScope.hasMembership, isTrue);
      expect(api.selections, [
        {'branchId': 'm1', 'all': false, 'organizationId': 'merchant'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home avatar restores normal identity on personal and own business routes',
    (tester) async {
      BranchScope.organizationId = 'merchant';
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(user),
          activeSectionProvider.overrideWith((ref) => AppSection.personal),
          branchAccessProvider.overrideWith((ref) async => companies),
          myEmployeeProfileForProvider('merchant').overrideWith(
            (ref) async => {
              'employee': {
                'full_name': 'Employee HR Name',
                'photo_url': '/hr-photo.png',
              },
            },
          ),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/dashboard',
        routes: [
          for (final path in ['/dashboard', '/personal'])
            GoRoute(
              path: path,
              builder: (_, _) => const Scaffold(body: HomeProfileAvatar()),
            ),
          GoRoute(
            path: '/employee-profile',
            builder: (_, _) =>
                const Scaffold(body: Text('Employee destination')),
          ),
          GoRoute(
            path: '/profile',
            builder: (_, _) => const Scaffold(body: Text('Normal destination')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<EmployeeAvatar>(find.byType(EmployeeAvatar)).photo,
        '/hr-photo.png',
      );
      await tester.tap(find.byType(HomeProfileAvatar));
      await tester.pumpAndSettle();
      expect(find.text('Employee destination'), findsOneWidget);
      router.go('/personal');
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeAvatar), findsNothing);
      await tester.tap(find.byType(HomeProfileAvatar));
      await tester.pumpAndSettle();
      expect(find.text('Normal destination'), findsOneWidget);
      BranchScope.organizationId = 'own';
      container.read(branchEpochProvider.notifier).state++;
      router.go('/dashboard');
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeAvatar), findsNothing);
      await tester.tap(find.byType(HomeProfileAvatar));
      await tester.pumpAndSettle();
      expect(find.text('Normal destination'), findsOneWidget);
    },
  );

  for (final limited in [false, true]) {
    testWidgets(
      'enter accepted store selects authorized scope limited=$limited',
      (tester) async {
        final api = CapturingBranches();
        final container = ProviderContainer(
          overrides: [
            branchApiProvider.overrideWithValue(api),
            branchAccessProvider.overrideWith((ref) async => []),
          ],
        );
        addTearDown(container.dispose);
        final router = GoRouter(
          initialLocation: '/store',
          routes: [
            GoRoute(
              path: '/store',
              builder: (_, _) => EmployerWorkspacePage(
                invitation: {
                  'organization': {'id': 'merchant', 'name': 'Merchant'},
                  'employee': {'id': 'employee'},
                  'branch_ids': limited ? ['m1', 'm2'] : null,
                  'branches': [
                    {'id': 'm1'},
                    {'id': 'm2'},
                  ],
                },
              ),
            ),
            GoRoute(
              path: '/dashboard',
              builder: (_, _) =>
                  const Scaffold(body: Text('Business destination')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('الدخول إلى المتجر'));
        await tester.tap(find.text('الدخول إلى المتجر'));
        await tester.pumpAndSettle();
        expect(api.selections, [
          {'branchId': 'm1', 'all': false, 'organizationId': 'merchant'},
        ]);
        expect(BranchScope.organizationId, 'merchant');
        expect(BranchScope.hasMembership, isTrue);
        expect(container.read(branchEpochProvider), 1);
        expect(find.text('Business destination'), findsOneWidget);
      },
    );
  }
}
