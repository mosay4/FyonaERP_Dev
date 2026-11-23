import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'api_exceptions.dart';

ApiException handleDioException(DioException e) {
  switch (e.type) {
    case DioExceptionType.cancel:
      return ApiException(message: AppLocalizations.t('coreRequestCancelled'));
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return TimeoutException();
    case DioExceptionType.connectionError:
      return _offlineOrServerOffline(e);
    case DioExceptionType.badResponse:
      return _handleStatusCode(e.response);
    case DioExceptionType.badCertificate:
      return ApiException(message: AppLocalizations.t('coreCertError'));
    case DioExceptionType.unknown:
      if (e.message?.contains('SocketException') ?? false) {
        return _offlineOrServerOffline(e);
      }
      return NetworkException();
    case DioExceptionType.transformTimeout:
      return TimeoutException();
  }
}

/// A connection failure to a loopback/LAN host means the local server is down
/// (or the adb reverse / LAN tunnel dropped), not necessarily no internet.
ApiException _offlineOrServerOffline(DioException e) {
  final uri = e.requestOptions.uri;
  final host = uri.host.trim();
  if (_isLocalHost(host)) return ServerUnavailableException();
  return OfflineException();
}

bool _isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '::1' || h == '0.0.0.0') return true;
  for (final p in ['127.', '10.', '192.168.']) {
    if (h.startsWith(p)) return true;
  }
  return RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h);
}

ApiException _handleStatusCode(Response? response) {
  final statusCode = response?.statusCode ?? 0;
  final body = response?.data;
  final message = _extractMessage(body);
  final errors = body is Map && body['detail'] is List
      ? (body['detail'] as List).map((e) => e is Map ? (e['msg'] ?? e.toString()).toString() : e.toString()).toList()
      : <String>[];

  switch (statusCode) {
    case 400:
      return ApiException(message: message ?? AppLocalizations.t('coreBadRequest'), statusCode: 400);
    case 401:
      return UnauthorizedException(message: message);
    case 403:
      return ApiException(message: message ?? AppLocalizations.t('coreForbidden'), statusCode: 403);
    case 404:
      return NotFoundException(message: message);
    case 409:
      return ApiException(message: message ?? AppLocalizations.t('coreConflict'), statusCode: 409);
    case 422:
      return ValidationException(message: message ?? (errors.isNotEmpty ? errors.first : null), errors: errors);
    case 429:
      return ApiException(message: message ?? AppLocalizations.t('coreTooManyRequests'), statusCode: 429);
    case 500:
      return ServerException(message: message);
    default:
      return ApiException(
        message: message ?? AppLocalizations.t('coreUnexpectedShort'),
        statusCode: statusCode,
      );
  }
}

String? _extractMessage(dynamic body) {
  if (body is! Map) return null;
  if (body['message'] != null) return body['message'].toString();
  if (body['detail'] != null) {
    if (body['detail'] is String) return body['detail'].toString();
    if (body['detail'] is List && body['detail'].isNotEmpty) {
      final first = body['detail'].first;
      if (first is Map) return first['msg']?.toString();
      return first.toString();
    }
  }
  return null;
}
