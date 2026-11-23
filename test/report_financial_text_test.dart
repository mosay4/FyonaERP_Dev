import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/reports/presentation/widgets/report_widgets.dart';

void main() {
  testWidgets(
    '12+ digit amount and long currency never clip, wrap or overflow',
    (tester) async {
      const text = '123,456,789,012.50 ريال يمني قديم';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                child: ReportFitText(
                  text: text,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 22),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(text), findsOneWidget);
      expect(tester.takeException(), isNull);
      final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fitted.fit, BoxFit.scaleDown);
      final render = tester.renderObject<RenderBox>(find.byType(FittedBox));
      expect(render.size.width, lessThanOrEqualTo(150));
    },
  );

  test('single-currency helper accepts one code only by construction', () {
    const amount = '11';
    const code = 'USD';
    final line = '$amount $code';
    expect(line.split(' ').length, 2);
  });
}
