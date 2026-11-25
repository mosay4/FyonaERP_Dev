import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/branches/presentation/widgets/business_branch_chip.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _org = 'org-1';

Map<String, dynamic> _company(List<String> names) => {
      'organization_id': _org,
      'role': 'owner',
      'branches': [
        for (var i = 0; i < names.length; i++) <String, dynamic>{'id': 'b$i', 'name': names[i]},
      ],
    };

String? _label(List<Map<String, dynamic>> companies,
        {String? branchId, String? branchName, bool all = false}) =>
    businessBranchChipLabel(
      companies: companies,
      scopeOrganizationId: _org,
      ownOrganizationId: _org,
      branchId: branchId,
      branchName: branchName,
      allMode: all,
      allBranchesLabel: 'ALL',
      mainBranchLabel: 'MAIN',
    );

Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> companies,
    {ThemeMode mode = ThemeMode.dark, double width = 240}) async {
  AppColors.setLightMode(mode == ThemeMode.light);
  await tester.runAsync(() => AppLocalizations.preload('ar'));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      branchMenuAccessProvider.overrideWith((ref) async => companies),
      currentUserProvider.overrideWithValue(null),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Mirrors HomeHeader: the chip sits on its own line UNDER the title.
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: width, child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('قسم الأعمال', key: ValueKey('title')),
              BusinessBranchChip(),
            ],
          )),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BranchScope.clear();
  });
  tearDown(() async {
    AppColors.setLightMode(false);
    await BranchScope.clear();
  });

  group('businessBranchChipLabel', () {
    test('one branch → no chip', () {
      expect(_label([_company(['A'])], branchId: 'b0'), isNull);
    });
    test('two branches → current branch name', () {
      expect(_label([_company(['A', 'B'])], branchId: 'b1'), 'B');
    });
    test('all-branches mode → localized all label', () {
      expect(_label([_company(['A', 'B'])], all: true), 'ALL');
    });
    test('unknown id falls back to saved name then main', () {
      expect(_label([_company(['A', 'B'])], branchId: 'x', branchName: 'Saved'), 'Saved');
      expect(_label([_company(['A', 'B'])]), 'MAIN');
    });
    test('archived/inactive branches do not count', () {
      final c = _company(['A', 'B']);
      (c['branches'] as List)[1]['is_archived'] = true;
      expect(_label([c], branchId: 'b0'), isNull);
    });
  });

  testWidgets('chip hidden with one branch', (tester) async {
    BranchScope.organizationId = _org;
    BranchScope.branchId = 'b0';
    await _pump(tester, [_company(['Main'])]);
    expect(find.byKey(const ValueKey('business-branch-chip')), findsNothing);
  });

  testWidgets('chip shown with two branches; long names truncate; light+dark',
      (tester) async {
    BranchScope.organizationId = _org;
    BranchScope.branchId = 'b1';
    final long = 'فرع ${'طويل جدا ' * 10}'.trim();
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      await _pump(tester, [_company(['Main', long])], mode: mode);
      expect(find.byKey(const ValueKey('business-branch-chip')), findsOneWidget);
      expect(find.text(long), findsOneWidget);
      expect(tester.takeException(), isNull); // no overflow
    }
  });

  testWidgets('chip sits below the title and shows the full branch name',
      (tester) async {
    BranchScope.organizationId = _org;
    BranchScope.branchId = 'b1';
    const name = 'فرع المدينة الرئيسي';
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      await _pump(tester, [_company(['Main', name])], mode: mode, width: 360);
      final title = tester.getRect(find.byKey(const ValueKey('title')));
      final chip =
          tester.getRect(find.byKey(const ValueKey('business-branch-chip')));
      expect(chip.top, greaterThanOrEqualTo(title.bottom),
          reason: 'chip is on its own line under «قسم الأعمال»');
      final paragraph = tester.renderObject<RenderParagraph>(find.text(name));
      expect(paragraph.didExceedMaxLines, isFalse,
          reason: 'a normal branch name is never cut');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a truly long name is ellipsized within the header width',
      (tester) async {
    BranchScope.organizationId = _org;
    BranchScope.branchId = 'b1';
    final long = 'فرع ${'طويل جدا ' * 20}'.trim();
    await _pump(tester, [_company(['Main', long])], width: 400);
    final chip =
        tester.getRect(find.byKey(const ValueKey('business-branch-chip')));
    expect(chip.width, lessThanOrEqualTo(BranchChipView.maxWidth));
    expect(tester.renderObject<RenderParagraph>(find.text(long))
        .didExceedMaxLines, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chip updates when the branch switches', (tester) async {
    BranchScope.organizationId = _org;
    BranchScope.branchId = 'b0';
    await _pump(tester, [_company(['Alpha', 'Beta'])]);
    expect(find.text('Alpha'), findsOneWidget);
    BranchScope.branchId = 'b1';
    final container = ProviderScope.containerOf(
        tester.element(find.byType(BusinessBranchChip)));
    container.read(branchEpochProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    BranchScope.allMode = true;
    container.read(branchEpochProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(find.text('جميع الفروع'), findsOneWidget);
  });
}
