import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/directory_pilot_build.dart';
import '../../core_business/data/local_directory/directory_pilot.dart';
import '../../core_business/data/local_directory/directory_scope.dart';
import '../../core_business/data/local_ledger/business_relay_identity.dart';

const employeeDeviceFinanceEnabled =
    DirectoryPilotBuild.signupEnabled &&
    bool.fromEnvironment('FYONA_BUSINESS_LEDGER_QA') &&
    bool.fromEnvironment('FYONA_BUSINESS_EMPLOYEE_FINANCE_QA');

typedef EmployeeReadSelection = ({
  String server,
  String account,
  String organization,
  String branch,
  String employee,
  String revision,
});

EmployeeReadSelection? resolveEmployeeReadSelection({
  required String server,
  required String account,
  required String? organization,
  required String? branch,
  required String? token,
  required bool allMode,
}) {
  if (!employeeDeviceFinanceEnabled ||
      !validDirectoryPilotScope(server, account, organization, branch) ||
      allMode ||
      token == null) {
    return null;
  }
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (claims is! Map ||
        claims['typ'] != 'branch_scope' ||
        claims['mode'] != 'branch' ||
        claims['sub'] != account ||
        claims['org'] != organization ||
        claims['branch'] != branch ||
        claims['qa_business_ledger'] == true ||
        claims['qa_directory'] == true) {
      return null;
    }
    final grant = claims['qa_employee_finance'];
    if (grant is! Map ||
        grant['employee_id'] is! String ||
        !isDirectoryId(grant['employee_id'] as String) ||
        grant['revision'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(grant['revision'] as String)) {
      return null;
    }
    return (
      server: server,
      account: account,
      organization: organization!,
      branch: branch!,
      employee: grant['employee_id'] as String,
      revision: grant['revision'] as String,
    );
  } on FormatException {
    return null;
  }
}

class EmployeeReadCopy {
  EmployeeReadCopy._(this.expires, this.profile, this.employment, this.finance);

  static EmployeeReadCopy? parse(
    Map<String, dynamic>? data,
    EmployeeReadSelection scope,
    String session,
  ) {
    if (data == null ||
        data['account_id'] != scope.account ||
        data['session_id'] != session ||
        data['organization_id'] != scope.organization ||
        data['branch_id'] != scope.branch ||
        data['employee_id'] != scope.employee ||
        data['grant_revision'] != scope.revision) {
      return null;
    }
    final expires = DateTime.tryParse('${data['expires_at']}');
    final profile = data['profile'];
    final employee = profile is Map ? profile['employee'] : null;
    final organization = profile is Map ? profile['organization'] : null;
    final employment = data['employment'];
    final employer = employment is Map ? employment['organization'] : null;
    final finance = data['finance'];
    if (expires == null ||
        !expires.isAfter(DateTime.now()) ||
        employee is! Map ||
        employee['id'] != scope.employee ||
        employee['linked_user_id'] != scope.account ||
        organization is! Map ||
        organization['id'] != scope.organization ||
        employment is! Map ||
        employment['employee_id'] != scope.employee ||
        employment['status'] != 'accepted' ||
        employer is! Map ||
        employer['id'] != scope.organization ||
        (finance != null &&
            (finance is! Map ||
                finance['organization_id'] != scope.organization ||
                finance['employee_id'] != scope.employee ||
                finance['salary'] is! List ||
                finance['debts'] is! List ||
                finance['balances'] is! Map))) {
      return null;
    }
    return EmployeeReadCopy._(
      expires,
      Map<String, dynamic>.from(profile as Map),
      Map<String, dynamic>.from(employment),
      finance == null ? null : Map<String, dynamic>.from(finance as Map),
    );
  }

  final DateTime expires;
  final Map<String, dynamic> profile;
  final Map<String, dynamic> employment;
  final Map<String, dynamic>? finance;
}

/// An immutable authentication attempt. Uses the opt-in Business HTTP client
/// without global retry, branch switching, or auth side effects.
class EmployeeFinanceTransport {
  EmployeeFinanceTransport(this._http, this.server, this._auth, this._token);

  final Dio _http;
  final String server;
  final Future<BusinessRelayIdentity?> Function() _auth;
  final String? Function() _token;
  final _cancel = CancelToken();
  bool get active => !_cancel.isCancelled;
  void dispose() => _cancel.cancel();

  Future<BusinessRelayIdentity?> identity() => _auth();

  Future<Map<String, dynamic>> request(
    BusinessRelayIdentity auth,
    String method,
    String path, {
    Object? body,
  }) async {
    final token = _token();
    if (!active || token == null || server != DirectoryPilotBuild.baseUrl) {
      throw const DirectoryAccessDenied();
    }
    final res = await _http.request<Map<String, dynamic>>(
      '$server/business/employee-finance$path',
      data: body,
      cancelToken: _cancel,
      options: Options(
        method: method,
        followRedirects: false,
        headers: {
          'Authorization': 'Bearer ${auth.accessToken}',
          'X-Branch-Token': token,
        },
      ),
    );
    if (!active || (await _auth())?.sessionId != auth.sessionId) {
      throw const DirectoryAccessDenied();
    }
    final data = res.data?['data'];
    if (data is! Map) throw const FormatException('Invalid employee copy');
    return Map<String, dynamic>.from(data);
  }
}
