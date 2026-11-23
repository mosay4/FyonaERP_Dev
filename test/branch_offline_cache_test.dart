import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'branches live on the device and the server only carries them to the rest',
    () async {
      SharedPreferences.setMockInitialValues({});
      final docs = await Directory.systemTemp.createTemp('branch-docs-');
      addTearDown(() => docs.delete(recursive: true));
      PathProviderPlatform.instance = _FakePathProvider(docs.path);

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1/api/v1'));
      var online = true;
      final pushed = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (!online) {
              return handler.reject(
                DioException.connectionError(
                  requestOptions: request,
                  reason: 'no network',
                ),
              );
            }
            pushed.add('${request.method} ${request.path}');
            handler.resolve(
              Response(
                requestOptions: request,
                data: {
                  'data': {
                    if (request.path == '/business/media-transit')
                      'items': <Map<String, dynamic>>[],
                    if (request.path != '/business/media-transit') ...{
                      'branches': [
                        {
                          'id': '11111111-1111-4111-8111-111111111111',
                          'name': 'فرع حده',
                        },
                        {
                          'id': '22222222-2222-4222-8222-222222222222',
                          'name': 'الاصبحي',
                        },
                      ],
                    },
                  },
                },
              ),
            );
          },
        ),
      );
      final api = BranchApi(ApiClient(dio: dio));

      final onlineRows = await api.list();
      expect(onlineRows.map((e) => e['name']), ['فرع حده', 'الاصبحي']);
      pushed.clear();

      // A cold start without internet serves the very same branches.
      online = false;
      final offlineRows = await api.list();
      expect(offlineRows.map((e) => e['name']), ['فرع حده', 'الاصبحي']);

      // Editing a branch and uploading its image need no connection: both are
      // kept on the device and shown at once, and never written to the server.
      await api.rename(
        '11111111-1111-4111-8111-111111111111',
        'فرع حده المحدث',
      );
      await api.uploadImage(
        '11111111-1111-4111-8111-111111111111',
        Uint8List.fromList(const [1, 2, 3, 4]),
      );
      final edited = await api.list();
      final changed = edited.firstWhere(
        (e) => e['id'] == '11111111-1111-4111-8111-111111111111',
      );
      expect(changed['name'], 'فرع حده المحدث');
      expect('${changed['image']}', startsWith('local://'));
      expect(
        File('${changed['image']}'.substring('local://'.length)).existsSync(),
        isTrue,
      );
      expect(pushed, isEmpty);

      // Creating a branch and managing it needs no connection either: the
      // branch is born on the device and the server is not written to.
      await api.create('فرع جديد بدون إنترنت');
      await api.archive('22222222-2222-4222-8222-222222222222');
      final managed = await api.list();
      final born = managed.firstWhere(
        (e) => e['name'] == 'فرع جديد بدون إنترنت',
      );
      expect(born['is_default'], isFalse);
      expect(
        managed.firstWhere(
          (e) => e['id'] == '22222222-2222-4222-8222-222222222222',
        )['is_archived'],
        isTrue,
      );
      expect(pushed, isEmpty);

      // Back online the work travels to the other devices as one transit
      // payload; the server is only the road and keeps nothing.
      online = true;
      pushed.clear();
      await api.list();
      expect(
        pushed.where((e) => e.startsWith('POST /business/media-transit')),
        hasLength(3),
      );
      expect(
        pushed.where((e) => e.contains('PATCH') || e.contains('/image')),
        isEmpty,
      );

      // The branch the user last worked in is kept across restarts and is
      // never silently moved to the main branch.
      await BranchScope.save(
        token: 'saved-token',
        branchId: '11111111-1111-4111-8111-111111111111',
        branchName: 'فرع حده',
        allMode: false,
        organizationId: '33333333-3333-4333-8333-333333333333',
      );
      await BranchScope.load();
      expect(BranchScope.branchId, '11111111-1111-4111-8111-111111111111');
      expect(BranchScope.branchName, 'فرع حده');
      expect(BranchScope.allMode, isFalse);
      expect(BranchScope.token, 'saved-token');
    },
  );
}
