import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('pulling down refreshes without hiding the page ($platform)', (
      tester,
    ) async {
      var refreshed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: FyonaRefresh(
              onRefresh: () async {
                refreshed++;
                await Future<void>.delayed(const Duration(milliseconds: 300));
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  for (var i = 0; i < 30; i++) ListTile(title: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      );
      // A short pull does nothing.
      await tester.drag(find.text('row 0'), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(refreshed, 0);
      // A full pull refreshes once; the rows stay on screen meanwhile.
      final top = tester.getTopLeft(find.text('row 0')).dy;
      await tester.drag(find.text('row 0'), const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('row 0'), findsOneWidget);
      // While the dots show, the page stays pulled down (also on bouncing
      // lists that spring back by themselves).
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.getTopLeft(find.text('row 0')).dy, greaterThan(top + 30));
      await tester.pumpAndSettle();
      expect(refreshed, 1);
      expect(find.text('row 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
