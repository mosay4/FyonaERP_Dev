import '../network/api_client.dart';
import 'import_plan.dart';
import 'import_source.dart';

/// Asks Sara which column is which field. Sends ONLY the column titles and
/// at most 30 sample rows (values cut to 60 characters); the answer is a
/// suggestion the user sees and can change. Any failure returns null and
/// the deterministic mapping stays.
Future<Map<String, String>?> saraImportMapping(ApiClient api, ImportTarget target, ImportTable table) async {
  try {
    final sample = [
      for (final r in await table.sample(30)) [for (final v in r) v == null ? null : (v.length > 60 ? v.substring(0, 60) : v)],
    ];
    final r = await api.post<Map<String, dynamic>>('/ai/import-mapping', data: {
      'target': target.name,
      'columns': table.columns,
      'sample': sample,
    });
    final m = (r.data?['data'] as Map?)?['mapping'];
    if (m is! Map) return null;
    final fields = {for (final f in importFields[target]!) f.key};
    return {
      for (final e in m.entries)
        if (fields.contains('${e.key}') && table.columns.contains('${e.value}')) '${e.key}': '${e.value}',
    };
  } catch (_) {
    return null;
  }
}
