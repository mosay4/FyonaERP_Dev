import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/local_commerce_navigation.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/inventory/data/business_inventory_image.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/categories_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/category_detail_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_count_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_pick_page.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAFElEQVR4nGNk'
    'YPjPwMDAxMDAgKAAEkIBBZH9Q6gAAAAASUVORK5CYII=';

void main() {
  testWidgets(
    'original category and count screens use saved photos with no REST',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = DirectoryWorkspace(
        server: DirectoryPilotBuild.baseUrl,
        accountId: _id(),
        organizationId: _id(),
      );
      final scope = DirectoryAccess(
        workspace: workspace,
        branchId: _id(),
        readable: {},
        writable: {},
        financialCutover: true,
      );
      final grant = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      final keys = FixtureDirectoryKeys();
      const catName = 'Fixture bakery', productName = 'Fixture bread';
      final category = _id();
      late final Directory root;
      late final DirectoryPilotStore store;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        await BranchScope.save(
          token: 'fixture',
          branchId: scope.branchId,
          branchName: 'Fixture',
          allMode: false,
          organizationId: workspace.organizationId,
        );
        await AppLocalizations.preload('en');
        root = await Directory.systemTemp.createTemp('fyona-catalogue-ui-');
        final photo = File('${root.path}/fixture.png');
        await photo.writeAsBytes(base64Decode(_png));
        final image = await readBusinessProductImage(photo.path);
        await photo.delete(); // The renderer must not require the picked file.
        final db = await DirectoryDatabase.open(
          root: root,
          workspace: workspace,
          keys: keys,
        );
        await db.close();
        final setup = await databaseFactoryFfi.openDatabase(
          DirectoryDatabase.filePath(root, workspace),
          options: OpenDatabaseOptions(
            singleInstance: false,
            onConfigure: (s) => s.execute(
              'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
            ),
          ),
        );
        try {
          await setup.insert('business_commerce_catalogue', {
            'branch_id': scope.branchId,
          });
          await setup.insert('business_commerce_categories', {
            'branch_id': scope.branchId,
            'id': category,
            'name': catName,
            'image': image,
            'active': 1,
          });
        } finally {
          await setup.close();
        }
        store = DirectoryPilotStore(root: () async => root, keys: keys);
        await store.remember(scope, {
          'status': 'active',
          'business_setup_completed': true,
          'sections': {
            'business': {
              'active': true,
              'end_date': DateTime.now()
                  .add(const Duration(days: 1))
                  .toIso8601String(),
            },
          },
        });
        await store.withLedger(
          grant,
          () => scope,
          (ledger) => ledger.createCommerceProduct(
            grant,
            commandId: _id(),
            name: productName,
            unit: 'piece',
            price: 3,
            costPrice: 1,
            stock: 4,
            categoryId: category,
            image: image,
          ),
        );
      });
      addTearDown(() async {
        await store.close();
        await BranchScope.clear();
        await root.delete(recursive: true);
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const audio = 'xyz.luan/audioplayers';
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      for (final name in [
        audio,
        '$audio.global',
        '$audio.global/events',
        for (final id in ['fyona_scan_ok', 'fyona_scan_bad', 'fyona_recon_eq'])
          '$audio/events/$id',
      ]) {
        final channel = MethodChannel(name);
        messenger.setMockMethodCallHandler(channel, (call) async {
          final event = switch (call.method) {
            'seek' => {'event': 'audio.onSeekComplete'},
            'setSourceUrl' ||
            'setSourceBytes' => {'event': 'audio.onPrepared', 'value': true},
            _ => null,
          };
          if (name == audio && event != null) {
            unawaited(
              messenger.handlePlatformMessage(
                '$audio/events/${call.arguments['playerId']}',
                const StandardMethodCodec().encodeSuccessEnvelope(event),
                null,
              ),
            );
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }

      final scopeState = StateProvider<DirectoryAccess?>((_) => scope);
      final inventoryReadable = StateProvider<bool>((_) => true);
      final http = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, handler) {
              http.add(r.uri.toString());
              handler.resolve(
                Response(
                  requestOptions: r,
                  data: {
                    'data': [
                      {'id': 'connected', 'name': 'Connected category'},
                    ],
                  },
                ),
              );
            },
          ),
        );
      addTearDown(dio.close);
      final container = ProviderContainer(
        overrides: [
          businessLocalLedgerScopeProvider.overrideWith(
            (ref) => ref.watch(scopeState),
          ),
          directoryPilotStoreProvider.overrideWithValue(store),
          employeeCanProvider.overrideWith(
            (ref, permission) =>
                permission != 'inventory' || ref.watch(inventoryReadable),
          ),
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          dioProvider.overrideWithValue(dio),
        ],
      );
      addTearDown(container.dispose);
      late final LocalCommerceTarget target;
      late final Uri categoryUri;
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const CategoriesPage()),
          GoRoute(
            path: RouteNames.inventoryCategoryDetail,
            builder: (_, state) {
              categoryUri = state.uri;
              target = state.extra as LocalCommerceTarget;
              return CategoryDetailPage(id: target.id, localTarget: target);
            },
          ),
          GoRoute(
            path: RouteNames.reconciliationInventoryPick,
            builder: (_, _) => const ReconInventoryPickPage(scope: 'category'),
          ),
          GoRoute(
            path: '/reconciliation/inventory/count',
            builder: (_, state) {
              final data = state.extra as Map;
              return ReconInventoryCountPage(
                record: data['record'] as Map<String, dynamic>,
                localLink: data['local'] as LocalReconciliationLink,
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      // SQLCipher uses real I/O; pump the UI while the FFI futures complete.
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 120 && !done(); i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(
          done(),
          isTrue,
          reason: 'The device catalogue did not finish its UI read',
        );
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            routerConfig: router,
          ),
        ),
      );
      final paintedPhoto = find.byWidgetPredicate(
        (w) => w is RawImage && w.image != null,
      );
      await until(
        () => tester.any(find.text(catName)) && tester.any(paintedPhoto),
      );
      await tester.tap(find.text(catName));
      await until(() => tester.any(find.text(productName)));
      await tester.pumpAndSettle();
      expect(categoryUri.queryParameters, isEmpty);
      expect(target.id, category);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(CategoryDetailPage)),
      );
      // The branch owns its categories: no shared/read-only banner, and a
      // rename is saved in this branch's own ledger.
      expect(find.text(l10n.translate('invSharedCategoryReadOnly')), findsNothing);
      final api = container.read(inventoryApiProvider) as LocalInventoryApi;
      await tester.runAsync(() async {
        await api.updateCategory(category, 'Renamed here');
        expect(
          (await api.categories()).singleWhere((c) => c['id'] == category)['name'],
          'Renamed here',
        );
        await api.updateCategory(category, catName);
      });
      await tester.pump();

      container.read(inventoryReadable.notifier).state = false;
      await tester.pump();
      expect(find.text(productName), findsNothing);
      expect(find.text(catName), findsNothing);
      await expectLater(
        api.categories(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      container.read(inventoryReadable.notifier).state = true;
      router.go(RouteNames.reconciliationInventoryPick);
      final pick = find.descendant(
        of: find.byType(ReconInventoryPickPage),
        matching: find.text(catName),
      );
      await until(() => tester.any(pick));
      await tester.pumpAndSettle();
      await tester.tap(pick);
      final countPage = find.byType(ReconInventoryCountPage);
      final countedPhoto = find.descendant(
        of: countPage,
        matching: paintedPhoto,
      );
      final countedProduct = find.descendant(
        of: countPage,
        matching: find.text(productName),
      );
      await until(() => tester.any(countedProduct) && tester.any(countedPhoto));
      await tester.pumpAndSettle();
      final count = tester.widget<ReconInventoryCountPage>(countPage);
      expect(count.record['scope'], 'category');
      expect(count.localLink?.ids, count.record['id']);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(http, isEmpty);

      // A stale detail/stocktake cannot show rows or send its IDs after the
      // user switches sources. The connected sibling still uses REST.
      container.read(scopeState.notifier).state = null;
      container.read(branchEpochProvider.notifier).state++;
      await tester.pump();
      expect(find.text(productName), findsNothing);
      expect(http, isEmpty);
      final connected = container.read(inventoryApiProvider);
      final backOnline = await tester.runAsync(connected.categories);
      expect(backOnline!.single['name'], 'Connected category');
      expect(http.single, endsWith('/categories'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );
}
