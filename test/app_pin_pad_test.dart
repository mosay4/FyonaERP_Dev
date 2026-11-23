import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fyona_flutter/features/auth/presentation/widgets/app_pin_pad.dart';

/// AppPinPad: typing 5 digits fires onCompleted once with the PIN.
void main() {
  testWidgets('completing 5 digits reports the PIN', (tester) async {
    String? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppPinPad(
            onCompleted: (pin) => got = pin,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '12345');
    await tester.pump();

    expect(got, '12345');
  });

  testWidgets('non-digits are filtered, short input stays silent', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppPinPad(
            onCompleted: (_) => calls++,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '12ab');
    await tester.pump();
    expect(calls, 0);

    await tester.enterText(find.byType(TextField), '98765');
    await tester.pump();
    expect(calls, 1);
  });
}
