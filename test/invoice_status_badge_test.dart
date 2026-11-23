import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/business_widgets.dart';

void main() {
  testWidgets('StatusBadge shows a proper Arabic label for partially_paid',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: const Scaffold(body: StatusBadge(status: 'partially_paid')),
    ));
    await tester.pump();
    expect(find.text('مدفوعة جزئياً'), findsOneWidget);
    expect(find.text('partially_paid'), findsNothing);
  });
}
