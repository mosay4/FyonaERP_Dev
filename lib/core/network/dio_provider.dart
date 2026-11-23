// Single source of truth for all feature module API imports.
// Features import this file for: apiClientProvider, getSafe/postSafe extensions, ApiClient, ApiResponse, etc.

import 'package:dio/dio.dart';
import 'api_client.dart';
import 'api_response.dart';
import 'error_handler.dart';

export '../di/providers.dart' show apiClientProvider, secureStorageProvider;
export 'api_client.dart' show dioProvider, ApiClient;

// ─── Safe extension methods used by all feature repos ───
extension ApiClientSafe on ApiClient {
  Future<ApiResponse<T>> getSafe<T>(String path, {Map<String, dynamic>? queryParameters, T Function(dynamic)? fromJson}) async {
    try { final r = await get(path, queryParameters: queryParameters); return ApiResponse.fromJson(r.data as Map<String, dynamic>, fromJsonT: fromJson); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Future<ApiResponse<T>> postSafe<T>(String path, {dynamic data, Options? options, T Function(dynamic)? fromJson}) async {
    try { final r = await post(path, data: data, options: options); return ApiResponse.fromJson(r.data as Map<String, dynamic>, fromJsonT: fromJson); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Future<ApiResponse<T>> putSafe<T>(String path, {dynamic data, T Function(dynamic)? fromJson}) async {
    try { final r = await put(path, data: data); return ApiResponse.fromJson(r.data as Map<String, dynamic>, fromJsonT: fromJson); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Future<ApiResponse<T>> patchSafe<T>(String path, {dynamic data, T Function(dynamic)? fromJson}) async {
    try { final r = await patch(path, data: data); return ApiResponse.fromJson(r.data as Map<String, dynamic>, fromJsonT: fromJson); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Future<ApiResponse<T>> deleteSafe<T>(String path, {T Function(dynamic)? fromJson}) async {
    try { final r = await delete(path); return ApiResponse.fromJson(r.data as Map<String, dynamic>, fromJsonT: fromJson); }
    on DioException catch (e) { throw handleDioException(e); }
  }
}
