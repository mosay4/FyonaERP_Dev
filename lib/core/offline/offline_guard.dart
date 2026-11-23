import 'package:dio/dio.dart';
import '../network/api_exceptions.dart';

/// True when [error] means the server could not be reached (network/offline or
/// server unavailable/timeout), as opposed to a validation or server error.
bool isConnectivityError(Object error) {
  if (error is OfflineException ||
      error is ServerUnavailableException ||
      error is NetworkException ||
      error is TimeoutException) {
    return true;
  }
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.unknown:
        return error.message?.contains('SocketException') ?? false;
      default:
        return false;
    }
  }
  return false;
}