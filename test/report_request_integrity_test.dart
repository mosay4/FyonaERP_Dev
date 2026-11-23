import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/reports/data/report_request_guard.dart';
import 'package:fyona_flutter/features/reports/data/reports_api.dart';

void main() {
  tearDown(() {
    BranchScope.branchId = null;
    BranchScope.organizationId = null;
    BranchScope.allMode = false;
    BranchScope.token = null;
    BranchScope.selectionOwner = null;
  });

  test('fast report changes accept only the newest response', () {
    final guard = ReportRequestGuard();
    BranchScope.branchId = 'A';
    final first = guard.begin();
    final second = guard.begin();
    expect(guard.accepts(first), isFalse);
    expect(guard.accepts(second), isTrue);
    BranchScope.allMode = true;
    expect(guard.accepts(second), isFalse);
    final all = guard.begin();
    expect(guard.accepts(all), isTrue);
    BranchScope.allMode = false;
    BranchScope.branchId = 'B';
    expect(guard.accepts(all), isFalse);
  });

  test(
    'request snapshots branch token and rejects response after branch switch',
    () async {
      final dio = Dio();
      final pending = Completer<void>();
      final requestReady = Completer<void>();
      RequestOptions? request;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            request = options;
            requestReady.complete();
            await pending.future;
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'data': {
                    'currency': 'SAR',
                    'totals_complete': true,
                    'total': 100,
                  },
                },
              ),
            );
          },
        ),
      );
      BranchScope.branchId = 'A';
      BranchScope.token = 'TOKEN_A';
      final future = BusinessReportsApi(ApiClient(dio: dio)).home(null, null);
      final check = expectLater(future, throwsA(isA<ReportScopeChanged>()));
      await requestReady.future;
      expect(request!.headers['X-Branch-Token'], 'TOKEN_A');
      expect(request!.queryParameters['branch_id'], 'A');
      BranchScope.branchId = 'B';
      BranchScope.token = 'TOKEN_B';
      pending.complete();
      await check;
      dio.close();
    },
  );

  test(
    'all-branches never accepts a subset or falls back without a token',
    () async {
      final dio = Dio();
      var calls = 0;
      var branches = ['legacy'];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            expect(options.method, 'GET');
            expect(options.queryParameters, isNot(contains('branch_id')));
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'data': {
                    'totals_complete': true,
                    'branch_ids': branches,
                    'total': 300,
                  },
                },
              ),
            );
          },
        ),
      );
      BranchScope.allMode = true;
      BranchScope.selectionOwner = 'account-A';
      final api = BusinessReportsApi(ApiClient(dio: dio));
      await expectLater(
        api.overview(null, null),
        throwsA(isA<ReportNotAvailableLocally>()),
      );
      expect(calls, 0);
      final claims = base64Url.encode(
        utf8.encode(
          jsonEncode({
            'branch_ids': ['legacy', 'second'],
          }),
        ),
      );
      BranchScope.token = 'fixture.$claims.signature';
      await expectLater(
        api.overview(null, null),
        throwsA(isA<ReportNotAvailableLocally>()),
      );
      branches = ['second', 'legacy'];
      expect((await api.overview(null, null))['total'], 300);
      expect(calls, 2);
      dio.close();
    },
  );

  test(
    'partial totals cannot enter the UI, and error envelopes retain original amounts',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'data': {'totals_complete': false, 'total': 100},
                },
              ),
            );
          },
        ),
      );
      await expectLater(
        BusinessReportsApi(ApiClient(dio: dio)).home(null, null),
        throwsStateError,
      );
      final request = RequestOptions(path: '/business-reports/home');
      final error = DioException(
        requestOptions: request,
        response: Response(
          requestOptions: request,
          statusCode: 409,
          data: {
            'message': {
              'code': 'report_fx_missing',
              'message': 'documented rate needed',
              'missing': [
                {
                  'currency': 'YER_OLD',
                  'original_amount': '534',
                  'at': '2024-01-01',
                },
              ],
            },
          },
        ),
      );
      expect(BusinessReportsApi.serverMessage(error), 'documented rate needed');
      expect(
        BusinessReportsApi.missingRates(error).single['original_amount'],
        '534',
      );
      dio.close();
    },
  );
}
