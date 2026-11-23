import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_exceptions.dart';
import 'package:fyona_flutter/core/network/error_handler.dart';

import '../../test_utils.dart';

DioException _connError(String baseUrl) => DioException(
      type: DioExceptionType.connectionError,
      requestOptions: RequestOptions(path: '/auth/login', baseUrl: baseUrl),
    );

void main() {
  // Error messages are built through AppLocalizations.t, which returns the raw
  // key when no ARB table is cached — preload so assertions see real text.
  setUpAll(() => ensureTestLocalization());

  group('handleDioException connection errors', () {
    test('loopback host surfaces as server unavailable', () {
      final e = handleDioException(_connError('http://127.0.0.1:8001/api/v1'));
      expect(e, isA<ServerUnavailableException>());
      expect(e.message, contains('الخادم غير متاح'));
    });

    test('localhost host surfaces as server unavailable', () {
      final e = handleDioException(_connError('http://localhost:8001/api/v1'));
      expect(e, isA<ServerUnavailableException>());
    });

    test('private LAN host surfaces as server unavailable', () {
      final e = handleDioException(_connError('http://192.168.1.5:8001/api/v1'));
      expect(e, isA<ServerUnavailableException>());
    });

    test('public host surfaces as offline', () {
      final e = handleDioException(_connError('https://api.dssdfs.fun/api/v1'));
      expect(e, isA<OfflineException>());
      expect(e.message, contains('لا يوجد اتصال بالإنترنت'));
    });

    test('SocketException in unknown type uses host-aware mapping', () {
      final local = DioException(
        type: DioExceptionType.unknown,
        message: 'SocketException: Connection refused',
        requestOptions: RequestOptions(path: '/x', baseUrl: 'http://127.0.0.1:8001'),
      );
      expect(handleDioException(local), isA<ServerUnavailableException>());

      final remote = DioException(
        type: DioExceptionType.unknown,
        message: 'SocketException: Failed host lookup',
        requestOptions: RequestOptions(path: '/x', baseUrl: 'https://api.example.com'),
      );
      expect(handleDioException(remote), isA<OfflineException>());
    });

    test('non-socket unknown errors surface as network error', () {
      final e = DioException(
        type: DioExceptionType.unknown,
        message: 'Some other unknown thing',
        requestOptions: RequestOptions(path: '/x', baseUrl: 'https://api.example.com'),
      );
      expect(handleDioException(e), isA<NetworkException>());
    });
  });

  group('handleDioException status code errors', () {
    test('404 maps to NotFoundException with server message', () {
      final e = DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 404,
          data: {'message': 'المورد غير موجود'},
        ),
        requestOptions: RequestOptions(path: '/x'),
      );
      final err = handleDioException(e);
      expect(err, isA<NotFoundException>());
      expect(err.message, 'المورد غير موجود');
    });
  });
}