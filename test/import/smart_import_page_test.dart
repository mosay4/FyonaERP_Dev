// The smart import window: owner only; tables and drag-and-drop columns;
// the two-part review with thousands of rows, cell edits and bulk choices.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_schema.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:fyona_flutter/core/import/presentation/smart_import_page.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';

DirectoryAccess _scope({bool member = false}) => DirectoryAccess(
      workspace: DirectoryWorkspace(
          server: 'https://x.test/api/v1',
          accountId: '11111111-1111-4111-8111-111111111111',
          organizationId: '22222222-2222-4222-8222-222222222222'),
      branchId: '33333333-3333-4333-8333-333333333333',
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
      financialCutover: true,
      member: member,
    );

/// The window's Sara button keeps glowing: wait a fixed time instead of
/// "until nothing moves".
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('owner sees the entry; an employee does not', (tester) async {
    for (final member in [false, true]) {
      await tester.pumpWidget(ProviderScope(
        overrides: [businessLocalLedgerScopeProvider.overrideWithValue(_scope(member: member))],
        child: const MaterialApp(home: Scaffold(body: SmartImportEntry())),
      ));
      expect(find.byKey(const Key('si-entry')), member ? findsNothing : findsOneWidget);
    }
  });

  testWidgets('every place in FYONA is offered; columns dragged onto a field (swap with the old one)', (tester) async {
    final dir = Directory.systemTemp.createTempSync('fyona-si-ui-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/stock.csv')..writeAsStringSync('الصنف,السعر,الكمية,لون\nقلم,2.5,100,أزرق\n');
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var saraAsked = 0;
    await tester.runAsync(() async {
      await AppLocalizations.preload('ar');
      await tester.pumpWidget(ProviderScope(
        overrides: [
          businessLocalLedgerScopeProvider.overrideWithValue(_scope()),
          smartImportSaraProvider.overrideWithValue(SmartImportSara(
            schema: (t) async {
              saraAsked++;
              return const [];
            },
            agent: (m, s) async => null,
          )),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: SmartImportPage(initialFile: f),
        ),
      ));
      for (var i = 0; i < 80 && find.byKey(const Key('si-review')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pump();
    final dest = find.byWidgetPredicate((w) => w.key is ValueKey<String> && '${(w.key as ValueKey<String>).value}'.startsWith('si-dest-'));
    expect(dest, findsOneWidget);
    expect(find.text('المنتجات'), findsWidgets); // recognised as products
    // The destination list offers EVERY place a table can go.
    await tester.tap(dest);
    await _settle(tester);
    for (final r in TableRole.values.where((r) => r != TableRole.unknown)) {
      await tester.scrollUntilVisible(find.byKey(Key('si-role-${r.name}')), 80,
          scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first);
      expect(find.byKey(Key('si-role-${r.name}')), findsOneWidget, reason: r.name);
    }
    await tester.tapAt(const Offset(10, 10));
    await _settle(tester);
    // Columns: "لون" (colour) has no place and is listed as not saved.
    final cols = find.byWidgetPredicate((w) => w.key is ValueKey<String> && '${(w.key as ValueKey<String>).value}'.startsWith('si-columns-'));
    await tester.tap(cols);
    await _settle(tester);
    expect(find.byKey(const Key('si-col-لون')), findsOneWidget);
    // Drag الكمية onto the sale price: السعر goes to the quantity field.
    final from = tester.getCenter(find.byKey(const Key('si-col-الكمية')));
    final to = tester.getCenter(find.byKey(const Key('si-field-sale_price')));
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 50));
    await g.moveTo(to);
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('si-field-sale_price')), matching: find.text('الكمية')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('si-field-stock')), matching: find.text('السعر')), findsOneWidget);
    await tester.tap(find.byKey(const Key('si-columns-done')));
    await _settle(tester);
    // Sara is a button in the check (no chat window), with her picture.
    expect(find.byKey(const Key('si-sara-check')), findsOneWidget);
    expect(find.byType(SaraAvatar), findsWidgets);
  });

  testWidgets('review of 5 000 rows: cards in clear groups, the reason on each, edit in a sheet and bulk choices', (tester) async {
    final dir = Directory.systemTemp.createTempSync('fyona-si-review-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final b = StringBuffer('name,phone,balance\n');
    for (var i = 0; i < 5000; i++) {
      b.write('عميل $i,05$i,${i % 7 == 0 ? 'abc' : '$i.5'}\n');
    }
    final f = File('${dir.path}/c.csv')..writeAsStringSync(b.toString());
    final review = (await tester.runAsync(() async {
      final t = (await readImportFile(f)).single;
      return ImportReview.load(t, ImportTarget.parties, autoMapColumns(ImportTarget.parties, t.columns), defaultCurrency: 'SAR');
    }))!;
    expect(review.refusedCount, 715);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: ImportReviewView(review: review, onChanged: () {})),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('4285'), findsWidgets);
    expect(find.textContaining('715'), findsWidgets);
    // Lazily built: only the visible rows exist.
    expect(find.byKey(const Key('si-row-2')), findsOneWidget);
    expect(find.byKey(const Key('si-row-4999')), findsNothing);
    await tester.tap(find.byKey(const Key('si-tab-refused')));
    await tester.pump();
    expect(find.byKey(const Key('si-row-1')), findsOneWidget);
    expect(find.textContaining('رقم غير مفهوم'), findsWidgets); // the reason on the card
    expect(find.byKey(const Key('si-reason-bad_number')), findsOneWidget);
    // Fix row 1's balance by hand (its sheet): it moves to "will be added".
    await tester.tap(find.byKey(const Key('si-row-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('si-cell-1-balance')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('si-edit-field')), '10');
    await tester.tap(find.byKey(const Key('si-edit-save')));
    await tester.pumpAndSettle();
    expect(review.refusedCount, 714);
    await tester.tapAt(const Offset(20, 20)); // close the sheet
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('si-row-1')), findsNothing);
    // Search, select all shown, leave them out.
    await tester.tap(find.byKey(const Key('si-tab-add')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('si-search')), 'عميل 49');
    await tester.pump(const Duration(milliseconds: 300)); // typing pause
    await tester.tap(find.byKey(const Key('si-select-all')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('si-bulk')));
    await tester.pump();
    final hits = [for (var i = 0; i < 5000; i++) if ('عميل $i'.contains('عميل 49') && (i % 7 != 0 || i == 0)) i];
    expect(review.rows.where((r) => r.rejectedByUser).length, hits.length);
    expect(review.acceptedCount, 4286 - hits.length);
  });
}
