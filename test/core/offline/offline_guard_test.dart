import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_exceptions.dart';
import 'package:fyona_flutter/core/offline/offline_guard.dart';

DioException _dio(DioExceptionType type) =>
    DioException(type: type, requestOptions: RequestOptions(path: '/x'));

void main() {
  group('isConnectivityError', () {
    test('maps offline/api exceptions to true', () {
      expect(isConnectivityError(OfflineException()), isTrue);
      expect(isConnectivityError(ServerUnavailableException()), isTrue);
      expect(isConnectivityError(NetworkException()), isTrue);
      expect(isConnectivityError(TimeoutException()), isTrue);
    });

    test('maps connection errors to true', () {
      expect(isConnectivityError(_dio(DioExceptionType.connectionError)), isTrue);
      expect(isConnectivityError(_dio(DioExceptionType.connectionTimeout)), isTrue);
      expect(isConnectivityError(_dio(DioExceptionType.sendTimeout)), isTrue);
      expect(isConnectivityError(_dio(DioExceptionType.receiveTimeout)), isTrue);
    });

    test('maps unknown SocketException to true', () {
      final e = DioException(
        type: DioExceptionType.unknown,
        message: 'SocketException: Connection refused',
        requestOptions: RequestOptions(path: '/x'),
      );
      expect(isConnectivityError(e), isTrue);
    });

    test('non-connectivity errors are false', () {
      expect(isConnectivityError(ValidationException()), isFalse);
      expect(isConnectivityError(NotFoundException()), isFalse);
      expect(isConnectivityError(ServerException()), isFalse);
      expect(isConnectivityError(_dio(DioExceptionType.badResponse)), isFalse);
      expect(isConnectivityError(Exception('boom')), isFalse);
    });
  });
}