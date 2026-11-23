import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/employees/data/employee_permissions.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_detail_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/employee_permissions_editor.dart';

Widget localized(String language, Widget child) => MaterialApp(
  locale: Locale(language),
  supportedLocales: const [Locale('ar'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

void main() {
  test('permission names match app actions and HR is never grantable', () {
    const labels = {
      'ai': ('سارة', 'Sara'),
      'falcon': ('صقر', 'Saqr'),
      'transactions': ('العمليات', 'Transactions'),
      'income': ('إضافة دخل', 'Add income'),
      'expenses': ('سحب مصروف', 'Withdraw expense'),
      'returns': ('المرتجعات', 'Returns'),
    };
    for (final entry in labels.entries) {
      expect(employeeGroupLabel(entry.key, arabic: true), entry.value.$1);
      expect(employeeGroupLabel(entry.key, arabic: false), entry.value.$2);
    }
    expect(employeePermissionGroups, isNot(contains('employees')));
    expect(defaultEmployeePermissions(), isNot(contains('employees')));
    expect(employeePermissionGroups, isNot(contains('subscription')));
    expect(employeePermissionOrder, isNot(contains('subscription')));
    expect(defaultEmployeePermissions(), isNot(contains('subscription')));
    expect(employeePermissionAllowed({'subscription': true}, 'subscription'), isFalse);
    expect(
      employeePermissionAllowed({'employees': true}, 'employees'),
      isFalse,
    );
    final perms = {...defaultEmployeePermissions(), 'banks.balances': false};
    expect(employeePermissionAllowed(perms, 'banks'), isTrue);
    expect(employeePermissionAllowed(perms, 'banks.balances'), isFalse);
    expect(employeeHasFullAccess(perms), isFalse);
  });
  test('every permission group and child has bilingual labels', () {
    for (final arabic in [true, false]) {
      for (final entry in employeePermissionGroups.entries) {
        expect(employeeGroupLabel(entry.key, arabic: arabic), isNot(entry.key));
        expect(employeeGroupDescription(entry.key, arabic: arabic), isNotEmpty);
        expect(
          employeeGroupLabel(entry.key, arabic: arabic),
          isNot(contains('Other section')),
        );
        for (final child in entry.value) {
          expect(employeeChildLabel(child, arabic: arabic), isNot(child));
          expect(
            employeeChildLabel(child, arabic: arabic),
            isNot(contains('Other permission')),
          );
        }
      }
    }
  });

  for (final language in ['ar', 'en']) {
    final arabic = language == 'ar';
    testWidgets('$language editor uses shared permission labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        localized(
          language,
          Scaffold(
            body: SingleChildScrollView(
              child: EmployeePermissionsEditor(
                value: const {'sales': true, 'sales.returns': true},
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(find.text(arabic ? 'الرئيسية' : 'Dashboard'), findsOneWidget);
      expect(find.text(arabic ? 'البنوك' : 'Banks'), findsOneWidget);
      for (final group in ['sales', 'purchases', 'reconciliation']) {
        final title = find.text(employeeGroupLabel(group, arabic: arabic));
        await tester.ensureVisible(title);
        await tester.pumpAndSettle();
        await tester.tap(title);
        await tester.pumpAndSettle();
        final tile = find.ancestor(
          of: title,
          matching: find.byType(ExpansionTile),
        );
        for (final child in employeePermissionGroups[group]!) {
          expect(
            find.descendant(
              of: tile,
              matching: find.text(employeeChildLabel(child, arabic: arabic)),
            ),
            findsOneWidget,
          );
        }
      }
      for (final key in {
        ...employeePermissionGroups.keys,
        ...employeePermissionGroups.values.expand((keys) => keys),
      }) {
        expect(find.text(key), findsNothing);
      }
      expect(find.text(arabic ? 'المرتجعات' : 'Returns'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$language detail uses shared permission labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeesProvider.overrideWith(
              (ref) async => [
                {
                  'id': 'e1',
                  'full_name': 'محمد',
                  'status': 'linked',
                  'salary': 500,
                  'salary_currency': 'SAR',
                  'permissions': {
                    'sales': true,
                    'sales.returns': true,
                    'purchases': true,
                    'purchases.returns': true,
                    'reconciliation': true,
                    'reconciliation.bank': true,
                    'reconciliation.inventory': true,
                    'reconciliation.equalize': true,
                  },
                },
              ],
            ),
          ],
          child: localized(language, const EmployeeDetailPage(id: 'e1')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(
          arabic ? 'إيش يقدر يسوي الموظف؟' : 'What can the employee do?',
        ),
        250,
      );
      await tester.pumpAndSettle();
      expect(find.text(arabic ? 'المرتجعات' : 'Returns'), findsNWidgets(2));
      for (final child in ['bank', 'inventory', 'equalize']) {
        expect(
          find.text(employeeChildLabel(child, arabic: arabic)),
          findsOneWidget,
        );
      }
      for (final key in [
        'returns',
        'bank',
        'inventory',
        'equalize',
        'sales',
        'purchases',
      ]) {
        expect(find.text(key), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
