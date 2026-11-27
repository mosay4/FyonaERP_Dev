// The backups list: numbered (newest highest, on top); a trash button
// switches to selection, any backups can be picked and deleted after a
// confirmation; what could not be deleted stays listed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/presentation/backup_list_sheet.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

void main() {
  testWidgets('select backups and delete them', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final items = [
      for (var i = 0; i < 4; i++) BackupListItem('b$i', DateTime(2026, 11, 20 + i, 10, 30), (i + 1) * 1048576),
    ];
    final asked = <List<String>>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => BackupListSheet.show(ctx, title: 't', icon: Icons.cloud, items: items, empty: 'e',
                onDelete: (picked) async {
              asked.add([for (final p in picked) p.name]);
              // b1 cannot be deleted (e.g. offline): it stays.
              return [for (final p in picked) if (p.name != 'b1') p];
            }),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bkh-item-4')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bkl-select')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bkh-item-1')));
    await tester.tap(find.byKey(const Key('bkh-item-2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bkl-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bkl-delete-confirm')));
    await tester.pumpAndSettle();
    expect(asked.single.toSet(), {'b0', 'b1'});
    expect(find.byKey(const Key('bkh-item-1')), findsNothing); // deleted
    expect(find.byKey(const Key('bkh-item-2')), findsOneWidget); // could not be deleted: still listed
    expect(find.byKey(const Key('bkh-item-4')), findsOneWidget);
  });
}
