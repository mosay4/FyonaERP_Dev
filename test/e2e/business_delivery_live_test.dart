// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/branches/data/branch_local_transfers.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_cash_delivery.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_cash_link_delivery.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_party_sharing.dart';
import 'package:fyona_flutter/features/employees/data/employee_device_finance.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';

String get _base => DirectoryPilotBuild.baseUrl;
const _managed = bool.fromEnvironment('FYONA_QA_MANAGED_BUSINESS_PROBE');
const _managedLink = bool.fromEnvironment(
  'FYONA_QA_MANAGED_BUSINESS_LINK_PROBE',
);
const _staffRoute = '/business/employee-finance';
String _id() => const Uuid().v4();

Map<String, dynamic> _claims(String token) =>
    jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(token.split('.')[1])),
          ),
        )
        as Map<String, dynamic>;

Matcher _status(int code) => isA<DioException>().having(
  (e) => e.response?.statusCode,
  'HTTP status',
  code,
);

// Each device has a separate transport and disk. A cut fails the actual request
// without contacting the lab; a lost reply is discarded AFTER the real API
// returns. No interceptor manufactures a successful API response.
final class _Device {
  _Device(Map<String, dynamic> actor)
    : profile = actor['profile'] as Map<String, dynamic>,
      token = actor['token'] as String,
      refresh = actor['refresh'] as String,
      scopeToken = actor['scope'] as String?,
      code = actor['code'] as String,
      login = {
        'email': actor['email'] as String,
        'password': actor['password'] as String,
      } {
    addTearDown(() => http.close(force: true));
    http.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (!request.uri.toString().startsWith('$_base/')) {
            return handler.reject(_cut(request));
          }
          if (!online ||
              request.uri.path.endsWith(dropRequestSuffix ?? '@never')) {
            if (online) dropRequestSuffix = null;
            return handler.reject(_cut(request));
          }
          delivered++;
          handler.next(request);
        },
        onResponse: (reply, handler) {
          if (reply.requestOptions.uri.path.endsWith(
            dropReplySuffix ?? '@never',
          )) {
            dropReplySuffix = null;
            return handler.reject(_cut(reply.requestOptions));
          }
          handler.next(reply);
        },
      ),
    );
  }

  final Map<String, dynamic> profile;
  final Map<String, String> login;
  final String token, refresh, code;
  final String? scopeToken;
  final http = Dio(
    BaseOptions(
      followRedirects: false,
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 19),
    ),
  );
  late final account = profile['id'] as String;
  late final session = _claims(token)['sid'] as String;
  bool online = true;
  String? dropReplySuffix, dropRequestSuffix;
  int delivered = 0;

  DioException _cut(RequestOptions request) => DioException.connectionError(
    requestOptions: request,
    reason: 'Lab link cut',
  );

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? data,
    String? branchToken,
    Map<String, String> headers = const {},
  }) async {
    final response = await http.request<dynamic>(
      '$_base$path',
      data: data,
      options: Options(
        method: method,
        headers: {
          'Authorization': 'Bearer $token',
          'X-Branch-Token': ?branchToken,
          ...headers,
        },
      ),
    );
    final body = response.data;
    return body is Map && body.containsKey('data') ? body['data'] : body;
  }

  Future<_Device> anotherLogin(String name) async {
    final fresh =
        await request(
              '/auth/login',
              method: 'POST',
              data: login,
              headers: {'X-Device-Name': name, 'X-Device-Fingerprint': name},
            )
            as Map;
    expect((fresh['user'] as Map)['id'], account);
    return _Device({
      ...login,
      'code': code,
      'profile': profile,
      'token': fresh['access_token'],
      'refresh': fresh['refresh_token'],
    });
  }

  EmployeeFinanceTransport finance(String branch) {
    final transport = EmployeeFinanceTransport(
      http,
      _base,
      () async => (accessToken: token, sessionId: session),
      () => branch,
    );
    addTearDown(transport.dispose);
    return transport;
  }
}

final class _Lab {
  _Lab(this.frame);
  final Map<String, dynamic> frame;
  String get organization => frame['organization'] as String;
  String get branch => (frame['branch'] as Map)['id'] as String;
  String get sibling => (frame['sibling'] as Map)['id'] as String;
  String get connected => (frame['connected'] as Map)['id'] as String;
  String get employee => frame['employee'] as String;
  Map<String, dynamic> get till => frame['till'] as Map<String, dynamic>;
  _Device device(String role) =>
      _Device((frame['actors'] as Map)[role] as Map<String, dynamic>);
  DirectoryAccess ownerScope(_Device owner) {
    final resolved = resolveDirectoryPilot(
      server: _base,
      accountId: owner.account,
      organizationId: organization,
      selectedOrganizationId: organization,
      selectedBranchId: branch,
      selectedToken: owner.scopeToken,
      readOnly: false,
    );
    expect(resolved?.financialCutover, isTrue);
    return resolved!;
  }

  Future<_Disk> disk(_Device device) async {
    final d = _Disk(
      ownerScope(device),
      device.session,
      await Directory.systemTemp.createTemp('fyona-live-device-'),
    );
    addTearDown(() async {
      await d.store.close();
      await d.root.delete(recursive: true);
    });
    await d.store.remember(
      d.scope,
      frame['subscription'] as Map<String, dynamic>,
    );
    expect(await d.store.entry(d.scope), isNotNull);
    return d;
  }
}

final class _Disk {
  _Disk(this.scope, this.session, this.root);
  final DirectoryAccess scope;
  final String session;
  final Directory root;
  final _keys = FixtureDirectoryKeys();
  late final grant = BusinessLedgerAccess(
    scope,
    BusinessLedgerAction.values.toSet(),
    cashSessionId: session,
  );
  late DirectoryPilotStore store = _open();

  DirectoryPilotStore _open() => DirectoryPilotStore(
    root: () async => root,
    keys: _keys,
    writerSession: (_) async => session,
  );
  Future<void> reopen() async {
    await store.close();
    store = _open();
  }

  Future<T> write<T>(
    Future<T> Function(BusinessLedger, BusinessLedgerAccess) act,
  ) => store.withLedger(grant, () => scope, (db) => act(db, grant));
  Future<int> balance(String accountId) => write(
    (db, g) async =>
        (await db.accounts(
              g,
            )).singleWhere((row) => row['id'] == accountId)['balance_minor']
            as int,
  );
  Future<void> bank(String account, int openingMinor, {bool cash = false}) =>
      write((db, g) async {
        await db.createAccount(
          g,
          commandId: account,
          bankName: cash ? 'كاش' : 'صندوق الرياض',
          accountName: cash ? 'حساب الكاش' : 'صندوق المعمل',
          accountNumber: cash ? 'CASH' : 'QA-001',
          currency: 'SAR',
          openingMinor: openingMinor,
        );
      });
  Future<bool> linkCash(_Device device) => runBusinessCashLink(
    scope: scope,
    sessionId: session,
    store: store,
    current: () => scope,
    request: (path, body) async =>
        await device.request(
              '/business/cash-relay$path',
              branchToken: device.scopeToken,
              method: body == null ? 'GET' : 'POST',
              data: body,
              headers: {'X-Business-Replica-Session': session},
            )
            as Map<String, dynamic>,
  );
  BusinessCashDelivery delivery(_Device d) => BusinessCashDelivery(
    scope: scope,
    sessionId: session,
    store: store,
    current: () => scope,
    send: (_, _) async => fail('v3 account used the v2 route'),
    sendV3: (action, body) async =>
        await d.request(
              '/business/cash-relay/v3/${action.name}',
              method: 'POST',
              data: body,
              branchToken: d.scopeToken,
              headers: {'X-Business-Replica-Session': d.session},
            )
            as Map<String, dynamic>,
  );
}

void main() {
  final fixture = Platform.environment['FYONA_QA_SCENARIO_FIXTURE'];
  late _Lab lab;
  setUp(() async {
    expect(DirectoryPilotBuild.signupEnabled, isTrue);
    expect(
      _base,
      _managed
          ? DirectoryPilotBuild.stagingBase
          : DirectoryPilotBuild.loopbackBase,
    );
    expect(fixture, startsWith('/tmp/opencode/fyona-business-run.'));
    final frame =
        jsonDecode(await File(fixture!).readAsString()) as Map<String, dynamic>;
    expect(frame['base'], _base);
    expect(frame['managed_probe'] ?? false, _managed);
    expect(frame['managed_link_probe'] ?? false, _managedLink);
    lab = _Lab(frame);
  });

  test(
    'offline store to live buyer and supplier debts, chat, and notifications',
    () async {
      final owner = lab.device('owner'), second = lab.device('owner_b');
      final buyer = lab.device('buyer'), supplier = lab.device('supplier');
      final store = await lab.disk(owner);
      final bank = _id();
      final parties = <DirectoryPartyReference, _Device>{};
      for (final (kind, name, target) in [
        (DirectoryPartyKind.customer, 'مها - عميلة الرياض', buyer),
        (DirectoryPartyKind.supplier, 'مستودع الأفق - المورد', supplier),
      ]) {
        final p = await store.store.add(store.scope, kind, name: name);
        parties[DirectoryPartyReference(
              scope: store.scope,
              kind: kind,
              id: p.id,
            )] =
            target;
      }
      final (customer, vendor) = (parties.keys.first, parties.keys.last);
      BusinessPartySharing sharing() => BusinessPartySharing(
        owner.http,
        store.store,
        store.scope,
        () => store.scope,
        () => owner.scopeToken,
        (_) => true,
        () => owner.online,
        () {},
        () async => (accessToken: owner.token, sessionId: owner.session),
      );
      var share = sharing();
      addTearDown(() => share.dispose());
      final links = <_Device, String>{};
      for (final row in parties.entries) {
        final (party, recipient) = (row.key, row.value);
        final contact = {'code': recipient.code};
        expect((await share.lookup(party, contact))['found'], isTrue);
        if (recipient == buyer) {
          owner.dropReplySuffix = '/invite';
          await expectLater(
            share.invite(party, contact),
            throwsA(isA<DioException>()),
          );
          await share.refresh();
        }
        await share.invite(party, contact);
        final state = await share.cachedStatus(party);
        final link = state['id'] as String;
        links[recipient] = link;
        expect(state['status'], 'pending');
        final inbox = await recipient.request('/me/merchant-invites') as List;
        expect(inbox.map((i) => (i as Map)['link_id']), [link]);
        await expectLater(
          recipient.request('/me/merchant-links/$link/debt-overview'),
          throwsA(_status(400)),
        );
        final accepted =
            await recipient.request(
                  '/me/merchant-invites/$link/accept',
                  method: 'POST',
                )
                as Map;
        expect(accepted['status'], 'accepted');
      }
      final buyerLink = links[buyer]!, supplierLink = links[supplier]!;
      Future<Map> debts(_Device target, String link) async =>
          await target.request(
                '/me/merchant-links/$link/debt-overview?currency=SAR',
              )
              as Map;
      expect((await debts(buyer, buyerLink))['remaining_total'], isNull);
      expect((await debts(supplier, supplierLink))['remaining_total'], isNull);
      await expectLater(debts(supplier, buyerLink), throwsA(_status(400)));
      owner.online = false;
      final writesAreLocal = owner.delivered;
      await store.bank(bank, 300000);
      final goods =
          (await store.write(
                (db, g) => db.createCommerceProduct(
                  g,
                  commandId: _id(),
                  name: 'طقم مفكات',
                  unit: 'طقم',
                  costPrice: '42.75',
                  price: '85.50',
                  stock: '12',
                ),
              ))['id']
              as String;
      Future<Map<String, Object?>> invoice({
        required String command,
        required DirectoryPartyReference party,
        required String quantity,
        int paid = 0,
      }) {
        final purchase = party.kind == DirectoryPartyKind.supplier;
        return store.write(
          (db, g) => db.issueCommerceDocument(
            g,
            kind: purchase
                ? BusinessInvoiceKind.purchase
                : BusinessInvoiceKind.sale,
            commandId: command,
            partyId: party.id,
            currency: 'SAR',
            lines: [
              CommerceIssueLine(
                description: 'طقم مفكات',
                productId: goods,
                quantity: quantity,
                unitMinor: purchase ? 4275 : 8550,
              ),
            ],
            payments: [
              if (paid > 0)
                CommerceIssuePayment(
                  accountId: bank,
                  originalMinor: paid,
                  paymentCurrency: 'SAR',
                ),
            ],
          ),
        );
      }

      final purchase = await invoice(
        command: _id(),
        party: vendor,
        quantity: '20',
        paid: 35000,
      );
      final saleCommand = _id();
      final sale = await invoice(
        command: saleCommand,
        party: customer,
        quantity: '6',
        paid: 20000,
      );
      expect(
        await invoice(
          command: saleCommand,
          party: customer,
          quantity: '6',
          paid: 20000,
        ),
        sale,
      );
      expect(await store.balance(bank), 285000);
      Future<num> stock() => store.write(
        (db, g) async =>
            (await db.commerceInventoryProduct(g, goods))!['stock'] as num,
      );
      expect(await stock(), 26);
      await share.refresh();
      expect(owner.delivered, writesAreLocal);
      expect((await debts(buyer, buyerLink))['published_at'], isNull);
      share.dispose();
      await store.reopen();
      share = sharing();
      expect(await stock(), 26);
      expect(await store.balance(bank), 285000);
      expect(
        (await store.write(
          (db, g) => db.debts(g, customer),
        )).single['remaining_minor'],
        31300,
      );
      owner.online = true;
      final watch = Stopwatch()..start();
      owner.dropReplySuffix = '/snapshot';
      await share.refresh(); // At least one committed response is discarded.
      final firstBuyer = await debts(buyer, buyerLink);
      expect(firstBuyer['remaining_total'], '313.00');
      final firstVendor = await debts(supplier, supplierLink);
      expect(firstVendor['remaining_total'], '505.00');
      await share.refresh();
      expect(await debts(buyer, buyerLink), firstBuyer);
      expect(await debts(supplier, supplierLink), firstVendor);
      expect(
        jsonEncode([firstBuyer, firstVendor]),
        isNot(contains(sale['id'] as String)),
      );
      expect(
        jsonEncode([firstBuyer, firstVendor]),
        isNot(contains(purchase['id'] as String)),
      );
      expect(jsonEncode(firstBuyer), isNot(contains(vendor.id)));
      // The second owner device is not a full commerce replica.
      final otherDisk = await lab.disk(second);
      expect(
        await otherDisk.store.search(otherDisk.scope, customer.kind, ''),
        isEmpty,
      );
      print(
        'PASS trade: 26 units and SAR 2850.00 cash after reopen; '
        'isolated SAR 313.00/505.00 customer/supplier projections '
        'in ${watch.elapsedMilliseconds} ms from the explicit reconnect cycle.',
      );

      owner.online = false;
      await invoice(command: _id(), party: customer, quantity: '2');
      expect(await stock(), 24);
      await share.refresh();
      expect(await debts(buyer, buyerLink), firstBuyer);
      owner.online = true;
      await share.refresh();
      expect((await debts(buyer, buyerLink))['remaining_total'], '484.00');
      expect(await debts(supplier, supplierLink), firstVendor);
      final buyerB = await buyer.anotherLogin('business-qa-buyer-b');
      expect(await debts(buyerB, buyerLink), await debts(buyer, buyerLink));
      final messageRoute = '/chat/$buyerLink/messages';
      final message = {
        'text': 'تأكيد طلب أطقم المفكات. المتبقي 484.00 ريال.',
        'side': 'merchant',
        'client_message_id': _id(),
      };
      final live = buyer.request('/chat/$buyerLink/updates?side=personal');
      final liveWatch = Stopwatch()..start();
      owner.dropReplySuffix = '/messages';
      await expectLater(
        owner.request(messageRoute, method: 'POST', data: message),
        throwsA(isA<DioException>()),
      );
      final retry =
          await owner.request(messageRoute, method: 'POST', data: message)
              as Map;
      expect(retry['duplicate'], isTrue);
      final id = (retry['message'] as Map)['id'];
      final pushed = await live.timeout(const Duration(seconds: 10)) as Map;
      expect((pushed['messages'] as List).single['id'], id);
      expect(liveWatch.elapsedMilliseconds, lessThan(10000));
      expect(
        ((await second.request('$messageRoute?side=merchant')
                    as Map)['messages']
                as List)
            .single['id'],
        id,
      );
      expect(
        ((await buyerB.request('$messageRoute?side=personal')
                    as Map)['messages']
                as List)
            .single['id'],
        id,
      );
      await expectLater(
        supplier.request('$messageRoute?side=personal'),
        throwsA(_status(403)),
      );
      final notifications =
          '/debt-notifications?side=personal&link_id=$buyerLink';
      final notice =
          ((await buyerB.request(notifications) as Map)['items'] as List)
                  .where((n) => n['event_id'] == 'chat:$id')
                  .single
              as Map;
      expect(notice['is_read'], isFalse);
      await buyer.request('/chat/$buyerLink/read', method: 'POST');
      final mirrored =
          ((await buyerB.request(notifications) as Map)['items'] as List)
                  .singleWhere((n) => n['id'] == notice['id'])
              as Map;
      expect(mirrored['is_read'], isTrue);
      expect((await supplier.request(notifications) as Map)['items'], isEmpty);
      final supplierMessage = '/chat/$supplierLink/messages';
      final answer =
          await supplier.request(
                supplierMessage,
                method: 'POST',
                data: {
                  'side': 'personal',
                  'text': 'تم تسليم عشرين طقمًا',
                  'client_message_id': _id(),
                },
              )
              as Map;
      expect(
        ((await second.request('$supplierMessage?side=merchant')
                    as Map)['messages']
                as List)
            .single['id'],
        (answer['message'] as Map)['id'],
      );
      await buyerB.request(
        '/me/merchant-links/$buyerLink/unlink',
        method: 'POST',
      );
      await expectLater(debts(buyer, buyerLink), throwsA(_status(400)));
      await expectLater(buyer.request(messageRoute), throwsA(_status(403)));
      expect(await debts(supplier, supplierLink), firstVendor);
      print(
        'PASS chat: authorized live delivery in ${liveWatch.elapsedMilliseconds} ms, '
        'one message/notice after reply loss, read state shared, and unlink revoked access.',
      );
    },
    skip: fixture == null,
  );

  test(
    'offline salary and employee advance only reach the authorized reader',
    () async {
      final owner = lab.device('owner'), second = lab.device('owner_b');
      final employee = lab.device('employee'), outsider = lab.device('buyer');
      final disk = await lab.disk(owner);
      final staff = employee.finance(employee.scopeToken!);
      final staffIdentity = (await staff.identity())!;
      final readScope = resolveEmployeeReadSelection(
        server: _base,
        account: employee.account,
        organization: lab.organization,
        branch: lab.branch,
        token: employee.scopeToken,
        allMode: false,
      )!;
      final workspace = DirectoryWorkspace(
        server: _base,
        organizationId: lab.organization,
        accountId: employee.account,
      );
      final root = await Directory.systemTemp.createTemp(
        'fyona-live-employee-',
      );
      final keys = FixtureDirectoryKeys();
      var cache = BusinessEmployeeReadCache(() async => root, keys);
      addTearDown(() async {
        await cache.close();
        await root.delete(recursive: true);
      });
      final bank = _id(), salary = _id(), advance = _id();
      Future<EmployeeReadCopy?> copy() async => EmployeeReadCopy.parse(
        await cache.read(workspace, lab.branch),
        readScope,
        employee.session,
      );
      Future<void> receive() async {
        final frame = await staff.request(staffIdentity, 'GET', '/me');
        expect(
          EmployeeReadCopy.parse(frame, readScope, employee.session),
          isNotNull,
        );
        await cache.replace(workspace, lab.branch, frame, current: () => true);
      }

      await receive();
      expect((await copy())?.finance, isNull);
      owner.online = false;
      final requests = owner.delivered;
      await disk.bank(bank, 700000);
      Future<Map<String, Object?>> paySalary() => disk.write(
        (db, g) => db.payEmployeeSalary(
          g,
          commandId: salary,
          employeeId: lab.employee,
          amountMinor: 420000,
          accountId: bank,
          currency: 'SAR',
          notes: 'راتب شهر الاختبار',
        ),
      );
      final paid = await paySalary();
      expect(await paySalary(), paid);
      await disk.write(
        (db, g) => db.createEmployeeDebt(
          g,
          commandId: advance,
          employeeId: lab.employee,
          amountMinor: 65000,
          accountId: bank,
          currency: 'SAR',
          note: 'سلفة نقل',
        ),
      );
      expect(await disk.balance(bank), 215000);
      expect(owner.delivered, requests);
      expect(
        (await staff.request(staffIdentity, 'GET', '/me'))['finance'],
        isNull,
      );
      await disk.reopen();
      final transport = owner.finance(owner.scopeToken!);
      final identity = (await transport.identity())!;
      Future<Map> packet() async {
        final reply = await transport.request(identity, 'GET', '/owner');
        final target = (reply['targets'] as List).single as Map;
        expect(target['employee_id'], lab.employee);
        return {
          'expected_version': target['version'],
          'grant_revision': target['grant_revision'],
          'receipts': await disk.write(
            (db, g) => db.employeeDeliveryReceipts(g, lab.employee),
          ),
        };
      }

      Future<Map<String, dynamic>> publish(Map body) => transport.request(
        identity,
        'PUT',
        '/owner/${lab.employee}',
        body: body,
      );
      owner.online = true;
      final initial = await packet();
      owner.dropReplySuffix = '/owner/${lab.employee}';
      await expectLater(publish(initial), throwsA(isA<DioException>()));
      expect(await publish(initial), {'version': 1});
      await receive();
      expect(
        ((await copy())!.finance!['salary'] as List).single['amount'],
        '4200.00',
      );
      expect((await copy())!.finance!['balances'], {'SAR': '650.00'});
      employee.online = false;
      await cache.close();
      cache = BusinessEmployeeReadCache(() async => root, keys);
      final retained = (await copy())!.finance!;
      expect((retained['salary'] as List).single['notes'], 'راتب شهر الاختبار');
      expect(
        await cache.read(
          DirectoryWorkspace(
            server: _base,
            accountId: outsider.account,
            organizationId: lab.organization,
          ),
          lab.branch,
        ),
        isNull,
      );
      expect(
        EmployeeReadCopy.parse(
          await cache.read(workspace, lab.branch),
          readScope,
          _id(),
        ),
        isNull,
      );
      owner.online = false;
      await disk.write(
        (db, g) => db.settleEmployeeDebt(
          g,
          commandId: _id(),
          debtId: advance,
          amountMinor: 17525,
          accountId: bank,
          employeeId: lab.employee,
          currency: 'SAR',
        ),
      );
      expect(await disk.balance(bank), 232525);
      owner.online = true;
      expect(await publish(await packet()), {'version': 2});
      expect((await copy())!.finance, retained);
      employee.online = true;
      await receive();
      final current = (await copy())!.finance!;
      expect(current['balances'], {'SAR': '474.75'});
      expect(
        (current['debts'] as List)
            .where((r) => r['kind'] == 'settlement')
            .single['amount'],
        '175.25',
      );
      await expectLater(
        second.request('$_staffRoute/owner', branchToken: second.scopeToken),
        throwsA(_status(403)),
      );
      await expectLater(
        outsider.request('$_staffRoute/me', branchToken: employee.scopeToken),
        throwsA(_status(403)),
      );
      await expectLater(
        employee.request(
          '/employees/me/finance?employee_id=${lab.employee}',
          branchToken: employee.scopeToken,
        ),
        throwsA(_status(409)),
      );
      final inviteRoute = '/job-requests?invite=${lab.frame['invitation']}';
      final notice = await employee.request('/notifications') as Map;
      expect(
        (notice['items'] as List).where((r) => r['route'] == inviteRoute),
        hasLength(1),
      );
      await owner.request(
        '/employees/${lab.employee}/unlink',
        method: 'POST',
        branchToken: owner.scopeToken,
      );
      await expectLater(
        staff.request(staffIdentity, 'GET', '/me'),
        throwsA(_status(403)),
      );
      await cache.replace(workspace, lab.branch, null, current: () => true);
      expect(await copy(), isNull);
      print(
        'PASS employee: SAR 4200.00 salary, SAR 650.00 advance less SAR 175.25 '
        'collection; cash SAR 2325.25, read copy SAR 474.75; link/sessions isolated.',
      );
    },
    skip: fixture == null,
  );

  test(
    'same-owner cash replicas reconcile and acknowledge without duplicating',
    () async {
      final owner = lab.device('owner'), second = lab.device('owner_b');
      final a = await lab.disk(owner), b = await lab.disk(second);
      final account = lab.till['account'] as String;
      if (_managed && !_managedLink) {
        final raw = lab.till['checkpoint'] as Map;
        final checkpoint = (
          sequence: raw['sequence'] as int,
          digest: raw['digest'] as String,
        );
        for (final disk in [a, b]) {
          await disk.bank(account, 150000);
          await disk.write((db, g) async {
            await db.cashSync.provision(
              g,
              account,
              grantVersion: 1,
              allowNegative: false,
            );
            await db.cashSync.bindReplica(
              g,
              sessionId: disk.session,
              checkpoint: checkpoint,
              settlementProtocol: true,
            );
          });
        }
      } else {
        await expectLater(
          owner.request(
            '/business/cash-relay/link',
            branchToken: second.scopeToken,
            headers: {'X-Business-Replica-Session': owner.session},
          ),
          throwsA(_status(403)),
        );
        expect(await b.linkCash(second), isFalse);
        expect(await b.write((db, g) => db.accounts(g)), isEmpty);
        await a.bank(account, 160000, cash: true);
        await a.write(
          (db, g) => db.move(
            g,
            commandId: _id(),
            accountId: account,
            amountMinor: 10000,
            withdraw: true,
          ),
        );
        // Nothing counted yet: no device invents an opening fact.
        expect(await a.linkCash(owner), isFalse);
        await a.write(
          (db, g) => db.checkBankReconciliation(
            g,
            id: _id(),
            entries: [
              (accountId: account, actualMinor: 150000, expectedMinor: 150000),
            ],
            allowed: () => true,
          ),
        );
        owner.dropReplySuffix = '/link/prepared';
        await expectLater(a.linkCash(owner), throwsA(isA<DioException>()));
        await a.reopen();
        expect(await a.linkCash(owner), isFalse);
        await expectLater(
          a.write(
            (db, g) => db.move(
              g,
              commandId: _id(),
              accountId: account,
              amountMinor: 1,
              withdraw: true,
            ),
          ),
          throwsA(isA<BusinessLedgerError>()),
        );
        expect(await b.write((db, g) => db.accounts(g)), isEmpty);
        second.dropReplySuffix = '/link/prepared';
        await expectLater(b.linkCash(second), throwsA(isA<DioException>()));
        expect(await b.write((db, g) => db.accounts(g)), isEmpty);
        await b.reopen();
        expect(await b.linkCash(second), isTrue);
        await a.reopen();
        expect(await a.linkCash(owner), isTrue);
        expect(await a.balance(account), 150000);
        expect(await b.balance(account), 150000);
        expect(
          await a.write((db, g) => db.statement(g, account)),
          hasLength(2),
        );
        expect(
          await b.write((db, g) => db.statement(g, account)),
          hasLength(1),
        );
        expect(await b.linkCash(second), isFalse);
        print(
          'PASS link: matched the existing till without replaying history, '
          'both reservations persisted, lost prepared reply recovered after reopen.',
        );
      }
      final checkpoint = (await a.write(
        (db, g) => db.cashSync.replicaCheckpoint(g, a.session),
      ))!;
      final raw = {
        'sequence': checkpoint.sequence,
        'digest': checkpoint.digest,
      };
      expect(owner.account, second.account);
      expect(owner.session, isNot(second.session));
      final sessionsHeaders = {'X-Refresh-Token': owner.refresh};
      final sessions =
          await owner.request('/auth/sessions', headers: sessionsHeaders)
              as List;
      expect(
        sessions.singleWhere((r) => r['id'] == owner.session)['is_current'],
        isTrue,
      );
      expect(
        sessions.singleWhere((r) => r['id'] == second.session)['is_current'],
        isFalse,
      );
      await second.request(
        '/auth/sessions/${second.session}/name',
        method: 'PUT',
        data: {'custom_name': 'كاشير الرياض QA'},
      );
      expect(
        (await owner.request('/auth/sessions') as List).singleWhere(
          (r) => r['id'] == second.session,
        )['custom_name'],
        'كاشير الرياض QA',
      );
      final staff = lab.device('employee');
      await expectLater(
        staff.request(
          '/business/cash-relay/v3/poll',
          method: 'POST',
          data: {'checkpoint': raw},
          branchToken: staff.scopeToken,
          headers: {'X-Business-Replica-Session': staff.session},
        ),
        throwsA(_status(403)),
      );
      final all =
          await owner.request(
                '/branches/select',
                method: 'POST',
                data: {'organization_id': lab.organization, 'all': true},
              )
              as Map;
      await expectLater(
        owner.request('/banking/accounts', branchToken: all['token'] as String),
        throwsA(_status(409)),
      );
      await expectLater(
        owner.request(
          '/branches/transfers/options?branch_id=${lab.branch}',
          branchToken: owner.scopeToken,
        ),
        throwsA(_status(409)),
      );
      final siblingSelection =
          await owner.request(
                '/branches/select',
                method: 'POST',
                data: {
                  'organization_id': lab.organization,
                  'branch_id': lab.connected,
                },
              )
              as Map;
      final other =
          await owner.request(
                '/branches/transfers/options?branch_id=${lab.connected}',
                branchToken: siblingSelection['token'] as String,
              )
              as Map;
      expect(other.containsKey('accounts'), isTrue);
      print(
        'PASS branch fences: no mixed total or legacy transfer options in the device branch; '
        'connected sibling still served.',
      );

      owner.online = false;
      second.online = false;
      final (aCommand, bCommand) = (_id(), _id());
      Future<void> spend(_Disk disk, String command, int amount) =>
          disk.write((db, g) async {
            await db.move(
              g,
              commandId: command,
              accountId: account,
              amountMinor: amount,
              withdraw: true,
              expenseCategory: 'مصروف تشغيل',
            );
          });
      await spend(a, aCommand, 102575);
      await spend(b, bCommand, 73520);
      await expectLater(
        a.delivery(owner).runOnce(),
        throwsA(isA<DioException>()),
      );
      await b.reopen();
      expect(await a.balance(account), 47425);
      expect(await b.balance(account), 76480);
      owner.online = true;
      owner.dropReplySuffix = '/withdraw';
      await expectLater(
        a.delivery(owner).runOnce(),
        throwsA(isA<DioException>()),
      );
      expect(
        (await a.write((db, g) => db.cashSync.pending(g))).single['command_id'],
        aCommand,
      );
      await a.delivery(owner).runOnce();
      expect(await a.write((db, g) => db.cashSync.pending(g)), isEmpty);
      second.online = true;
      second.dropRequestSuffix = '/ack';
      await expectLater(
        b.delivery(second).runOnce(),
        throwsA(isA<DioException>()),
      );
      expect(
        await b.balance(account),
        47425,
      ); // Applied before the ack was sent.
      await b.reopen();
      await b.delivery(second).runOnce();
      expect(await b.balance(account), 47425);
      expect(await b.write((db, g) => db.cashSync.pending(g)), isEmpty);
      // A count is admitted only at the current authoritative head. The live
      // relay keeps this fresh with its empty-poll cycle before the merchant
      // counts the cash; the second device's decision moved the head to 2.
      await a.delivery(owner).runOnce();

      final recon = _id();
      final counts = [
        (accountId: account, expectedMinor: 47425, actualMinor: 46000),
      ];
      owner.online = false;
      await a.write(
        (db, g) => db.checkBankReconciliation(
          g,
          id: recon,
          entries: counts,
          allowed: () => true,
        ),
      );
      final pending = await a.write(
        (db, g) => db.approveBankReconciliation(
          g,
          id: recon,
          entries: counts,
          allowed: () => true,
        ),
      );
      expect(pending['authority_state'], 'queued');
      expect(await a.balance(account), 47425);
      owner.online = true;
      await a.delivery(owner).runOnce();
      await b.delivery(second).runOnce();
      expect(await a.balance(account), 46000);
      expect(await b.balance(account), 46000);
      print(
        'PASS cash: offline withdrawals SAR 1025.75/735.20 conflicted; '
        'one accepted, then SAR 14.25 reconciliation reached both; '
        'no duplicate after lost response, failed ack, and restart.',
      );

      second.online = false;
      final sealed = _id();
      await spend(b, sealed, 1500);
      final archive = File('${b.root.path}/test.fyonabiz');
      final code = BusinessBackupCode.generate();
      await b.write(
        (db, g) => db.captureBackup(
          g,
          id: _id(),
          destination: archive,
          code: code,
          allowed: () => true,
        ),
      );
      final recovered = await lab.disk(second);
      final restored = await recovered.write(
        (db, g) => db.restoreBackup(
          g,
          source: archive,
          code: code,
          allowed: () => true,
        ),
      );
      expect(restored.hasSharedHistory, isTrue);
      expect(await recovered.balance(account), 44500);
      await expectLater(
        recovered.write(
          (db, g) => db.cashSync.bindReplica(
            g,
            sessionId: second.session,
            checkpoint: checkpoint,
            settlementProtocol: true,
          ),
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      second.online = true;
      final before = second.delivered;
      await expectLater(
        recovered.delivery(second).runOnce(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await recovered.write(
        (db, g) => db.approveRecoveredSync(g, commandId: _id()),
      );
      expect(
        (await recovered.write(
          (db, g) => db.suspendedRequests(g),
        )).single['command_id'],
        sealed,
      );
      expect(await recovered.write((db, g) => db.cashSync.pending(g)), isEmpty);
      await expectLater(
        recovered.delivery(second).runOnce(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(second.delivered, before);
      await second.request(
        '/auth/sessions/logout',
        method: 'POST',
        data: {'session_id': second.session},
      );
      await expectLater(second.request('/auth/me'), throwsA(_status(401)));
      expect(
        (await owner.request('/auth/sessions') as List).any(
          (r) => r['id'] == second.session,
        ),
        isFalse,
      );
      final fresh = await owner.anotherLogin('business-qa-owner-every-device');
      final frame =
          await fresh.request(
                '/branches/select',
                method: 'POST',
                data: {
                  'organization_id': lab.organization,
                  'branch_id': lab.branch,
                },
              )
              as Map;
      final freshScope = frame['token'] as String;
      // Every device of the account may use the branch and ask for the link;
      // only the saved two-sided reservation admits it to the shared till.
      expect(_claims(freshScope)['qa_cash_link'], isNotNull);
      await expectLater(
        fresh.request(
          '/business/cash-relay/v3/poll',
          method: 'POST',
          data: {'checkpoint': raw},
          branchToken: freshScope,
          headers: {'X-Business-Replica-Session': fresh.session},
        ),
        throwsA(_status(403)),
      );
      print(
        'PASS recovery fence: archived SAR 15.00 stayed sealed; revoked session '
        'rejected by live API; a new login alone is not a cash admission.',
      );
    },
    skip: fixture == null,
  );

  test(
    'two enrolled branches use the same offline writer and transfer atomically',
    () async {
      final pair = lab.frame['branch_pair'] as Map<String, dynamic>;
      final owner = _Device(pair);
      final branches = pair['branches'] as List;
      final (from, to, connected) = (
        branches[0]['id'] as String,
        branches[1]['id'] as String,
        branches[2]['id'] as String,
      );
      DirectoryAccess resolve(String branch, String token) =>
          resolveDirectoryPilot(
            server: _base,
            accountId: owner.account,
            organizationId: owner.profile['organization_id'] as String,
            selectedOrganizationId: owner.profile['organization_id'] as String,
            selectedBranchId: branch,
            selectedToken: token,
            readOnly: false,
          )!;
      final a = resolve(from, owner.scopeToken!);
      final b = resolve(to, pair['second_scope'] as String);
      expect(a.transferBranches.keys, unorderedEquals([from, to]));
      expect(a.writerSession, owner.session);
      final area = await Directory.systemTemp.createTemp('fyona-live-pair-');
      final keys = FixtureDirectoryKeys();
      String? sid = owner.session;
      DirectoryPilotStore open() => DirectoryPilotStore(
        root: () async => area,
        keys: keys,
        writerSession: (_) async => sid,
      );
      var store = open();
      addTearDown(() async {
        await store.close();
        await area.delete(recursive: true);
      });
      for (final scope in [a, b]) {
        await store.remember(
          scope,
          pair['subscription'] as Map<String, dynamic>,
        );
      }
      DirectoryAccess? active = a;
      final api = BranchLocalTransfers(
        scope: () => active,
        store: () => store,
        allowed: () => active != null,
        can: (_) => true,
      );
      Future<T> use<T>(
        DirectoryAccess scope,
        Future<T> Function(BusinessLedger, BusinessLedgerAccess) op,
      ) {
        final grant = BusinessLedgerAccess(
          scope,
          BusinessLedgerAction.values.toSet(),
        );
        return store.withLedger(
          grant,
          () => scope,
          (ledger) => op(ledger, grant),
        );
      }

      final (source, target) = (_id(), _id());
      for (final (scope, id, opening) in [
        (a, source, 70000),
        (b, target, 15000),
      ]) {
        await use(
          scope,
          (db, g) => db.createAccount(
            g,
            commandId: id,
            bankName: 'كاش',
            accountName: 'حساب الكاش',
            accountNumber: 'CASH',
            currency: 'SAR',
            openingMinor: opening,
          ),
        );
      }
      final created = await use(
        a,
        (db, g) => db.createCommerceProduct(
          g,
          commandId: _id(),
          name: 'مفكات فحص الفروع',
          unit: 'قطعة',
          price: 35,
          costPrice: 15.25,
          costCurrency: 'SAR',
          stock: 12,
          expiryDate: '2027-01-01',
        ),
      );
      final product = created['id'] as String;
      final delivered = owner.delivered;
      owner.online = false;
      await expectLater(api.transferOptions(connected), throwsException);
      expect((await api.transferOptions(to))['accounts'], hasLength(1));
      expect(
        (await api.productMatch(
          fromProductId: product,
          toBranchId: to,
        ))['exists'],
        isFalse,
      );
      final cash = _id(), stock = _id();
      for (var retry = 0; retry < 2; retry++) {
        await api.financialTransfer(
          fromBranchId: from,
          toBranchId: to,
          fromAccountId: source,
          toAccountId: target,
          amount: 125.75,
          commandId: cash,
        );
        await api.inventoryTransfer(
          fromBranchId: from,
          toBranchId: to,
          items: [
            {'from_product_id': product, 'quantity': '3.125'},
          ],
          commandId: stock,
        );
      }
      await store.close();
      store = open();
      expect((await api.transfer(cash))['amount'], '125.75');
      active = b;
      expect((await api.transfer(cash))['received_amount'], '125.75');
      expect(
        (await api.transfers()).map((r) => r['id']),
        unorderedEquals([stock, cash]),
      );
      final received = (await use(
        b,
        (db, g) => db.commerceInventoryProduct(g, product),
      ))!;
      final lot = (received['lots'] as List).single as Map;
      expect(double.parse('${lot['remaining']}'), 3.125);
      expect(double.parse('${lot['unit_cost']}'), 15.25);
      expect(double.parse('${received['avg_cost']}'), 15.25);
      expect(lot['currency'], 'SAR');
      expect(lot['expiry_date'], '2027-01-01');
      expect(
        (await use(a, (db, g) => db.accounts(g))).single['balance_minor'],
        57425,
      );
      expect(
        (await use(b, (db, g) => db.accounts(g))).single['balance_minor'],
        27575,
      );
      await api.reverseTransfer(stock, commandId: _id());
      expect((await api.transfer(stock))['status'], 'reversed');
      sid = _id();
      await expectLater(
        api.transfer(cash),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(owner.delivered, delivered);
      print(
        'PASS branches: two registered branches, SAR 125.75 and 3.125 units '
        'transferred offline and read after reopen; used one writer and no legacy requests.',
      );
    },
    skip: fixture == null || (_managed && !_managedLink),
  );
}
