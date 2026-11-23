import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../config/directory_pilot_build.dart';
import '../localization/app_localizations.dart';
import '../router/shell_keys.dart';
import '../theme/app_colors.dart';
import 'api_interceptors.dart';
import 'retry_interceptor.dart';
import 'token_refresh_interceptor.dart';
import '../storage/secure_storage.dart';
import '../../features/branches/data/branch_epoch.dart';
import '../../features/branches/data/branch_scope.dart';
import '../../features/branches/data/branch_revocation.dart';

bool _readOnlyDialogOpen = false;

/// Read-only POSTs must keep the signed all-branch scope, never select a write branch.
bool isFalconReadOnlyPath(String path) =>
    path == '/inventory/falcon/analyze' || path == '/inventory/falcon/chat';

bool requiresScopedCreateBranch(String path, {required bool businessPath}) =>
    businessPath &&
    !isFalconReadOnlyPath(path) &&
    !path.startsWith('/branches') &&
    !path.startsWith('/business/project-settings') &&
    !RegExp(r'/[0-9a-fA-F-]{36}(/|$)').hasMatch(path);

void _showReadOnlyDialog() {
  if (_readOnlyDialogOpen) return;
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return;
  _readOnlyDialogOpen = true;
  final l10n = AppLocalizations.of(ctx);
  showDialog<void>(
    context: ctx,
    barrierDismissible: true,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      contentPadding: const EdgeInsets.fromLTRB(22, 22, 22, 10),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.visibility_rounded,
              color: AppColors.primary,
              size: 28,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.translate('branchReadOnlyDialogTitle'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.translate('branchReadOnlyDialogBody'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              height: 1.55,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(
              l10n.translate('branchReadOnlyDialogOk'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    ),
  ).whenComplete(() => _readOnlyDialogOpen = false);
}

final dioProvider = Provider<Dio>((ref) {
  final secureStorage = ref.watch(secureStorageProvider);
  final baseUrl = ref.watch(serverBaseUrlProvider);
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(
        seconds: AppConfig.apiConnectTimeoutSeconds,
      ),
      receiveTimeout: const Duration(
        seconds: AppConfig.apiReceiveTimeoutSeconds,
      ),
      sendTimeout: const Duration(seconds: AppConfig.apiTimeoutSeconds),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ),
  );
  debugPrint(
    '[Dio] baseUrl=${dio.options.baseUrl} '
    'connectTimeout=${dio.options.connectTimeout?.inSeconds}s '
    'receiveTimeout=${dio.options.receiveTimeout?.inSeconds}s '
    'sendTimeout=${dio.options.sendTimeout?.inSeconds}s',
  );

  if (DirectoryPilotBuild.enabled) {
    dio.options.followRedirects = false;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (!DirectoryPilotBuild.allows(request.uri)) {
        handler.reject(DioException(requestOptions: request));
        return;
      }
      request.followRedirects = false;
      handler.next(request);
    }));
  }
  dio.interceptors.addAll([
    AuthInterceptor(secureStorage),
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        // «جميع الفروع» is READ-ONLY. The backend already enforces this;
        // blocking here makes every screen safe without touching each one.
        final method = options.method.toUpperCase();
        final path = options.path;
        final businessPath =
            path.startsWith('/business') ||
            path.startsWith('/banking') ||
            path.startsWith('/products') ||
            path.startsWith('/inventory') ||
            path.startsWith('/customers') ||
            path.startsWith('/suppliers') ||
            path.startsWith('/invoices') ||
            path.startsWith('/finance') ||
            path.startsWith('/branches') ||
            path.startsWith('/accounting') ||
            path.startsWith('/reconciliation') ||
            path.startsWith('/business-reports') ||
            path.startsWith('/sales') ||
            path.startsWith('/purchases') ||
            path.startsWith('/reports');
        // The legacy API chooses a default branch when there is no token.
        // A locally selected branch must never send data to that default.
        if (BranchScope.awaitingServerSelection &&
            (businessPath ||
                const ['/categories', '/returns', '/payments', '/cheques',
                       '/expenses', '/merchant-links', '/employees']
                    .any(path.startsWith)) &&
            !const {'/branches/select', '/branches/access',
                    '/branches/invitations', '/employees/me'}
                .contains(path) &&
            !path.startsWith('/employees/me/') &&
            !path.startsWith('/employees/invitations') &&
            !(path.startsWith('/employees/') && path.endsWith('/unlink')) &&
            !RegExp(r'^/branches/invitations/[^/]+/respond$').hasMatch(path)) {
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            error: 'branch_selection_not_verified',
          ));
          return;
        }
        final t = BranchScope.token;
        if (t != null &&
            t.isNotEmpty &&
            options.extra['branchScopeSnapshot'] != true) {
          options.headers['X-Branch-Token'] = t;
        }
        final allowedBranchWrite = path.startsWith('/branches/select') ||
          path == '/business-sara/query' || path == '/business-sara/query-attachment' ||
          path == '/business-sara/continue' ||
          isFalconReadOnlyPath(path);
        if (BranchScope.readOnly &&
            businessPath &&
            !allowedBranchWrite &&
            method != 'GET' &&
            method != 'HEAD' &&
            method != 'OPTIONS') {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: 409,
                data: {
                  'success': false,
                  'message':
                      'لا يمكنك تنفيذ العمليات أثناء عرض جميع الفروع. يرجى الانتقال إلى الفرع المطلوب لتنفيذ العملية.',
                },
              ),
              error: 'all_branches_read_only',
            ),
          );
          return;
        }
        final mutating = !const ['GET', 'HEAD', 'OPTIONS'].contains(method);
        final scopedCreate = requiresScopedCreateBranch(path, businessPath: businessPath);
        final data = options.data;
        if (BranchScope.allMode &&
            !BranchScope.readOnly &&
            mutating &&
            scopedCreate &&
            !(data is Map && data['branch_id'] != null) &&
            options.queryParameters['branch_id'] == null) {
          final chosen = await _chooseWriteBranch(
            dio,
            BranchScope.permittedBranchIds,
          );
          if (chosen == null || BranchScope.token != t) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.cancel,
                error: 'branch_selection_cancelled',
              ),
            );
            return;
          }
          options.headers['X-Branch-Id'] = chosen;
        }
        handler.next(options);
      },
      // Branch scope tokens expire (12h). Refresh ONCE via the current
      // authenticated session, re-verify the branch, then retry the original
      // request. Losing the network is not a permission change and must not
      // clear the branch selection or expire the unrelated account session.
      onError: (e, handler) async {
        if (BranchScope.readOnly &&
            e.response?.statusCode == 409 &&
            !const [
              'GET',
              'HEAD',
              'OPTIONS',
            ].contains(e.requestOptions.method.toUpperCase())) {
          _showReadOnlyDialog();
        }
        final opts = e.requestOptions;
        // Refresh ONLY for an expired/invalid branch-scope token (explicit
        // backend code). Permission revocation, archived branches and other
        // 401/403 must NOT trigger a retry.
        final detail = e.response?.data is Map
            ? (e.response!.data as Map)['detail'] ??
                  (e.response!.data as Map)['message']
            : null;
        final code = detail is Map ? '${detail['code'] ?? ''}' : '';
        if (e.response?.statusCode == 403 &&
            code == 'merchant_subscription_expired') {
          final token = opts.headers['X-Branch-Token']?.toString();
          if (token == BranchScope.token) {
            ref.read(merchantSubscriptionBlockedScopeProvider.notifier).state =
                token ?? '__own__';
          }
          handler.next(e);
          return;
        }
        if (e.response?.statusCode == 403 &&
            code == 'employee_workspace_revoked') {
          final cleared = await clearRevokedBranchScope(
            opts.headers['X-Branch-Token']?.toString(),
          );
          if (cleared) ref.read(branchRevocationProvider.notifier).state++;
          // Never replay a rejected write against the user's own company.
          handler.next(e);
          return;
        }
        final canTry =
            code == 'branch_scope_expired' &&
            BranchScope.token != null &&
            opts.headers['X-Branch-Token'] == BranchScope.token &&
            (opts.extra['branchScopeSnapshot'] != true ||
                opts.extra['branchScopeIdentity'] ==
                    '${BranchScope.organizationId}|${BranchScope.allMode}|${BranchScope.branchId}') &&
            (BranchScope.branchId != null || BranchScope.allMode) &&
            opts.headers['x-branch-retried'] != true;
        if (!canTry) {
          if (code == 'branch_scope_expired') {
            handler.reject(e);
          } else {
            handler.next(e);
          }
          return;
        }
        final selection = BranchScope.selection;
        final (refreshOrg, refreshBranch, refreshAll, _) = selection;
        final expiredToken = BranchScope.token;
        bool stillSelected() =>
            selection == BranchScope.selection && expiredToken == BranchScope.token;
        try {
          final r = await dio.post(
            '/branches/select',
            data: {
              'branch_id': refreshBranch,
              'all': refreshAll,
              if (refreshOrg != null) 'organization_id': refreshOrg,
            },
            options: Options(headers: {'x-branch-retried': true}),
          );
          if (!stillSelected()) {
            handler.reject(e);
            return;
          }
          final d = r.data;
          final data = (d is Map && d['data'] != null) ? d['data'] : d;
          final token = '${data['token'] ?? ''}';
          if (token.isEmpty ||
              data['branch_id']?.toString() != refreshBranch ||
              data['organization_id']?.toString() != refreshOrg) {
            throw StateError('Invalid branch refresh');
          }
          await BranchScope.save(
            token: token,
            branchId: refreshBranch,
            branchName: (data['branch'] is Map)
                ? data['branch']['name']?.toString()
                : BranchScope.branchName,
            allMode: refreshAll,
            organizationId: refreshOrg,
            stillSelected: stillSelected,
          );
          if (const bool.fromEnvironment('FYONA_BUSINESS_EMPLOYEE_FINANCE_QA') &&
              BranchScope.token == token) {
            if (const bool.fromEnvironment('FYONA_BUSINESS_EMPLOYEE_FINANCE_QA')) {
              ref.read(branchTokenRefreshProvider.notifier).state++;
            }
          }
          // The retry belongs to the original branch, even if the global
          // selection changes while the request passes through auth.
          opts.extra['branchScopeSnapshot'] = true;
          opts.headers['X-Branch-Token'] = token;
          opts.headers['x-branch-retried'] = true;
          final response = await dio.fetch(opts);
          handler.resolve(response);
        } catch (error) {
          if (stillSelected() && error is DioException &&
              const {403, 404}.contains(error.response?.statusCode) &&
              await clearRevokedBranchScope(expiredToken)) {
            ref.read(branchTokenRefreshProvider.notifier).state++;
          }
          handler.reject(e);
        }
      },
    ),
    RetryInterceptor(dio: dio),
    TokenRefreshInterceptor(secureStorage: secureStorage, dio: dio),
    InterceptorsWrapper(
      onRequest: (options, handler) {
        debugPrint('[HTTP] --> ${options.method} ${options.uri}');
        handler.next(options);
      },
      onResponse: (response, handler) {
        debugPrint(
          '[HTTP] <-- ${response.statusCode} ${response.requestOptions.method} '
          '${response.requestOptions.uri}',
        );
        handler.next(response);
      },
      onError: (e, handler) {
        debugPrint(
          '[HTTP] <-- ERROR ${e.type} ${e.message} '
          '${e.requestOptions.method} ${e.requestOptions.uri}',
        );
        handler.next(e);
      },
    ),
  ]);

  return dio;
});

/// Runtime server address (any LAN device can point the app at the backend).
/// Initialized from the persisted override (or the build default) at startup;
/// changing it rebuilds the whole network stack (Dio + interceptors).
final serverBaseUrlProvider = StateProvider<String>(
  (ref) => AppConfig.effectiveApiBaseUrl,
);

/// Normalize free-form server input into a full `/api/v1` base URL:
/// - "192.168.8.139" → "http://192.168.8.139:8001/api/v1" (bare LAN host
///   defaults to the backend port, since the backend always serves 8001);
/// - explicit ports/paths/schemes are respected as typed.
String normalizeServerBaseUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return AppConfig.apiBaseUrl;
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'http://$s';
  }
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return AppConfig.apiBaseUrl;
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  // Bare hosts default to the backend port on plain http (LAN dev);
  // https keeps the default 443 and explicit ports are always respected.
  final withPort = uri.hasPort || uri.scheme == 'https'
      ? s
      : '${uri.scheme}://${uri.host}:8001${path.isEmpty ? '' : path}';
  final noTrail = withPort.replaceAll(RegExp(r'/+$'), '');
  if (noTrail.endsWith('/api/v1')) return noTrail;
  return '$noTrail/api/v1';
}

Future<String?> _chooseWriteBranch(Dio dio, List<String> ids) async {
  final context = rootNavigatorKey.currentContext;
  if (context == null || ids.isEmpty) return null;
  try {
    final response = await dio.get('/branches/access');
    final body = response.data;
    final data = body is Map ? body['data'] : null;
    final companies = data is Map
        ? data['companies'] as List? ?? const []
        : const [];
    final choices = <Map>[];
    for (final company in companies.whereType<Map>()) {
      if ('${company['organization_id']}' != BranchScope.organizationId)
        continue;
      for (final branch
          in (company['branches'] as List? ?? const []).whereType<Map>()) {
        if (ids.contains('${branch['id']}')) choices.add(branch);
      }
    }
    if (!context.mounted || choices.isEmpty) return null;
    return await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('اختر فرع العملية'),
        children: [
          for (final branch in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '${branch['id']}'),
              child: Text('${branch['name']}'),
            ),
        ],
      ),
    );
  } catch (_) {
    return null;
  }
}

/// Persist a new server address and apply it live (Dio rebuilds via the
/// provider above; static host helpers follow through [AppConfig]).
Future<void> persistServerBaseUrl(WidgetRef ref, String url) async {
  if (DirectoryPilotBuild.enabled && url != DirectoryPilotBuild.baseUrl) {
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('server_base_url', url);
  AppConfig.overrideBaseUrl = url;
  ref.read(serverBaseUrlProvider.notifier).state = url;
}

class ApiClient {
  final Dio dio;

  ApiClient({required this.dio});

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return dio.get<T>(
      path,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return dio.post<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> put<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return dio.put<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> patch<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return dio.patch<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return dio.delete<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }
}
