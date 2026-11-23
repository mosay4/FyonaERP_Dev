import '../../network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../interfaces/all_services.dart';

class SchedulerServiceImpl implements SchedulerService {
  final ApiClient? apiClient;

  SchedulerServiceImpl({this.apiClient});

  @override
  Future<List<Map<String, dynamic>>> getScheduledTasks() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/scheduler/tasks');
        return (response.data as List).whereType<Map<String, dynamic>>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('schedLoadTasksFailed', {'error': e.toString()}));
      }
    }
    return [
      {'id': 1, 'name': AppLocalizations.t('schedDemoDailyBackup'), 'description': AppLocalizations.t('schedDemoDailyBackupDesc'), 'type': 'backup', 'schedule': AppLocalizations.t('schedDemoDaily2300'), 'enabled': true, 'last_run': '2025-07-10 23:00', 'next_run': '2025-07-11 23:00', 'status': 'active'},
      {'id': 2, 'name': AppLocalizations.t('schedDemoAlerts'), 'description': AppLocalizations.t('schedDemoAlertsDesc'), 'type': 'alert', 'schedule': AppLocalizations.t('schedDemoEvery15'), 'enabled': true, 'last_run': '2025-07-11 14:30', 'next_run': '2025-07-11 14:45', 'status': 'active'},
      {'id': 3, 'name': AppLocalizations.t('schedDemoRates'), 'description': AppLocalizations.t('schedDemoRatesDesc'), 'type': 'sync', 'schedule': AppLocalizations.t('schedDemoEveryHour'), 'enabled': false, 'last_run': '2025-07-10 12:00', 'next_run': '—', 'status': 'paused'},
    ];
  }

  @override
  Future<Map<String, dynamic>> createTask(Map<String, dynamic> data) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.post('/api/scheduler/tasks', data: data);
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('schedCreateFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<bool> updateTask(int id, Map<String, dynamic> data) async {
    if (apiClient != null) {
      try {
        await apiClient!.put('/api/scheduler/tasks/$id', data: data);
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('schedUpdateFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<bool> deleteTask(int id) async {
    if (apiClient != null) {
      try {
        await apiClient!.delete('/api/scheduler/tasks/$id');
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('schedDeleteFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<bool> runNow(int id) async {
    if (apiClient != null) {
      try {
        await apiClient!.post('/api/scheduler/tasks/$id/run');
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('schedRunFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<List<Map<String, dynamic>>> getTaskLogs(int id) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/scheduler/tasks/$id/logs');
        return (response.data as List).whereType<Map<String, dynamic>>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('schedLogsFailed', {'error': e.toString()}));
      }
    }
    return [
      {'id': 1, 'task_id': id, 'started_at': '2025-07-11 14:00', 'finished_at': '2025-07-11 14:00', 'status': 'success', 'message': AppLocalizations.t('schedDemoLogSuccess')},
      {'id': 2, 'task_id': id, 'started_at': '2025-07-10 23:00', 'finished_at': '2025-07-10 23:02', 'status': 'success', 'message': AppLocalizations.t('schedDemoLogBackupOk')},
    ];
  }

  @override
  Future<Map<String, dynamic>> getSchedulerStatus() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/scheduler/status');
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('schedStatusFailed', {'error': e.toString()}));
      }
    }
    return {'is_running': true, 'last_run': '2025-07-11 14:30', 'next_run': '2025-07-11 14:45', 'active_tasks': 2, 'uptime': AppLocalizations.t('schedDemoUptime')};
  }
}
