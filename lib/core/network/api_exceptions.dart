import 'package:fyona_flutter/core/config/app_config.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final List<String>? errors;

  const ApiException({
    required this.message,
    this.statusCode,
    this.errors,
  });

  @override
  String toString() => 'ApiException: $message (status: $statusCode)';
}

class NetworkException extends ApiException {
  NetworkException({String? message})
      : super(message: message ?? AppLocalizations.t('coreNetworkError'), statusCode: null);
}

class UnauthorizedException extends ApiException {
  UnauthorizedException({String? message})
      : super(message: message ?? AppLocalizations.t('unauthorized'), statusCode: 401);
}

class NotFoundException extends ApiException {
  NotFoundException({String? message})
      : super(message: message ?? AppLocalizations.t('coreNotFound'), statusCode: 404);
}

class ValidationException extends ApiException {
  ValidationException({String? message, super.errors})
      : super(message: message ?? AppLocalizations.t('coreInvalidData'), statusCode: 422);
}

class ServerException extends ApiException {
  ServerException({String? message})
      : super(message: message ?? AppLocalizations.t('coreServerError'), statusCode: 500);
}

class TimeoutException extends ApiException {
  TimeoutException({String? message})
      : super(message: message ?? _withServer(), statusCode: null);

  /// Name the server that did not answer — "انتهت مهلة الطلب" alone leaves the
  /// user with no way to tell a wrong address from a slow one.
  static String _withServer() {
    final text = AppLocalizations.t('coreRequestTimeout');
    final uri = Uri.tryParse(AppConfig.effectiveApiBaseUrl);
    final host = uri?.host;
    if (host == null || host.isEmpty) return text;
    final port = uri?.port;
    final suffix = (port == null || port == 80 || port == 443) ? '' : ':$port';
    return '$text ($host$suffix)';
  }
}

class OfflineException extends ApiException {
  OfflineException({String? message})
      : super(message: message ?? AppLocalizations.t('noInternet'), statusCode: null);
}

/// Thrown when the API server itself is unreachable (loopback/LAN host), as
/// opposed to the device having no internet at all.
class ServerUnavailableException extends ApiException {
  ServerUnavailableException({String? message})
      : super(
          message: message ?? AppLocalizations.t('coreServerUnavailable'),
          statusCode: null,
        );
}
