import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/dio_provider.dart';
import '../network/api_client.dart';

class AuditEvent {
  final String action;
  final String resource;
  final String? resourceId;
  final String? details;
  final String? ipAddress;
  final String? userId;
  final String? orgId;
  final DateTime timestamp;

  AuditEvent({
    required this.action,
    required this.resource,
    this.resourceId,
    this.details,
    this.ipAddress,
    this.userId,
    this.orgId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'action': action,
        'resource': resource,
        if (resourceId != null) 'resource_id': resourceId,
        if (details != null) 'details': details,
        if (ipAddress != null) 'ip_address': ipAddress,
        if (userId != null) 'user_id': userId,
        if (orgId != null) 'organization_id': orgId,
        'created_at': timestamp.toIso8601String(),
      };
}

abstract class AuditService {
  Future<void> logEvent(AuditEvent event);
  Future<List<AuditEvent>> getLogs({
    String? orgId,
    String? userId,
    String? action,
    String? resource,
    DateTime? fromDate,
    DateTime? toDate,
    int skip = 0,
    int limit = 100,
  });
  Future<int> getLogsCount({
    String? orgId,
    String? userId,
    String? action,
    String? resource,
  });
}

class AuditServiceImpl implements AuditService {
  final ApiClient _apiClient;

  AuditServiceImpl({required this._apiClient});

  @override
  Future<void> logEvent(AuditEvent event) async {
    // Audit logging is local-only; the backend has no POST /audit/logs endpoint.
    // The admin dashboard reads audit logs via GET /admin/audit-logs.
  }

  @override
  Future<List<AuditEvent>> getLogs({
    String? orgId,
    String? userId,
    String? action,
    String? resource,
    DateTime? fromDate,
    DateTime? toDate,
    int skip = 0,
    int limit = 100,
  }) async {
    try {
      final params = <String, dynamic>{
        'skip': skip,
        'limit': limit,
        if (orgId != null) 'organization_id': orgId,
        if (userId != null) 'user_id': userId,
        if (action != null) 'action': action,
        if (resource != null) 'resource': resource,
        if (fromDate != null) 'from_date': fromDate.toIso8601String(),
        if (toDate != null) 'to_date': toDate.toIso8601String(),
      };
      final response = await _apiClient.getSafe<List<dynamic>>(
        '/admin/audit-logs',
        queryParameters: params,
      );
      if (response.success && response.data != null) {
        return response.data!.map((e) {
          final m = e as Map<String, dynamic>;
          return AuditEvent(
            action: m['action'] as String,
            resource: m['resource'] as String,
            resourceId: m['resource_id'] as String?,
            details: m['details'] as String?,
            ipAddress: m['ip_address'] as String?,
            userId: m['user_id'].toString(),
            orgId: m['organization_id'].toString(),
            timestamp: DateTime.tryParse(m['created_at'].toString()) ?? DateTime.now(),
          );
        }).toList();
      }
    } catch (_) {}
    return [];
  }

  @override
  Future<int> getLogsCount({
    String? orgId,
    String? userId,
    String? action,
    String? resource,
  }) async {
    final logs = await getLogs(orgId: orgId, userId: userId, action: action, resource: resource, limit: 1000);
    return logs.length;
  }
}

final auditServiceProvider = Provider<AuditService>((ref) {
  ref.watch(dioProvider);
  return AuditServiceImpl(apiClient: ref.read(apiClientProvider));
});
