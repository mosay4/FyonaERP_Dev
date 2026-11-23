import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/auth/presentation/widgets/google_logo.dart';

void main() {
  testWidgets('GoogleLogo يرسم بدون أخطاء وضمن حدوده', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: GoogleLogo(size: 48)),
        ),
      ),
    );

    final customPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(GoogleLogo),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(customPaint.painter, isNotNull);

    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
