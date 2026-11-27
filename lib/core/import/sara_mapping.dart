import '../network/api_client.dart';
import 'import_plan.dart';
import 'import_schema.dart';
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


/// Sara's view of the tables the rules could not place (names, columns and
/// at most 5 sample rows each are sent). Null when Sara is unavailable.
Future<List<Map<String, dynamic>>?> saraImportSchema(ApiClient api, List<TableAnalysis> unclear) async {
  if (unclear.isEmpty) return const [];
  try {
    final tables = [
      for (final a in unclear.take(30))
        {
          'name': a.table.name.length > 120 ? a.table.name.substring(0, 120) : a.table.name,
          'columns': a.table.columns.take(200).toList(),
          'sample': [
            for (final r in await a.table.sample(5)) [for (final v in r) v == null ? null : (v.length > 60 ? v.substring(0, 60) : v)],
          ],
        },
    ];
    final r = await api.post<Map<String, dynamic>>('/ai/import-schema', data: {'tables': tables});
    final list = (r.data?['data'] as Map?)?['tables'];
    if (list is! List) return null;
    return [for (final e in list) if (e is Map) Map<String, dynamic>.from(e)];
  } catch (_) {
    return null;
  }
}
