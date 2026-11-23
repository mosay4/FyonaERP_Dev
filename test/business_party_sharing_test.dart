import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_party_sharing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String id() => const Uuid().v4();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test(
    'lost acknowledgement, consent, money change, reopen and revoke use only share transport',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fyona-share-fixture-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = FixtureDirectoryKeys();
      DirectoryPilotStore open() =>
          DirectoryPilotStore(root: () async => root, keys: keys);
      var store = open();
      addTearDown(() => store.close());
      const customer = DirectoryPartyKind.customer;
      final base = DirectoryPilotBuild.baseUrl;
      final real = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: base,
          accountId: id(),
          organizationId: id(),
        ),
        branchId: id(),
        readable: {customer},
        writable: {customer},
        financialCutover: true,
      );
      await store.remember(real, {
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
      DirectoryAccess? selected = real;
      var online = true, allowed = true, lostAck = true, notifications = 0;
      final calls = <RequestOptions>[];
      final published = <Map<String, dynamic>>[];
      final linkId = id();
      final publisherSession = id();
      const generation = '2026-11-21T00:00:00+00:00';
      String status = 'none';
      String? opaque;
      var revision = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              calls.add(options);
              expect(options.uri.host, Uri.parse(base).host);
              if (options.uri.path.startsWith('/api/v1/peer-relay/')) {
                // The debt copy now travels through the peer relay.
                expect(options.headers['Authorization'], 'Bearer fixture-access');
                if (options.uri.pathSegments.last == 'push') {
                  final body = Map<String, dynamic>.from(options.data as Map);
                  expect(status, 'accepted');
                  expect(body['link_id'], linkId);
                  expect(body['kind'], 'debt_snapshot');
                  published.add(Map<String, dynamic>.from(body['payload'] as Map));
                }
                handler.resolve(Response(requestOptions: options, data: {'data': {}}));
                return;
              }
              expect(
                options.uri.path,
                startsWith('/api/v1/business/party-sharing/'),
              );
              expect(options.headers['X-Branch-Token'], 'fixture-token');
              expect(options.headers['Authorization'], 'Bearer fixture-access');
              final suffix = options.uri.pathSegments.last;
              if (suffix == 'lookup') {
                expect(options.data, {'kind': 'customer', 'code': '123456'});
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'data': {'found': true},
                    },
                  ),
                );
                return;
              }
              final key =
                  options.uri.pathSegments[options.uri.pathSegments.length -
                      (suffix == 'invite' || suffix == 'snapshot' ? 2 : 1)];
              opaque ??= key;
              expect(key, opaque);
              if (suffix == 'invite' && status == 'none') {
                status = 'pending';
                revision++;
                notifications++;
              }
              if (suffix == 'invite' && lostAck) {
                lostAck = false;
                handler.reject(
                  DioException.connectionError(
                    requestOptions: options,
                    reason: 'Synthetic response loss',
                  ),
                );
                return;
              }
              if (suffix == 'snapshot') {
                expect(status, 'accepted');
                final body = Map<String, dynamic>.from(options.data as Map);
                expect(body['link_id'], linkId);
                expect(body['generation'], generation);
                expect(body['revision'], revision);
                published.add(body);
                revision++;
              }
              if (options.method == 'DELETE') status = 'revoked';
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'data': {
                      'id': linkId,
                      'status': status,
                      'generation': generation,
                      'revision': revision,
                    },
                  },
                ),
              );
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      BusinessPartySharing session() => BusinessPartySharing(
        dio,
        store,
        real,
        () => selected,
        () => 'fixture-token',
        (_) => allowed,
        () => online,
        () {},
        () async =>
            (accessToken: 'fixture-access', sessionId: publisherSession),
      );
      var sharing = session();
      addTearDown(() => sharing.dispose());
      final grant = BusinessLedgerAccess(
        real,
        BusinessLedgerAction.values.toSet(),
      );
      final buyer = (await store.add(
        real,
        customer,
        name: 'Synthetic Buyer',
      )).id;
      final party = DirectoryPartyReference(
        scope: real,
        kind: customer,
        id: buyer,
      );
      final op = await store.withLedger(
        grant,
        () => real,
        (ledger) => ledger.issueCommerceDocument(
          grant,
          kind: BusinessInvoiceKind.sale,
          commandId: id(),
          currency: 'SAR',
          partyId: buyer,
          lines: const [
            CommerceIssueLine(
              description: 'Service',
              quantity: '1',
              unitMinor: 1000,
            ),
          ],
          payments: const [],
        ),
      );
      expect(
        (await sharing.lookup(party, {'code': '123456'}))['found'],
        isTrue,
      );
      await expectLater(
        sharing.invite(party, {'code': '123456'}),
        throwsA(isA<DioException>()),
      );
      expect(opaque, isNot(buyer));
      expect(published, isEmpty);
      sharing.dispose();
      await store.close();
      store = open();
      sharing = session();
      await sharing.refresh();
      expect((await sharing.cachedStatus(party))['status'], 'pending');
      expect(published, isEmpty);
      expect(notifications, 1);
      await sharing.invite(party, {'code': '123456'});
      expect(notifications, 1);
      status = 'accepted';
      await sharing.refresh();
      expect(published, hasLength(1));
      expect(published.single['debts'], [
        {'currency': 'SAR', 'remaining_minor': 1000, 'paid_minor': 0},
      ]);
      expect(jsonEncode(published.single), isNot(contains(op['id'] as String)));
      expect(jsonEncode(published.single), isNot(contains(buyer)));
      expect(jsonEncode(published.single), isNot(contains('Synthetic Buyer')));
      await sharing.refresh();
      expect(published, hasLength(1));
      online = false;
      await store.withLedger(
        grant,
        () => real,
        (ledger) => ledger.issueCommerceDocument(
          grant,
          kind: BusinessInvoiceKind.sale,
          commandId: id(),
          currency: 'SAR',
          partyId: buyer,
          lines: const [
            CommerceIssueLine(
              description: 'Other service',
              quantity: '1',
              unitMinor: 600,
            ),
          ],
          payments: const [],
        ),
      );
      final offlineCalls = calls.length;
      await sharing.refresh();
      expect(calls, hasLength(offlineCalls));
      online = true;
      await sharing.refresh();
      expect(published.last['debts'], [
        {'currency': 'SAR', 'remaining_minor': 1600, 'paid_minor': 0},
      ]);
      final sent = calls.length;
      allowed = false;
      await sharing.refresh();
      expect(calls, hasLength(sent));
      allowed = true;
      selected = null;
      await sharing.refresh();
      expect(calls, hasLength(sent));
      selected = real;
      await store.withLedger(
        grant,
        () => real,
        (ledger) => ledger.deleteUnlinkedParty(grant, party, commandId: id()),
      );
      await sharing.refresh();
      expect(status, 'revoked');
      expect(calls.last.method, 'DELETE');
      await sharing.refresh();
      expect(calls, hasLength(sent + 1));
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );
}
