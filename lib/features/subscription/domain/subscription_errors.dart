import '../../../core/localization/app_localizations.dart';
import '../../../core/network/api_exceptions.dart';

/// The localized notice for the known backend guard, or null when the error
/// is something else.
String? premiumSubscriptionMessage(Object e) {
  final raw = e is ApiException ? e.message : '$e';
  if (raw.contains('Premium already includes') ||
      raw.contains('premium_includes')) {
    return AppLocalizations.t('premiumIncludesSections');
  }
  return null;
}

/// Map known backend subscription errors into the app's language so the user
/// never reads an English-only server sentence.
String localizeSubscriptionError(Object e) =>
    premiumSubscriptionMessage(e) ??
    (e is ApiException ? e.message : '$e');
