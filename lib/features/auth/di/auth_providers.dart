import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../../core/services/audit_service.dart';
import '../data/datasources/auth_remote_data_source_impl.dart';
import '../data/datasources/auth_local_data_source.dart';
import '../data/repositories/auth_repository_impl.dart';
import '../domain/repositories/auth_repository.dart';
import '../domain/services/auth_service.dart';
import '../domain/services/firebase_auth_service.dart';
import '../presentation/providers/auth_provider.dart';

final firebaseAuthServiceProvider = Provider<FirebaseAuthService>((ref) {
  return FirebaseAuthService();
});

final authLocalDataSourceProvider = Provider<AuthLocalDataSource>((ref) {
  return AuthLocalDataSource(storage: ref.watch(secureStorageProvider));
});

final authRemoteDataSourceProvider = Provider<AuthRemoteDataSourceImpl>((ref) {
  ref.watch(dioProvider);
  return AuthRemoteDataSourceImpl(apiClient: ref.read(apiClientProvider));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositoryImpl(
    remoteDataSource: ref.watch(authRemoteDataSourceProvider),
    localDataSource: ref.watch(authLocalDataSourceProvider),
  );
});

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(
    repository: ref.watch(authRepositoryProvider),
    auditService: ref.watch(auditServiceProvider),
  );
});

final authStateProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    ref.watch(authServiceProvider),
    ref.watch(authLocalDataSourceProvider),
    ref.watch(firebaseAuthServiceProvider),
    ref,
  );
});

final authProvider = authStateProvider;
