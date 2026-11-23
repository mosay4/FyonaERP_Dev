import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_form_page.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';

void main() {
  testWidgets('employee form inputs keep readable widths', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: EmployeeFormPage())),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      final size = tester.getSize(fields.at(i));
      expect(
        size.width,
        greaterThan(180),
        reason: 'field $i width ${size.width}',
      );
      expect(size.height, greaterThanOrEqualTo(48));
    }
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'حفظ الموظف'),
    );
    expect(save.style?.backgroundColor?.resolve({}), AppColors.success);
  });
}
