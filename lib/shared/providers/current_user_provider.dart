import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/di/auth_providers.dart';
import '../models/user_model.dart';

final currentUserProvider = Provider<UserModel?>((ref) {
  return ref.watch(authProvider).user;
});

final currentOrgIdProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider)?.organizationId;
});

final currentUserIdProvider = Provider<String>((ref) {
  return ref.watch(currentUserProvider)?.id ?? '';
});

final currentUserRoleProvider = Provider<String>((ref) {
  return ref.watch(currentUserProvider)?.role ?? '';
});

final currentBusinessTypeProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider)?.preferredUsageMode;
});