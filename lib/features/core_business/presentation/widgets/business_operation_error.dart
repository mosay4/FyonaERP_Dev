import 'package:dio/dio.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_scope.dart';

String businessOperationError(
  AppLocalizations l10n,
  Object error, {
  required String fallback,
}) {
  if (error is ApiException) return error.message;
  if (error is DioException) {
    if (error.error is DirectoryAccessDenied)
      return l10n.translate('unauthorized');
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return l10n.translate('networkError');
    }
    final data = error.response?.data;
    final detail = data is Map ? data['detail'] ?? data['message'] : null;
    final message = detail is Map ? detail['message'] : detail;
    if (message is String && message.trim().isNotEmpty) return message;
  }
  if (error is DirectoryAccessDenied) return l10n.translate('unauthorized');
  if (error is SharedCatalogReadOnly) return l10n.translate('invSharedCategoryReadOnly');
  if (error is BusinessCashEqualizationPending) return l10n.translate('reconDeviceCashFinishPending');
  if (error is DirectoryPartyNotFound) return l10n.translate(fallback);
  if (error is BusinessLedgerError) {
    return l10n.translate(switch (error.problem) {
      BusinessLedgerProblem.insufficientBalance => 'insufficientBalance',
      BusinessLedgerProblem.insufficientStock => 'saleOutOfStock',
      BusinessLedgerProblem.invalidAccount => 'accountNotFound',
      BusinessLedgerProblem.missingRate => 'saleErrNeedRate',
      _ => fallback,
    });
  }
  return l10n.translate(fallback);
}
