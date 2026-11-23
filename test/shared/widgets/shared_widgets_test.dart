import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/widgets/business_widgets.dart';
import 'package:fyona_flutter/shared/widgets/stat_card.dart';
import 'package:fyona_flutter/shared/widgets/data_components.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icons.dart';

import '../../test_utils.dart';

void main() {
  // StatusBadge reads labels through AppLocalizations, so the ARB table must
  // be preloaded outside FakeAsync and the delegates must be in the tree.
  setUpAll(() => ensureTestLocalization());
  group('StatCard', () {
    testWidgets('renders title and value', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatCard(
          title: 'العملاء',
          value: '١٠٠',
          icon: TwoToneIcons.users,
        )),
      ));

      expect(find.text('العملاء'), findsOneWidget);
      expect(find.text('١٠٠'), findsOneWidget);
    });
  });

  group('StatusBadge', () {
    testWidgets('renders paid status', (tester) async {
      await pumpLocalizedWidget(tester, const StatusBadge(status: 'paid'));
      await tester.pumpAndSettle();
      expect(find.text('مدفوعة'), findsOneWidget);
    });

    testWidgets('renders cancelled status', (tester) async {
      await pumpLocalizedWidget(tester, const StatusBadge(status: 'cancelled'));
      await tester.pumpAndSettle();
      expect(find.text('ملغية'), findsOneWidget);
    });

    testWidgets('renders draft status', (tester) async {
      await pumpLocalizedWidget(tester, const StatusBadge(status: 'draft'));
      await tester.pumpAndSettle();
      expect(find.text('مسودة'), findsOneWidget);
    });
  });

  group('EmptyStateWidget', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: EmptyStateWidget(title: 'لا توجد بيانات')),
      ));
      expect(find.text('لا توجد بيانات'), findsOneWidget);
    });
  });

  group('SearchBarWidget', () {
    testWidgets('renders hint text', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SearchBarWidget(
          controller: TextEditingController(),
          onChanged: (_) {},
          hintText: 'بحث...',
        )),
      ));
      expect(find.text('بحث...'), findsOneWidget);
    });
  });

  group('FormCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FormCard(title: 'معلومات العميل', children: [])),
      ));
      expect(find.text('معلومات العميل'), findsOneWidget);
    });
  });

  group('PaginationControls', () {
    testWidgets('renders page info', (tester) async {
      await pumpLocalizedWidget(
        tester,
        PaginationControls(
          currentPage: 1,
          totalPages: 5,
          totalItems: 100,
          onPrevious: () {},
          onNext: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('صفحة 1 من 5'), findsOneWidget);
      expect(find.text('إجمالي 100'), findsOneWidget);
    });
  });
}
