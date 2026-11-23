import '../../../core/network/api_client.dart';
import '../../core_business/data/local_directory/directory_database.dart';
import '../../core_business/data/local_directory/directory_scope.dart';
import 'package:dio/dio.dart';

import 'employee_local_finance.dart';

class EmployeeApi {
  static String message(Object e) {
    if (e is DirectoryAccessDenied) {
      return 'ما عندك صلاحية لهذي العملية الآن';
    }
    if (e is BusinessCashEqualizationPending) {
      return 'في طلب تسوية معلّق؛ انتظر قراره أول';
    }
    if (e is BusinessLedgerError) {
      return switch (e.problem) {
        BusinessLedgerProblem.invalidAmount => 'اكتب مبلغ صحيح أكبر من صفر',
        BusinessLedgerProblem.insufficientBalance => 'الرصيد في الحساب ما يكفي',
        BusinessLedgerProblem.currencyMismatch => 'اختر حساب بنفس عملة العملية',
        BusinessLedgerProblem.sharedCashRequiresArbitration =>
          'هذا الحساب المشترك ما يتحرك إلا عن طريق التسوية المشتركة',
        BusinessLedgerProblem.invalidEmployee =>
          'بيانات الموظف أو العملية غير مكتملة',
        _ => 'تعذر تنفيذ العملية',
      };
    }
    try {
      final dynamic d = (e as dynamic).response?.data;
      final v = d is Map ? (d['detail'] ?? d['message']) : null;
      if (v is Map) return '${v['message'] ?? ''}';
      if (v is String) return v;
    } catch (_) {}
    return 'تعذر تنفيذ العملية';
  }

  EmployeeApi(
    this._client, {
    EmployeeLocalFinance? Function()? localFinance,
    bool Function()? employeeDeviceSelected,
  }) : _localFinance = localFinance,
       _employeeDeviceSelected = employeeDeviceSelected;
  final ApiClient _client;
  final EmployeeLocalFinance? Function()? _localFinance;
  final bool Function()? _employeeDeviceSelected;

  EmployeeLocalFinance? _managementSource() {
    if (_employeeDeviceSelected?.call() == true)
      throw const DirectoryAccessDenied();
    return _localFinance?.call();
  }

  Map<String, dynamic> _data(dynamic body) => body is Map && body['data'] is Map
      ? Map<String, dynamic>.from(body['data'])
      : {};

  Future<List<Map<String, dynamic>>> list() async {
    final r = await _client.get('/employees');
    return ((_data(r.data)['employees'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> lookup(String code) async {
    final r = await _client.get(
      '/employees/lookup',
      queryParameters: {'code': code},
    );
    return Map<String, dynamic>.from((_data(r.data)['user'] as Map?) ?? {});
  }

  Future<Map<String, dynamic>> create(Map<String, dynamic> body) async {
    final r = await _client.post('/employees', data: body);
    return _data(r.data);
  }

  Future<Map<String, dynamic>> update(
    String id,
    Map<String, dynamic> body,
  ) async {
    final r = await _client.put('/employees/$id', data: body);
    return _data(r.data);
  }

  Future<Map<String, dynamic>> invite(
    String id,
    String code,
    Map<String, bool> permissions, {
    List<String>? branchIds,
  }) async {
    final r = await _client.post(
      '/employees/$id/invite',
      data: {
        'code': code,
        'permissions': permissions,
        if (branchIds != null) 'branch_ids': branchIds,
      },
    );
    return _data(r.data);
  }

  Future<void> remove(String id) async {
    await _client.delete('/employees/$id');
  }

  Future<Map<String, dynamic>> unlink(String id) async {
    final r = await _client.post('/employees/$id/unlink');
    final result = _data(r.data);
    if (result['organization_id'] == null) {
      throw StateError('Invalid unlink response');
    }
    return result;
  }

  Future<Map<String, dynamic>> salary(String id) async {
    final local = _managementSource();
    if (local != null) return local.salaryLedger(id);
    final r = await _client.get('/employees/$id/salary');
    return _data(r.data);
  }

  Future<Map<String, dynamic>> paySalary(
    String id,
    Map<String, dynamic> body,
  ) async {
    final local = _managementSource();
    if (local != null) return local.paySalary(id, body);
    final r = await _client.post('/employees/$id/salary', data: body);
    return _data(r.data);
  }

  Future<Map<String, dynamic>> debts(String id) async {
    final local = _managementSource();
    if (local != null) return local.debtsLedger(id);
    final r = await _client.get('/employees/$id/debts');
    return _data(r.data);
  }

  Future<Map<String, dynamic>> addDebt(
    String id,
    Map<String, dynamic> body,
  ) async {
    final local = _managementSource();
    if (local != null) return local.addDebt(id, body);
    final r = await _client.post('/employees/$id/debts', data: body);
    return _data(r.data);
  }

  Future<List<Map<String, dynamic>>> myInvitations() async {
    final r = await _client.get('/employees/invitations/me');
    return ((_data(r.data)['invitations'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> respond(String id, bool accept) async {
    final r = await _client.post(
      '/employees/invitations/$id/respond',
      data: {'accept': accept},
    );
    return _data(r.data);
  }

  Future<Map<String, dynamic>> myFinance({String? employeeId}) async {
    if (_employeeDeviceSelected?.call() == true)
      throw const DirectoryAccessDenied();
    final local = _localFinance?.call();
    if (local != null) return local.myFinance(employeeId: employeeId);
    final r = await _client.get(
      '/employees/me/finance',
      queryParameters: {if (employeeId != null) 'employee_id': employeeId},
    );
    return _data(r.data);
  }

  Future<Map<String, dynamic>> invitation(String id) async {
    final r = await _client.get('/employees/invitations/$id');
    return _data(r.data);
  }

  Future<Map<String, dynamic>> myProfile({String? organizationId}) async {
    final r = await _client.get(
      '/employees/me/profile',
      queryParameters: {
        if (organizationId != null) 'organization_id': organizationId,
      },
    );
    return _data(r.data);
  }

  Future<void> heartbeat({bool online = true, String? scopeToken}) async {
    try {
      await _client.dio.post(
        '/employees/me/heartbeat?online=$online',
        options: scopeToken == null
            ? null
            : Options(
                headers: {'X-Branch-Token': scopeToken},
                extra: {
                  'branchScopeSnapshot': true,
                  'branchScopeIdentity': scopeToken,
                },
              ),
      );
    } catch (_) {}
  }
}
