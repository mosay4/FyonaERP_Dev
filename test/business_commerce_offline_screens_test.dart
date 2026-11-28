import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart'
    show secureStorageProvider;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart'
    show apiClientProvider;
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart'
    show SecureStorageService;
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_banks_page.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/customers_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_detail_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/suppliers_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_party_sharing_provider.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_relay_http_provider.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/local_commerce_navigation.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_income_expense_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_transaction_details_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_transactions_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_recent_ops.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_detail_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_form_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_movements_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/invoices/presentation/pages/invoice_view_page.dart';
import 'package:fyona_flutter/features/invoices/presentation/providers/invoices_providers.dart';
import 'package:fyona_flutter/features/purchases/presentation/pages/purchase_invoice_page.dart';
import 'package:fyona_flutter/features/purchases/presentation/pages/purchase_success_dialog.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/returns/presentation/pages/invoice_picker_page.dart';
import 'package:fyona_flutter/features/returns/presentation/pages/return_create_page.dart';
import 'package:fyona_flutter/features/returns/presentation/pages/return_success_dialog.dart';
import 'package:fyona_flutter/features/returns/presentation/pages/return_view_page.dart';
import 'package:fyona_flutter/features/returns/presentation/pages/returns_page.dart';
import 'package:fyona_flutter/features/returns/presentation/providers/returns_providers.dart';
import 'package:fyona_flutter/features/sales/presentation/pages/sale_invoice_page.dart';
import 'package:fyona_flutter/features/sales/presentation/pages/sale_success_dialog.dart';
import 'package:fyona_flutter/features/sales/presentation/providers/sale_providers.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';
import 'package:fyona_flutter/shared/widgets/currency_selector.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:fyona_flutter/features/reports/data/reports_api.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/local_business_banking.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/business_banks_providers.dart';
import 'support/directory_test_keys.dart';

const _enabled =
    DirectoryPilotBuild.signupEnabled &&
    bool.fromEnvironment('FYONA_BUSINESS_LEDGER_QA');
const _owner = UserModel(
  id: '8dfa2ad5-66b2-4762-ae97-2f66fd64fd9b',
  organizationId: '869f687d-0873-4bfa-b4a4-4ae2ebc45bb5',
  role: 'owner',
  status: 'active',
  phoneComplete: true,
  phoneMasked: '***0000',
  preferredUsageMode: 'business',
);
const _branch = 'b539002c-6787-4c7a-af95-11ffe0779ade';
const _sibling = '444f459e-dd4f-43c4-a695-340cb45b75af';
const _currency = 'YER_OLD';
const _bankName = 'بنك الاختبار المحلي';
const _refundBank = 'جيب تجريبي';
const _productName = 'منتج الاختبار المحلي';

class _SignedIn extends StateNotifier<AuthState> implements AuthNotifier {
  _SignedIn()
    : super(const AuthState(status: AuthStatus.authenticated, user: _owner));

  void setUser(UserModel user) =>
      state = AuthState(status: AuthStatus.authenticated, user: user);

  @override
  dynamic noSuchMethod(Invocation call) => super.noSuchMethod(call);
}

class _ReadOnlySession extends SecureStorageService {
  @override
  Future<String?> getToken() async {
    final payload = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'type': 'access',
          'sub': _owner.id,
          'sid': '920ef047-6829-4fee-9f80-bda286cc54fd',
        }),
      ),
    );
    return 'fixture.$payload.signature';
  }
}

String _selectionToken({required String branch, required bool ledger}) {
  // The real endpoint produces this payload; the Flutter scope reader binds
  // the retained server response to the local identity and selected branch.
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'typ': 'branch_scope',
            'mode': 'branch',
            'sub': _owner.id,
            'org': _owner.organizationId,
            'branch': branch,
            'qa_directory': true,
            if (ledger) 'qa_business_ledger': true,
          }),
        ),
      )
      .replaceAll('=', '');
  return 'fixture.$payload.signature';
}

Future<void> _select({
  required bool ledger,
  String branch = _branch,
  String? claimedBranch,
}) => BranchScope.save(
  token: _selectionToken(branch: claimedBranch ?? branch, ledger: ledger),
  branchId: branch,
  branchName: 'فرع اختبار مستقل',
  allMode: false,
  organizationId: _owner.organizationId,
);

class _Round {
  _Round({this.onShareRequest})
    : connectivity = ConnectivityService(debugOnline: false);

  final void Function(RequestOptions, RequestInterceptorHandler)?
  onShareRequest;
  final ConnectivityService connectivity;
  final attempted = <String>[];
  final keys = FixtureDirectoryKeys();
  late final Directory root;
  late DirectoryPilotStore store;
  ProviderContainer? _container;
  ProviderContainer get container => _container!;

  Future<void> setup() async {
    SharedPreferences.setMockInitialValues({
      'enabled_currencies_biz_${_owner.id}_$_branch': [_currency],
    });
    root = await Directory.systemTemp.createTemp('fyona-commerce-ui-');
    reopen();
  }

  Future<void> closeStore() async {
    _container?.dispose();
    _container = null;
    await store.close();
  }

  Future<void> dispose() async {
    connectivity.dispose();
    await closeStore();
    await BranchScope.clear();
    await root.delete(recursive: true);
  }

  void reopen() {
    store = DirectoryPilotStore(root: () async => root, keys: keys);
    final tripwire = Dio(BaseOptions(baseUrl: DirectoryPilotBuild.baseUrl));
    tripwire.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          attempted.add('${request.method} ${request.path}');
          handler.reject(
            DioException.connectionError(
              requestOptions: request,
              reason: 'Synthetic transport failure',
            ),
          );
        },
      ),
    );
    final relay = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (onShareRequest != null &&
                request.uri.path.startsWith(
                  '/api/v1/business/party-sharing/',
                )) {
              expect(
                request.headers['Authorization'],
                startsWith('Bearer fixture.'),
              );
              expect(request.headers.containsKey('X-Refresh-Token'), isFalse);
              onShareRequest!(request, handler);
              return;
            }
            attempted.add('${request.method} ${request.path}');
            handler.reject(
              DioException.connectionError(
                requestOptions: request,
                reason: 'Unexpected QA relay request',
              ),
            );
          },
        ),
      );
    _container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((_) => _SignedIn()),
        serverBaseUrlProvider.overrideWith((_) => DirectoryPilotBuild.baseUrl),
        directoryPilotStoreProvider.overrideWithValue(store),
        connectivityServiceProvider.overrideWithValue(connectivity),
        branchAccessProvider.overrideWith((_) async => const []),
        apiClientProvider.overrideWithValue(ApiClient(dio: tripwire)),
        businessRelayHttpProvider.overrideWith((ref) {
          ref.onDispose(() => relay.close(force: true));
          return relay;
        }),
        secureStorageProvider.overrideWithValue(_ReadOnlySession()),
        dioProvider.overrideWithValue(tripwire),
        currencyEngineProvider.overrideWithValue(CurrencyEngine()),
      ],
    );
  }

  Future<void> rememberAccess() async {
    final scope = container.read(directoryPilotAccessProvider)!;
    await store.remember(scope, {
      'status': 'active',
      'business_setup_completed': true,
      'sections': {
        'business': {
          'active': true,
          'end_date': DateTime.now()
              .add(const Duration(days: 2))
              .toIso8601String(),
        },
      },
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'scope comes from the retained branch claim, not a name or directory entitlement',
    () async {
      final lab = _Round();
      await lab.setup();
      addTearDown(lab.dispose);
      await _select(ledger: false);
      await lab.rememberAccess();
      final c = lab.container;
      expect(c.read(directoryPilotAccessProvider)?.branchId, _branch);
      expect(c.read(businessLocalLedgerScopeProvider), isNull);
      expect(c.read(salesApiProvider), isNot(isA<LocalSalesApi>()));
      // The owner opens another branch of the same organization offline with
      // the organization's signed context (no cross-branch session).
      await _select(ledger: true, branch: _sibling, claimedBranch: _branch);
      c.read(branchEpochProvider.notifier).state++;
      expect(c.read(businessLocalLedgerScopeProvider)?.branchId, _sibling);
      expect(c.read(businessLocalLedgerScopeProvider)?.writerSession, isNull);
      await _select(ledger: true);
      c.read(branchEpochProvider.notifier).state++;
      expect(c.read(businessLocalLedgerScopeProvider)?.branchId, _branch);
      expect(c.read(salesApiProvider), isA<LocalSalesApi>());
      (c.read(authProvider.notifier) as _SignedIn).setUser(
        _owner.copyWith(role: 'employee', id: _sibling),
      );
      expect(c.read(directoryPilotAccessProvider), isNull);
      expect(c.read(businessLocalLedgerScopeProvider), isNull);
    },
    skip: !_enabled,
  );

  for (final (online, always) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      'original screens reopen with no HTTP: ${online ? 'connected' : 'offline'} '
      'return, ${always ? 'allow always' : 'allow once'}',
      (tester) async {
        final lab = _Round();

        // Widget reads may already hold the store lock in Flutter's fake-clock
        // zone. Pump those continuations while real FFI work finishes.
        Future<void> withDisk(Future<void> Function() action) async {
          var finished = false;
          Object? error;
          StackTrace? trace;
          await tester.runAsync(() async {
            unawaited(
              action().then<void>(
                (_) => finished = true,
                onError: (Object e, StackTrace s) {
                  error = e;
                  trace = s;
                  finished = true;
                },
              ),
            );
          });
          for (var i = 0; !finished && i < 240; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 12)),
            );
          }
          if (!finished)
            fail('The encrypted ledger did not finish its disk work');
          if (error != null) Error.throwWithStackTrace(error!, trace!);
        }

        Future<T> withDiskResult<T>(Future<T> Function() action) async {
          late T result;
          await withDisk(() async {
            result = await action();
          });
          return result;
        }

        await tester.runAsync(() async {
          await lab.setup();
          await _select(ledger: true);
          await BranchScope.load();
          await lab.rememberAccess();
          await AppLocalizations.preload('ar');
        });
        tester.view.physicalSize = const Size(760, 2050);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // Product selection plays a sound. Supply native acknowledgements so
        // this widget test doesn't depend on platform audio or its timeouts.
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const audio = 'xyz.luan/audioplayers';
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        messenger.setMockMethodCallHandler(
          paths,
          (call) async => lab.root.path,
        );
        addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
        for (final name in [
          '$audio.global',
          '$audio.global/events',
          audio,
          for (final id in [
            'fyona_scan_ok',
            'fyona_scan_bad',
            'fyona_recon_eq',
          ])
            '$audio/events/$id',
        ]) {
          final channel = MethodChannel(name);
          messenger.setMockMethodCallHandler(channel, (call) async {
            final event = switch (call.method) {
              'seek' => {'event': 'audio.onSeekComplete'},
              'setSourceUrl' ||
              'setSourceBytes' => {'event': 'audio.onPrepared', 'value': true},
              'resume' => {'event': 'audio.onComplete'},
              _ => null,
            };
            if (name == audio && event != null) {
              final player = call.arguments['playerId'];
              final reply = const StandardMethodCodec().encodeSuccessEnvelope(
                event,
              );
              if (call.method == 'resume') {
                Timer.run(
                  () => messenger.handlePlatformMessage(
                    '$audio/events/$player',
                    reply,
                    null,
                  ),
                );
              } else {
                unawaited(
                  messenger.handlePlatformMessage(
                    '$audio/events/$player',
                    reply,
                    null,
                  ),
                );
              }
            }
            return null;
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        }

        final router = GoRouter(
          initialLocation: RouteNames.banks,
          routes: [
            GoRoute(
              path: RouteNames.dashboard,
              builder: (_, _) => const Scaffold(body: BusinessRecentOps()),
            ),
            GoRoute(
              path: RouteNames.businessTransactions,
              builder: (_, _) => const BusinessTransactionsPage(),
            ),
            GoRoute(
              path: RouteNames.businessTransactionDetails,
              builder: (_, state) {
                expect(state.uri.query, isEmpty);
                final target = state.extra! as LocalCommerceTarget;
                return BusinessTransactionDetailsPage(
                  sourceType: target.kind!,
                  sourceId: target.id,
                  localTarget: target,
                );
              },
            ),
            GoRoute(
              path: RouteNames.businessIncomeExpense,
              builder: (_, _) => const BusinessIncomeExpensePage(),
            ),
            GoRoute(
              path: RouteNames.banks,
              builder: (_, _) => const Scaffold(body: BusinessBanksPage()),
            ),
            GoRoute(
              path: RouteNames.inventoryProductEdit,
              builder: (_, _) => const ProductFormPage(),
            ),
            GoRoute(
              path: RouteNames.inventoryProduct,
              builder: (_, state) {
                final target = state.extra! as LocalCommerceTarget;
                return ProductDetailPage(id: target.id, localTarget: target);
              },
            ),
            GoRoute(
              path: RouteNames.inventoryProductMovements,
              builder: (_, state) {
                expect(state.uri.query, isEmpty);
                final target = state.extra! as LocalCommerceTarget;
                return ProductMovementsPage(id: target.id, localTarget: target);
              },
            ),
            GoRoute(
              path: RouteNames.salesAdd,
              builder: (_, _) => const SaleInvoicePage(),
            ),
            GoRoute(
              path: RouteNames.purchasesAdd,
              builder: (_, _) => const PurchaseInvoicePage(),
            ),
            GoRoute(
              path: RouteNames.invoicesView,
              builder: (_, state) {
                final target = state.extra! as LocalCommerceTarget;
                return InvoiceViewPage(
                  id: target.id,
                  type: target.kind!,
                  localCommerce: target,
                );
              },
            ),
            GoRoute(
              path: RouteNames.returns,
              builder: (_, _) => const ReturnsPage(),
            ),
            GoRoute(
              path: RouteNames.returnsAdd,
              builder: (_, _) => const ReturnCreatePage(kind: 'sale_return'),
            ),
            GoRoute(
              path: RouteNames.returnsPickInvoice,
              builder: (_, _) => const InvoicePickerPage(kind: 'sale_return'),
            ),
            GoRoute(
              path: RouteNames.returnsView,
              builder: (_, state) {
                final target = state.extra! as LocalCommerceTarget;
                return ReturnViewPage(
                  id: target.id,
                  kind: target.kind!,
                  localTarget: target,
                );
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        Future<void> mount() => tester.pumpWidget(
          UncontrolledProviderScope(
            container: lab.container,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
            ),
          ),
        );

        Future<void> until(Finder target) async {
          for (var i = 0; i < 120; i++) {
            await tester.pump(const Duration(milliseconds: 45));
            if (target.evaluate().isNotEmpty) return;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 12)),
            );
          }
          expect(
            target,
            findsWidgets,
            reason: tester
                .widgetList<Text>(find.byType(Text))
                .map((w) => w.data)
                .whereType<String>()
                .take(28)
                .join(' | '),
          );
        }

        Future<void> tap(Finder target) async {
          await until(target);
          await tester.ensureVisible(target);
          final visible = target.hitTestable();
          await until(visible);
          await tester.tap(visible);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 360));
        }

        Finder field(String caption) => find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText == caption ||
                  w.decoration?.labelText == caption),
        );
        Finder exact(String value) =>
            find.byWidgetPredicate((w) => w is Text && w.data == value);
        Finder sheet(String label) => find.descendant(
          of: find.byType(BottomSheet),
          matching: exact(label),
        );
        Future<void> enter(String label, String text) async {
          final target = field(label);
          await until(target);
          await tester.ensureVisible(target);
          await tester.enterText(target, text);
          tester.testTextInput.hide();
          await tester.pump();
        }

        Future<void> doubleSubmit(
          Finder label, {
          bool bank = false,
          bool cut = false,
        }) async {
          await until(label);
          final button = find
              .ancestor(
                of: label,
                matching: bank
                    ? find.byType(ElevatedButton)
                    : find.byType(FilledButton),
              )
              .first;
          final handler = bank
              ? tester.widget<ElevatedButton>(button).onPressed!
              : tester.widget<FilledButton>(button).onPressed!;
          // Use the real handler twice before Flutter has a chance to rebuild.
          await tester.runAsync(() async {
            handler();
            if (cut) lab.connectivity.debugSetOnline(false);
            handler();
          });
          await tester.pump();
          expect(
            find.descendant(
              of: button,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsNothing,
          );
        }

        Future<void> accountPicker(
          String button, {
          String bank = _bankName,
        }) async {
          await tap(exact(button));
          await tap(sheet(bank));
          await tap(sheet(currencyLabel(_currency)));
        }

        Future<void> runRound() async {
          await mount();
          await tap(exact('إضافة بنك'));
          await enter('اسم البنك', _bankName);
          await enter('رصيد البداية', '1000');
          await tap(field('اختر العملة'));
          final selector = find.byType(CurrencySelector);
          await tester.enterText(
            find.descendant(of: selector, matching: find.byType(TextField)),
            _currency,
          );
          tester.testTextInput.hide();
          await tester.pump();
          await tap(
            find.descendant(
              of: selector,
              matching: exact(currencyName(_currency)),
            ),
          );
          expect(tester.widget<CurrencySelector>(selector).value, _currency);
          await doubleSubmit(exact('إضافة'), bank: true);
          await until(exact(_bankName));
          expect(field('اسم البنك'), findsNothing);

          // All pickers use the bank commit, not a legacy cash read.
          await withDisk(() async {
            for (final provider in [
              saleAccountsProvider,
              purchaseAccountsProvider,
              returnAccountsProvider,
            ]) {
              // The new bank, next to the branch's own cash account.
              final banks = [
                for (final row in await lab.container.read(provider.future))
                  row['bank'],
              ];
              expect(banks.where((b) => b == _bankName), hasLength(1));
            }
          });

          lab.connectivity.debugSetOnline(true);
          router.go(RouteNames.inventoryProductEdit);
          await enter('اسم المنتج', _productName);
          await enter('الكمية الحالية', '5');
          await doubleSubmit(exact('حفظ'));
          await until(find.byType(ProductDetailPage));
          await until(exact(_productName));
          final product = tester.widget<ProductDetailPage>(
            find.byType(ProductDetailPage),
          );
          final productTarget = product.localTarget!;
          lab.connectivity.debugSetOnline(false);

          Future<void> invoice({required bool purchase}) async {
            router.go(purchase ? RouteNames.purchasesAdd : RouteNames.salesAdd);
            await tap(
              exact(purchase ? 'إضافة منتجات الشراء' : 'إضافة منتجات البيع'),
            );
            await tap(sheet('بحث وتحديد منتجات'));
            await tester.pump(const Duration(milliseconds: 400));
            await tap(sheet(_productName));
            await tap(sheet('حفظ (1)'));
            await tap(exact('تحديد نسبة الدفع'));
            await tap(sheet('دفع كامل'));
            await accountPicker('تحديد الحساب');
            final prices = find.byWidgetPredicate(
              (w) =>
                  w is TextField &&
                  (w.decoration?.labelText?.startsWith(
                        purchase ? 'سعر الشراء' : 'السعر',
                      ) ??
                      false),
            );
            await until(prices);
            await tester.enterText(prices.first, purchase ? '200' : '13500');
            tester.testTextInput.hide();
            await tester.pump();
            if (purchase) lab.connectivity.debugSetOnline(true);
            await doubleSubmit(
              exact(purchase ? 'إصدار فاتورة الشراء' : 'إصدار الفاتورة'),
              cut: purchase,
            );
            final success = find.byType(
              purchase ? PurchaseSuccessDialog : SaleSuccessDialog,
            );
            await until(success);
            expect(
              find.descendant(
                of: success,
                matching: find.textContaining(
                  purchase
                      ? 'تم إصدار فاتورة الشراء بنجاح'
                      : 'تم إصدار الفاتورة',
                ),
              ),
              findsOneWidget,
            );
            await tap(exact('عرض المزيد عن الفاتورة'));
            await tap(exact('عرض الفاتورة'));
            await until(find.byType(InvoiceViewPage));
            await until(find.textContaining(purchase ? 'PUR-' : 'INV-'));
            expect(
              GoRouterState.of(
                tester.element(find.byType(InvoiceViewPage)),
              ).uri.query,
              isEmpty,
            );
          }

          await invoice(purchase: false);
          await invoice(purchase: true);
          final refundAccount = await withDiskResult(() async {
            final scope = lab.container.read(businessLocalLedgerScopeProvider)!;
            final grant = BusinessLedgerAccess(scope, {
              BusinessLedgerAction.createBank,
            });
            return lab.store.withLedger(
              grant,
              () => scope,
              (db) => db.createAccount(
                grant,
                commandId: const Uuid().v4(),
                bankName: _refundBank,
                accountName: _refundBank,
                accountNumber: '102',
                currency: _currency,
                openingMinor: 300000,
              ),
            );
          });
          lab.connectivity.debugSetOnline(online);
          router.go(RouteNames.returns);
          await until(exact('المرتجعات'));
          await tap(exact('ارجاع منتجات من قبل العميل'));
          await tap(exact('اختر الفاتورة'));
          final invoiceNumber = find.textContaining('INV-');
          await until(invoiceNumber);
          await tap(invoiceNumber.first);
          await tap(exact('تحديد الكل'));
          await accountPicker('اختر الحساب', bank: _refundBank);
          await doubleSubmit(exact('تأكيد المرتجع'));
          await until(exact(AppLocalizations.t('payNegOnce')));
          expect(
            exact(AppLocalizations.t('payNegAlways')).hitTestable(),
            findsOneWidget,
          );
          expect(find.byType(ReturnSuccessDialog), findsNothing);
          await tap(exact(AppLocalizations.t('payNegCancel')));
          await withDisk(() async {
            final scope = lab.container.read(businessLocalLedgerScopeProvider)!;
            final grant = BusinessLedgerAccess(scope, {
              BusinessLedgerAction.readBank,
              BusinessLedgerAction.changeNegativePolicy,
            });
            final accounts = await lab.store.withLedger(
              grant,
              () => scope,
              (db) => db.accounts(grant),
            );
            expect(
              accounts.singleWhere(
                (a) => a['bank_name'] == _refundBank,
              )['balance_minor'],
              300000,
            );
            expect(
              await lab.container.read(returnsApiProvider).list(),
              isEmpty,
            );
            expect(
              await lab.store.withLedger(
                grant,
                () => scope,
                (db) => db.savedAllowNegative(grant),
              ),
              isNull,
            );
          });
          await doubleSubmit(exact('تأكيد المرتجع'));
          await until(exact(AppLocalizations.t('payNegOnce')));
          await tap(
            exact(AppLocalizations.t(always ? 'payNegAlways' : 'payNegOnce')),
          );
          await until(find.byType(ReturnSuccessDialog));
          expect(find.textContaining('تم تسجيل المرتجع #RTN-'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(lab.attempted, isEmpty);

          // Reopening offline proves the refund wasn't waiting in a network queue.
          lab.connectivity.debugSetOnline(false);
          await tester.pumpWidget(const SizedBox.shrink());
          // Dispose the providers and reopen the same encrypted file with the
          // retained scope, no caches, no seeded accounts and no connectivity.
          await withDisk(() async {
            await lab.closeStore();
            await BranchScope.load();
            lab.reopen();
            expect(
              lab.container.read(businessLocalLedgerScopeProvider)?.branchId,
              _branch,
            );
            final rows = await lab.container
                .read(inventoryApiProvider)
                .listProducts();
            expect(rows.single['name'], _productName);
            expect(rows.single['stock'], 6);
            final invoices = lab.container.read(invoicesApiProvider);
            for (final (kind, total, paid) in [
              ('sale', 13500, 0),
              ('purchase', 200, 200),
            ]) {
              final row = (await invoices.list(type: kind)).single;
              final doc = await invoices.getInvoice('${row['id']}');
              expect(doc['total'], total);
              expect(doc['paid_amount'], paid);
              expect((doc['payments'] as List).single['amount'], total);
              expect(doc['balance'], 0);
            }
            expect(
              (await lab.container.read(returnsApiProvider).list())
                  .single['total'],
              13500,
            );
            expect(
              (await lab.container.read(
                saleAccountsProvider.future,
              )).singleWhere((a) => a['bank'] == _refundBank)['balance'],
              '-10500.00',
            );
            final scope = lab.container.read(businessLocalLedgerScopeProvider)!;
            final grant = BusinessLedgerAccess(scope, {
              BusinessLedgerAction.changeNegativePolicy,
              BusinessLedgerAction.readBank,
            });
            await lab.store.withLedger(grant, () => scope, (db) async {
              expect(
                await db.savedAllowNegative(grant),
                always ? isTrue : isNull,
              );
              final legs = await db.statement(
                grant,
                refundAccount['id'] as String,
              );
              expect(legs.map((leg) => leg['delta_minor']), [-1350000, 300000]);
            });
          });
          router.go(RouteNames.returns);
          await mount();
          await tap(find.textContaining('RTN-'));
          await until(find.byType(ReturnViewPage));
          await until(
            find.descendant(
              of: find.byType(ReturnViewPage),
              matching: find.textContaining('RTN-'),
            ),
          );
          expect(
            GoRouterState.of(
              tester.element(find.byType(ReturnViewPage)),
            ).uri.query,
            isEmpty,
          );
          router.go(RouteNames.dashboard);
          await until(exact('أحدث العمليات'));
          final recentReturn = find.descendant(
            of: find.byType(BusinessRecentOps),
            matching: find.textContaining('RTN-'),
          );
          await until(recentReturn);
          expect(recentReturn, findsOneWidget);
          await tap(recentReturn);
          await until(find.byType(BusinessTransactionDetailsPage));
          await tap(exact(AppLocalizations.t('viewInvoice')));
          await until(
            find.descendant(
              of: find.byType(ReturnViewPage),
              matching: find.textContaining('RTN-'),
            ),
          );
          router.go(RouteNames.businessIncomeExpense);
          final manualPage = find.byType(BusinessIncomeExpensePage);
          await until(manualPage);
          await until(
            find.descendant(
              of: manualPage,
              matching: exact(AppLocalizations.t('txEmpty')),
            ),
          );
          expect(
            find.descendant(
              of: manualPage,
              matching: find.textContaining('RTN-'),
            ),
            findsNothing,
          );
          router.go(RouteNames.businessTransactions);
          Finder transaction(String prefix) => find.descendant(
            of: find.byType(BusinessTransactionsPage),
            matching: find.textContaining(prefix),
          );
          await until(transaction('RTN-'));
          expect(transaction('INV-'), findsWidgets);
          expect(transaction('PUR-'), findsWidgets);
          for (final prefix in ['INV-', 'PUR-']) {
            await tap(transaction(prefix).first);
            await tap(exact(AppLocalizations.t('viewInvoice')));
            await until(
              find.descendant(
                of: find.byType(InvoiceViewPage),
                matching: find.textContaining(prefix),
              ),
            );
            router.go(RouteNames.businessTransactions);
            await until(transaction('RTN-'));
          }
          router.go(RouteNames.inventoryProduct, extra: productTarget);
          await tap(exact('${AppLocalizations.t('invShowBatches')} (2)'));
          final batches = find.byType(BottomSheet);
          Finder batchText(String fragment) => find.descendant(
            of: batches,
            matching: find.textContaining(fragment),
          );
          expect(
            find.descendant(of: batches, matching: exact(_productName)),
            findsNWidgets(2),
          );
          expect(
            batchText('${AppLocalizations.t('invBatchReceived')}: 5'),
            findsOneWidget,
          );
          expect(
            batchText('${AppLocalizations.t('invBatchReceived')}: 1'),
            findsOneWidget,
          );
          expect(
            batchText('${AppLocalizations.t('invPurchasePrice')}: 200'),
            findsOneWidget,
          );
          Navigator.of(tester.element(batches)).pop();
          await tester.pumpAndSettle();
          await tap(exact('إحصائيات المنتج'));
          final stats = find.byType(ProductMovementsPage);
          await until(
            find.descendant(
              of: stats,
              matching: exact(AppLocalizations.t('invStatPurchases')),
            ),
          );
          expect(
            find.descendant(
              of: stats,
              matching: exact(AppLocalizations.t('invLoadError')),
            ),
            findsNothing,
          );
          expect(lab.attempted, isEmpty);

          // A purchase movement opens a tidy sheet: the invoice number on its
          // own line, short (PUR-1 in order once the branch's documents were
          // read, else PUR-XXXXXXXX), never inside the notes; «عرض
          // الفاتورة» opens the Business invoice screen, not the old one.
          await tap(find.descendant(
            of: stats,
            matching: exact(AppLocalizations.t('invMovementPurchase')),
          ).first);
          final docNo = find.byKey(const ValueKey('movement-doc-number'));
          await until(docNo);
          final shown = tester.widget<Text>(docNo).data!;
          expect(shown, matches(RegExp(r'^PUR-([0-9]+|[0-9A-F]{8})$')));
          expect(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: exact(AppLocalizations.t('saleNotes')),
            ),
            findsNothing,
          );
          await tap(find.byKey(const ValueKey('movement-open-document')));
          await until(
            find.descendant(
              of: find.byType(InvoiceViewPage),
              matching: find.textContaining('PUR-'),
            ),
          );
          expect(lab.attempted, isEmpty);

          // Deliberately keep an old detail mounted across a connected branch
          // change: neither provider reload nor a later frame may send its ID.
          router.go(RouteNames.inventoryProduct, extra: productTarget);
          await until(exact(_productName));
          await tester.pump(const Duration(milliseconds: 360));
          lab.connectivity.debugSetOnline(true);
          await withDisk(() => _select(ledger: false, branch: _sibling));
          lab.container.read(branchEpochProvider.notifier).state++;
          await until(exact('غير مصرح بالوصول'));
          expect(exact(_productName), findsNothing);
          await withDisk(() async {
            await expectLater(
              lab.container.read(
                productDetailProvider((
                  id: product.id,
                  target: productTarget,
                )).future,
              ),
              throwsA(isA<DirectoryAccessDenied>()),
            );
          });
          expect(tester.takeException(), isNull);
          expect(lab.attempted, isEmpty);
        }

        try {
          await runRound();
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await withDisk(lab.dispose);
        }
      },
      skip: !_enabled,
    );
  }

  testWidgets(
    'original customer and supplier buttons use only scoped consent transport',
    (tester) async {
      const entries = {
        DirectoryPartyKind.customer: 'عميل الاختبار',
        DirectoryPartyKind.supplier: 'مورد الاختبار',
      };
      final localIds = <DirectoryPartyKind, String>{};
      final posted = <String, String>{};
      const code = {'code': '123456'};
      const phone = {'phone': '771234567', 'country': 'YE'};
      final lab = _Round(
        onShareRequest: (request, handler) {
          expect(request.method, 'POST');
          expect(
            request.headers['X-Branch-Token'],
            _selectionToken(branch: _branch, ledger: true),
          );
          final parts = request.uri.pathSegments;
          expect(parts.take(4), ['api', 'v1', 'business', 'party-sharing']);
          final data = Map<String, dynamic>.from(request.data as Map);
          if (parts.last == 'lookup') {
            final kind = data.remove('kind') as String;
            expect(data, kind == 'customer' ? code : phone);
            handler.resolve(
              Response(
                requestOptions: request,
                data: {
                  'data': {'found': true, 'name': 'حساب تجريبي'},
                },
              ),
            );
            return;
          }
          expect(parts.last, 'invite');
          final kind = DirectoryPartyKind.values.byName(parts[4]);
          final shareKey = parts[5];
          expect(isDirectoryId(shareKey), isTrue);
          expect(localIds.values, isNot(contains(shareKey)));
          expect(data, kind == DirectoryPartyKind.customer ? code : phone);
          expect(posted.containsKey(kind.name), isFalse);
          posted[kind.name] = shareKey;
          handler.resolve(
            Response(
              requestOptions: request,
              data: {
                'data': {
                  'id': const Uuid().v4(),
                  'status': 'pending',
                  'revision': 1,
                },
              },
            ),
          );
        },
      );
      await tester.runAsync(() async {
        await lab.setup();
        await _select(ledger: true);
        await lab.rememberAccess();
        await AppLocalizations.preload('ar');
        final scope = lab.container.read(businessLocalLedgerScopeProvider)!;
        for (final entry in entries.entries) {
          localIds[entry.key] = (await lab.store.add(
            scope,
            entry.key,
            name: entry.value,
          )).id;
        }
        lab.connectivity.debugSetOnline(true);
      });
      final router = GoRouter(
        initialLocation: RouteNames.customers,
        routes: [
          GoRoute(
            path: RouteNames.customers,
            builder: (_, _) => const CustomersPage(),
          ),
          GoRoute(
            path: RouteNames.suppliers,
            builder: (_, _) => const SuppliersPage(),
          ),
          GoRoute(
            path: '/customers/detail',
            builder: (_, state) => PartyDetailPage(
              id: '',
              isSupplier: false,
              localParty: state.extra as DirectoryPartyReference,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      Future<void> see(Finder target) async {
        for (var i = 0; i < 130; i++) {
          await tester.pump(const Duration(milliseconds: 35));
          if (target.evaluate().isNotEmpty) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 12)),
          );
        }
        expect(target, findsOneWidget);
      }

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: lab.container,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
            ),
          ),
        );
        for (final kind in entries.keys) {
          final supplier = kind == DirectoryPartyKind.supplier;
          final list = supplier
              ? find.byType(SuppliersPage)
              : find.byType(CustomersPage);
          if (supplier) router.go(RouteNames.suppliers);
          await see(
            find.descendant(of: list, matching: find.text(entries[kind]!)),
          );
          final track = find.descendant(
            of: list,
            matching: find.byTooltip(AppLocalizations.t('merchantTrack')),
          );
          await see(track.hitTestable());
          await tester.tap(track);
          final title = find.text(
            AppLocalizations.t(
              supplier ? 'trackAddSupplier' : 'trackAddCustomer',
            ),
          );
          await see(title.hitTestable());
          if (supplier) {
            await tester.tap(find.byKey(const ValueKey('tracking-mode-phone')));
            await tester.pump();
          }
          await tester.enterText(
            find.byKey(
              ValueKey(
                supplier ? 'tracking-phone-input' : 'tracking-code-input',
              ),
            ),
            supplier ? '٧٧١٢٣٤٥٦٧' : '١٢٣٤٥٦',
          );
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          await tester.tap(find.text('بحث'));
          await see(find.text('حساب تجريبي'));
          await tester.tap(find.text('نعم، أرسل الدعوة'));
          await see(find.text(AppLocalizations.t('merchantDone')));
          await tester.pump(const Duration(milliseconds: 350));
          expect(title, findsNothing);
          final scope = lab.container.read(businessLocalLedgerScopeProvider)!;
          final status = await tester.runAsync(
            () => lab.container
                .read(localBusinessPartySharingProvider)!
                .cachedStatus(
                  DirectoryPartyReference(
                    scope: scope,
                    kind: kind,
                    id: localIds[kind]!,
                  ),
                ),
          );
          expect(status?['status'], 'pending');
          await tester.pump(const Duration(seconds: 4));
          await tester.pump(const Duration(milliseconds: 350));
        }
        expect(posted.keys, ['customer', 'supplier']);
        expect(posted.values.toSet(), hasLength(2));
        // The original detail card sees the same persisted invitation offline.
        lab.connectivity.debugSetOnline(false);
        router.go(RouteNames.customers);
        await see(
          find
              .descendant(
                of: find.byType(CustomersPage),
                matching: find.text(entries[DirectoryPartyKind.customer]!),
              )
              .hitTestable(),
        );
        await tester.tap(
          find
              .descendant(
                of: find.byType(CustomersPage),
                matching: find.text(entries[DirectoryPartyKind.customer]!),
              )
              .hitTestable(),
        );
        final invite = find.descendant(
          of: find.byType(PartyDetailPage),
          matching: find.text(AppLocalizations.t('merchantInviteBtn')),
        );
        await see(invite.hitTestable());
        await tester.tap(invite.hitTestable());
        await see(
          find.text(AppLocalizations.t('merchantInvitePendingCustomer')),
        );
        expect(lab.attempted, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(lab.dispose);
      }
    },
    skip: !_enabled,
  );

  test(
    'a branch born offline opens its ledger with the account grant',
    () async {
      final lab = _Round();
      await lab.setup();
      addTearDown(lab.dispose);
      // The owner worked online in the main branch once.
      await _select(ledger: true);
      await lab.rememberAccess();
      final c = lab.container;
      // A branch created offline: never had a live answer of its own.
      await _select(ledger: true, branch: _sibling, claimedBranch: _branch);
      c.read(branchEpochProvider.notifier).state++;
      expect(c.read(businessLocalLedgerScopeProvider)?.branchId, _sibling);
      final home = await c.read(businessReportsApiProvider).home(null, null, _currency);
      expect(home, isA<Map<String, dynamic>>());
      final banks = c.read(businessBanksProvider.notifier);
      await banks.ensureLocalCash([_currency]);
      final local = c.read(localBusinessBankingProvider)!;
      final accounts = await local.accounts();
      expect(accounts.where((a) => a['bank_name'] == 'كاش' && a['currency'] == _currency), hasLength(1));
      // Branch currency customization (profile) saves on the device.
      final before = await local.cashCurrencies();
      await local.saveCashCurrencies(before, {...before, 'SAR', 'USD'}, const Uuid().v4());
      expect(await local.cashCurrencies(), {_currency, 'SAR', 'USD'});
      await local.saveCashCurrencies(
        await local.cashCurrencies(), {_currency, 'SAR'}, const Uuid().v4());
      expect(await local.cashCurrencies(), {_currency, 'SAR'});
    },
    skip: !_enabled,
  );
}
