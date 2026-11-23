import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_debts_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';

void main() {
  testWidgets('employee debt page builds with empty data', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeFinanceForProvider('x').overrideWith(
            (ref) async => {'salary': [], 'debts': [], 'balances': {}},
          ),
        ],
        child: const MaterialApp(
          home: EmployeeDebtsPage(
            employeeId: 'x',
            employeeName: 'Test',
            readOnly: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ديوني'), findsOneWidget);
    expect(find.text('ما في ديون في هذه الفترة'), findsOneWidget);
  });
}
