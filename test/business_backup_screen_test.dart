import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/storage/free_space.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
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
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
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

class _Files extends BusinessBackupFiles {
  List<int>? exported;
  String? exportName;
  final verification = <String>[];
  int shared = 0;
  int picked = 0;
  Completer<Stream<List<int>>?>? pendingPicker;

  @override
  Future<void> save(LocalBusinessBackupFile backup) async {
    exportName = backup.name;
    exported = await backup.file.readAsBytes();
  }

  @override
  Future<void> share(LocalBusinessBackupFile backup) async {
    expect(await backup.file.readAsBytes(), exported);
    shared++;
  }

  @override
  Future<Stream<List<int>>?> pick() async {
    picked++;
    if (pendingPicker case final pending?) return pending.future;
    return Stream.value(exported!);
  }
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
    'original backup controls create and import only an encrypted local file',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          accountId: _id(),
          organizationId: _id(),
        ),
        branchId: _id(),
        readable: {},
        writable: {},
        financialCutover: true,
      );
      final grant = BusinessLedgerAccess(scope, {
        BusinessLedgerAction.createBank,
        BusinessLedgerAction.readBank,
      });
      final files = _Files();
      final account = _id();
      late Directory root;
      late DirectoryPilotStore first;
      late DirectoryPilotStore second;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('business-backup-ui-');
        first = DirectoryPilotStore(
          root: () => root.createTemp('original-'),
          keys: FixtureDirectoryKeys(),
        );
        final recoveryRoot = await root.createTemp('recovery-');
        second = DirectoryPilotStore(
          root: () async => recoveryRoot,
          keys: FixtureDirectoryKeys(),
        );
        await BranchScope.save(
          token: 'fixture',
          branchId: scope.branchId,
          branchName: 'فرع المعمل',
          allMode: false,
          organizationId: scope.workspace.organizationId,
        );
        final status = {
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
        };
        for (final store in [first, second]) {
          await store.remember(scope, status);
        }
        await first.withLedger(
          grant,
          () => scope,
          (ledger) => ledger.createAccount(
            grant,
            commandId: account,
            bankName: 'Synthetic bank',
            accountName: 'Synthetic account',
            accountNumber: '1',
            currency: 'SAR',
            openingMinor: 5700,
          ),
        );
      });
      addTearDown(() async {
        await first.close();
        await second.close();
        await root.delete(recursive: true);
        await BranchScope.clear();
      });
      var http = 0;
      var verificationAccepted = true;
      Completer<bool>? pendingVerification;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, h) {
              http++;
              h.reject(
                DioException.connectionError(
                  requestOptions: r,
                  reason: 'No test network',
                ),
              );
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      ProviderContainer container(
        DirectoryPilotStore store,
        String backupArea,
      ) => ProviderContainer(
        overrides: [
          authProvider.overrideWith((_) => _Session()),
          serverBaseUrlProvider.overrideWith(
            (_) => DirectoryPilotBuild.baseUrl,
          ),
          businessLocalLedgerScopeProvider.overrideWithValue(scope),
          directoryPilotStoreProvider.overrideWithValue(store),
          businessBackupRootProvider.overrideWithValue(
            () async => Directory('${root.path}/$backupArea'),
          ),
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          businessBackupFilesProvider.overrideWithValue(files),
          businessBackupVerifierProvider.overrideWithValue((
            _,
            __,
            reason,
            local,
          ) async {
            expect(local, isTrue);
            files.verification.add(reason);
            if (pendingVerification case final pending?) return pending.future;
            return verificationAccepted;
          }),
        ],
      );
      final original = container(first, 'archives-original');
      final fresh = container(second, 'archives-fresh');
      addTearDown(original.dispose);
      addTearDown(fresh.dispose);
      final page = MaterialApp(home: const BusinessBackupPage());
      Future<void> mount(ProviderContainer value) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            key: ObjectKey(value),
            container: value,
            child: page,
          ),
        );
        await tester.pump();
      }

      Future<void> see(Finder finder) async {
        for (
          var attempt = 0;
          attempt < 110 && finder.evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 15));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 7)),
          );
          // Only the restore's own percentage bar (large files) may show.
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is LinearProgressIndicator &&
                  w.key != const ValueKey('business-backup-progress'),
            ),
            findsNothing,
          );
        }
        expect(finder, findsOneWidget);
      }

      Future<void> trueCondition(bool Function() check) async {
        for (var i = 0; i < 90 && !check(); i++) {
          await tester.pump(const Duration(milliseconds: 15));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 7)),
          );
        }
        expect(check(), isTrue);
      }

      await mount(original);
      await tester.tap(find.text('إنشاء نسخة احتياطية'));
      final shownCode = find.byKey(const ValueKey('business-backup-code'));
      await see(shownCode);
      final code = tester.widget<SelectableText>(shownCode).data!;
      expect(files.exported, isNull);
      expect(find.text('تم إنشاء النسخة المشفّرة'), findsNothing);
      await tester.tap(find.text('حفظت الرمز، أنشئ النسخة'));
      await see(find.text('تم إنشاء النسخة المشفّرة'));
      await see(find.text('حفظ'));
      await tester.tap(find.text('حفظ'));
      await trueCondition(() => files.exported != null);
      expect(files.exportName, endsWith('.fyonabiz'));
      expect(
        String.fromCharCodes(files.exported!.take(16)),
        isNot(startsWith('SQLite format 3')),
      );
      expect(String.fromCharCodes(files.exported!), isNot(contains(code)));
      await tester.tap(find.text('مشاركة'));
      await trueCondition(() => files.shared == 1);

      await mount(fresh);
      final restore = find.text('استعادة من ملف مشفّر');
      Future<void> enter(String value) async {
        await tester.tap(restore);
        final field = find.byKey(const ValueKey('business-restore-code'));
        await see(field);
        await tester.enterText(field, value);
        await tester.tap(find.text('متابعة'));
      }

      verificationAccepted = false;
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(files.picked, 0);
      expect(find.text('استعادة الدفتر'), findsNothing);
      verificationAccepted = true;
      // Returning to the same selection after a context/permission epoch
      // changed does not resume an old confirmation or a native picker.
      pendingVerification = Completer<bool>();
      await tester.tap(restore);
      await tester.pump();
      fresh.read(branchEpochProvider.notifier).state++;
      await tester.pump();
      pendingVerification!.complete(true);
      pendingVerification = null;
      await tester.pumpAndSettle();
      expect(find.text('استعادة الدفتر'), findsNothing);
      files.pendingPicker = Completer<Stream<List<int>>?>();
      await enter(code);
      await trueCondition(() => files.picked == 1);
      fresh.read(branchEpochProvider.notifier).state++;
      await tester.pump();
      files.pendingPicker!.complete(Stream.value(files.exported!));
      files.pendingPicker = null;
      await tester.pumpAndSettle();
      expect(find.text('تمت استعادة السجلات المحلية'), findsNothing);
      await tester.runAsync(() async {
        expect(
          await second.withLedger(
            grant,
            () => scope,
            (ledger) => ledger.accounts(grant),
          ),
          isEmpty,
        );
      });
      await enter(code);
      await see(find.text('تمت استعادة السجلات المحلية'));
      expect(files.picked, 2);
      await tester.runAsync(() async {
        await second.close();
        final accounts = await second.withLedger(
          grant,
          () => scope,
          (ledger) => ledger.accounts(grant),
        );
        expect(accounts.single['id'], account);
        expect(accounts.single['balance_minor'], 5700);
      });
      expect(fresh.read(branchEpochProvider), 3);
      await mount(original);
      await see(find.text('حذف'));
      await tester.tap(find.text('حذف'));
      await trueCondition(() => find.text('حذف').evaluate().isEmpty);
      expect(files.verification, contains('تأكيد حذف النسخة'));
      expect(http, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !DirectoryPilotBuild.signupEnabled,
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
