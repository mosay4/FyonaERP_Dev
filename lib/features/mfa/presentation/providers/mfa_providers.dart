import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/mfa_models.dart';
import '../../di/mfa_providers.dart';

final mfaStatusProvider = FutureProvider<MfaStatusModel>((ref) async {
  final service = ref.watch(mfaServiceProvider);
  return service.getStatus();
});

final mfaEnableProvider = FutureProvider<MfaStatusModel>((ref) async {
  final service = ref.watch(mfaServiceProvider);
  return service.enableMfa();
});

final mfaDisableProvider = FutureProvider<void>((ref) async {
  final service = ref.watch(mfaServiceProvider);
  await service.disableMfa();
});

final mfaVerifyProvider = FutureProvider.family<bool, String>((ref, code) async {
  final service = ref.watch(mfaServiceProvider);
  return service.verifyCode(code);
});

final mfaBackupCodesProvider = FutureProvider<List<String>>((ref) async {
  final service = ref.watch(mfaServiceProvider);
  return service.getBackupCodes();
});
