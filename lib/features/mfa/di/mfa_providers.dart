import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/services/mfa_service.dart';

final mfaServiceProvider = Provider<MfaService>((ref) {
  return MfaService();
});
