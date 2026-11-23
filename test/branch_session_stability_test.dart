import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/di/providers.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/audit_service.dart';
import 'package:fyona_flutter/features/auth/di/auth_providers.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';

void main() {
  test('branch refresh rebuilds business client but retains session dependencies', () {
    final dio = Dio();
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWithValue(dio),
    ]);
    addTearDown(container.dispose);
    addTearDown(() => dio.close());
    final business = container.read(apiClientProvider);
    final auth = container.read(authRemoteDataSourceProvider);
    final audit = container.read(auditServiceProvider);
    container.read(branchEpochProvider.notifier).state++;
    expect(container.read(apiClientProvider), isNot(same(business)));
    expect(container.read(authRemoteDataSourceProvider), same(auth));
    expect(container.read(auditServiceProvider), same(audit));
  });
}
