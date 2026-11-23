import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../data/models/mfa_models.dart';

class MfaService {
  Future<MfaStatusModel> getStatus() {
    throw UnsupportedError(AppLocalizations.t('mfaUnsupported'));
  }

  Future<MfaStatusModel> enableMfa() {
    throw UnsupportedError(AppLocalizations.t('mfaUnsupported'));
  }

  Future<void> disableMfa() {
    throw UnsupportedError(AppLocalizations.t('mfaUnsupported'));
  }

  Future<bool> verifyCode(String code) {
    throw UnsupportedError(AppLocalizations.t('mfaUnsupported'));
  }

  Future<List<String>> getBackupCodes() {
    throw UnsupportedError(AppLocalizations.t('mfaUnsupported'));
  }
}
