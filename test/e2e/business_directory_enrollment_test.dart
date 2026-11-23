import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';

import '../support/directory_test_keys.dart';

void main() {
  final fixturePath = Platform.environment['FYONA_ENROLLMENT_PROBE'];
  test(
    'a newly registered live QA account writes both directories only on disk',
    () async {
      final base = DirectoryPilotBuild.stagingBase;
      expect(DirectoryPilotBuild.baseUrl, base);
      expect(DirectoryPilotBuild.signupEnabled, isTrue);
      final fixture =
          jsonDecode(await File(fixturePath!).readAsString()) as Map;
      expect(
        '${fixture['email']}',
        matches(r'^signup-[a-f0-9]{24}@example\.test$'),
      );
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..findProxy = (_) => 'DIRECT';
      addTearDown(() => client.close(force: true));
      final root = await Directory.systemTemp.createTemp(
        'directory-enrollment-',
      );
      addTearDown(() => root.delete(recursive: true));

      Future<Map> call(
        String path, {
        Map<String, Object?>? body,
        String? token,
        String? scope,
      }) async {
        final req = await client.openUrl(
          body == null ? 'GET' : 'POST',
          Uri.parse('$base$path'),
        );
        req.followRedirects = false;
        req.headers.contentType = ContentType.json;
        req.headers.set('X-Device-Id', 'fyona-directory-enrollment-flutter');
        if (token != null) req.headers.set('Authorization', 'Bearer $token');
        if (scope != null) req.headers.set('X-Branch-Token', scope);
        if (body != null) req.write(jsonEncode(body));
        final response = await req.close().timeout(const Duration(seconds: 12));
        final content = await utf8.decoder.bind(response).join();
        expect(response.statusCode, 200, reason: path);
        final decoded = jsonDecode(content) as Map;
        return (decoded['data'] ?? decoded) as Map;
      }

      final login = await call(
        '/auth/login',
        body: {'email': fixture['email'], 'password': fixture['password']},
      );
      final token = login['access_token'] as String;
      final user = login['user'] as Map;
      final account = user['id'] as String;
      final org = user['organization_id'] as String;
      expect(account, fixture['account']);
      expect(org, fixture['organization']);

      Future<String> select(String id) async {
        final branch = await call(
          '/branches/select',
          token: token,
          body: {'organization_id': org, 'branch_id': id},
        );
        return branch['token'] as String;
      }

      DirectoryAccess? access(String id, String signed) =>
          resolveDirectoryPilot(
            server: base,
            accountId: account,
            organizationId: org,
            selectedOrganizationId: org,
            selectedBranchId: id,
            selectedToken: signed,
            readOnly: false,
          );

      final first = fixture['first_branch'] as String;
      final second = fixture['other_branch'] as String;
      final grant = await select(first);
      final scope = access(first, grant)!;
      expect(access(second, await select(second)), isNull);
      final snapshot = await call(
        '/subscription/status',
        token: token,
        scope: grant,
      );
      final keys = FixtureDirectoryKeys(root);
      final store = DirectoryPilotStore(root: () async => root, keys: keys);
      addTearDown(store.close);
      await store.remember(scope, Map<String, dynamic>.from(snapshot));
      for (final kind in DirectoryPartyKind.values) {
        expect(await store.search(scope, kind, ''), isEmpty);
        await store.add(scope, kind, name: 'Online smoke ${kind.name}');
      }
      client.close(force: true);
      for (final kind in DirectoryPartyKind.values) {
        await store.add(scope, kind, name: 'Offline smoke ${kind.name}');
      }
      await store.close();
      final reopened = DirectoryPilotStore(
        root: () async => root,
        keys: FixtureDirectoryKeys(root),
      );
      addTearDown(reopened.close);
      for (final kind in DirectoryPartyKind.values) {
        expect(
          (await reopened.search(scope, kind, 'smoke')).map((p) => p.name),
          ['Offline smoke ${kind.name}', 'Online smoke ${kind.name}'],
        );
      }
    },
    skip: fixturePath == null
        ? 'Needs the isolated signup probe fixture'
        : false,
  );
}
