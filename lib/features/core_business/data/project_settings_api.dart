import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_provider.dart';
import '../../../core/network/api_client.dart';

class ProjectSettingsApi {
  ProjectSettingsApi(this._client);
  final ApiClient _client;
  Future<Map<String, dynamic>> load() async {
    final r = await _client.get('/business/project-settings');
    return Map<String, dynamic>.from(r.data['data']['settings'] as Map? ?? {});
  }

  Future<void> save(Map<String, dynamic> patch) async {
    await _client.put('/business/project-settings', data: patch);
  }
}

final projectSettingsApiProvider = Provider(
  (ref) => ProjectSettingsApi(ref.watch(apiClientProvider)),
);

final projectSettingsProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(projectSettingsApiProvider).load(),
);
