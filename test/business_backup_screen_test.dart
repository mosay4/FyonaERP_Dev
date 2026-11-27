import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/storage/free_space.dart';
import 'package:fyona_flutter/core/di/providers.dart' show apiClientProvider;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart';
import 'package:fyona_flutter/features/auth/data/datasources/auth_local_data_source.dart';
import 'package:fyona_flutter/features/auth/di/auth_providers.dart'
    show authLocalDataSourceProvider;
import 'package:fyona_flutter/features/auth/domain/services/biometric_service.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/biometric_provider.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_local_backups.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_backup_provider.dart';
import 'package:fyona_flutter/features/profile/presentation/pages/business_backup_file_actions.dart';
import 'package:fyona_flutter/features/profile/presentation/pages/business_backup_page.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

class _Session extends StateNotifier<AuthState> implements AuthNotifier {
  _Session() : super(const AuthState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}


class _Biometrics extends BiometricService {
  _Biometrics(this.available);
  final bool available;

  @override
  Future<bool> isDeviceSupported() async => available;
  @override
  Future<bool> canCheckBiometrics() async => available;
  @override
  Future<List<BiometricType>> getAvailableBiometrics() async =>
      available ? [BiometricType.fingerprint] : [];
  @override
  Future<AuthResult> authenticate({String? reason}) async => AuthResult.success;
}

class _LocalCredentials extends AuthLocalDataSource {
  _LocalCredentials() : super(storage: SecureStorageService());
  int writes = 0;

  @override
  Future<bool> getBiometricEnabled() async => false;
  @override
  Future<void> saveBiometricEnabled(bool value) async {
    writes++;
  }

  @override
  Future<String?> getAccessToken() async {
    fail(
      'Backup verification must not read session tokens to enroll biometrics',
    );
  }

  @override
  Future<String?> getAppPin() async => null;
}

String _id() => const Uuid().v4();

void main() {
  // The device's free space is a platform call; widget tests run without it.
  setUp(() => FreeSpace.probe = (_) async => null);
  tearDown(() => FreeSpace.probe = null);
  testWidgets(
    'local backup verifies existing credentials without changing security settings',
    (tester) async {
      await tester.runAsync(() => AppLocalizations.preload('en'));
      // Mirror app startup (main.dart / LocaleNotifier): the context-free
      // lookup must follow the widget locale or it falls back to raw keys.
      AppLocalizations.setStaticLanguage('en');
      for (final available in [true, false]) {
        final local = _LocalCredentials();
        bool? authorized;
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(available),
            overrides: [
              biometricServiceProvider.overrideWithValue(
                _Biometrics(available),
              ),
              authLocalDataSourceProvider.overrideWithValue(local),
            ],
            child: MaterialApp(
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              locale: const Locale('en'),
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    return TextButton(
                      onPressed: () async {
                        authorized = await ref.read(
                          businessBackupVerifierProvider,
                        )(context, ref, 'Backup', true);
                      },
                      child: const Text('Backup fixture'),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Backup fixture'));
        await tester.pumpAndSettle();
        expect(authorized, available);
        expect(local.writes, 0);
        expect(
          ModalRoute.of(tester.element(find.text('Backup fixture')))!.isCurrent,
          isTrue,
        );
        if (!available) {
          expect(
            find.text(AppLocalizations.t('businessBackupVerifyExisting')),
            findsOneWidget,
          );
        }
      }
    },
  );

  testWidgets(
    'a device-ledger branch shows the redesigned backup: one button, two restore places, no codes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      AppLocalizations.setStaticLanguage('ar');
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(server: 'https://x.test/api/v1', accountId: _id(), organizationId: _id()),
        branchId: _id(),
        readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(),
        financialCutover: true,
      );
      late Directory root;
      late DirectoryPilotStore store;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('business-backup-home-');
        store = DirectoryPilotStore(root: () async => root, keys: FixtureDirectoryKeys());
      });
      addTearDown(() async => tester.runAsync(() async {
            await store.close();
            await root.delete(recursive: true);
          }));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          authProvider.overrideWith((_) => _Session()),
          businessLocalLedgerScopeProvider.overrideWithValue(scope),
          directoryPilotStoreProvider.overrideWithValue(store),
          localBusinessBackupsProvider.overrideWithValue(
            LocalBusinessBackups(scope, store, () async => root, () => scope),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const BusinessBackupPage(),
        ),
      ));
      for (var i = 0; i < 30 && find.byKey(const Key('bkh-now')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(find.text('النسخ الاحتياطي'), findsOneWidget); // no "والمزامنة"
      expect(find.byKey(const Key('bkh-now')), findsOneWidget);
      expect(find.byKey(const Key('bkh-device')), findsOneWidget);
      expect(find.byKey(const Key('bkh-cloud')), findsOneWidget);
      expect(find.byKey(const Key('bkh-auto')), findsOneWidget);
      // The old controls (codes to write down, files list) are gone.
      expect(find.text('رمز استعادة النسخة'), findsNothing);
      expect(find.text('استعادة من ملف مشفّر'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a connected branch keeps the original backup API', (
    tester,
  ) async {
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            requests.add('${r.method} ${r.path}');
            h.resolve(
              Response(
                requestOptions: r,
                statusCode: 200,
                data: {
                  'data': {
                    'backups': [
                      {
                        'id': 'legacy',
                        'created_at': '2019-01-02',
                        'bytes': 100,
                        'record_count': 4,
                      },
                    ],
                  },
                },
              ),
            );
          },
        ),
      );
    addTearDown(() => dio.close(force: true));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((_) => _Session()),
          localBusinessBackupsProvider.overrideWithValue(null),
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        ],
        child: const MaterialApp(home: BusinessBackupPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, ['GET /business/project-settings/backups']);
    expect(find.text('4 سجل • 100 بايت'), findsOneWidget);
    expect(find.text('استعادة'), findsOneWidget);
    expect(find.text('استعادة من ملف مشفّر'), findsNothing);
  });
}
