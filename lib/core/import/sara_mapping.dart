import 'package:dio/dio.dart';

import '../network/api_client.dart';
import 'import_plan.dart';
import 'import_schema.dart';
import 'import_source.dart';

/// Sara thinks before she answers: give her calls room (the server bounds
/// them at 75 s).
final _saraOptions = Options(receiveTimeout: const Duration(seconds: 90), sendTimeout: const Duration(seconds: 30));

String? _cut(String? v) => v == null ? null : (v.length > 60 ? v.substring(0, 60) : v);

/// Asks Sara which column is which field. Sends ONLY the column titles and
/// at most 30 sample rows (values cut to 60 characters); the answer is a
/// suggestion the user sees and can change. Any failure returns null and
/// the deterministic mapping stays.
Future<Map<String, String>?> saraImportMapping(ApiClient api, ImportTarget target, ImportTable table) async {
  try {
    final sample = [
      for (final r in await table.sample(30)) [for (final v in r) _cut(v)],
    ];
    final r = await api.post<Map<String, dynamic>>('/ai/import-mapping', data: {
      'target': target.name,
      'columns': table.columns,
      'sample': sample,
    }, options: _saraOptions);
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

/// Sara's view of the tables (names, columns and at most 5 sample rows each
/// are sent, 30 tables per request). Null when Sara is unavailable.
Future<List<Map<String, dynamic>>?> saraImportSchema(ApiClient api, List<TableAnalysis> tables) async {
  if (tables.isEmpty) return const [];
  final out = <Map<String, dynamic>>[];
  try {
    for (var i = 0; i < tables.length && i < 120; i += 30) {
      final chunk = tables.sublist(i, i + 30 > tables.length ? tables.length : i + 30);
      final body = [
        for (final a in chunk)
          {
            'name': a.table.name.length > 120 ? a.table.name.substring(0, 120) : a.table.name,
            'columns': a.table.columns.take(200).toList(),
            'sample': [
              for (final r in await a.table.sample(5)) [for (final v in r) _cut(v)],
            ],
          },
      ];
      final r = await api.post<Map<String, dynamic>>('/ai/import-schema', data: {'tables': body}, options: _saraOptions);
      final list = (r.data?['data'] as Map?)?['tables'];
      if (list is! List) return out.isEmpty ? null : out;
      out.addAll([for (final e in list) if (e is Map) Map<String, dynamic>.from(e)]);
    }
    return out;
  } catch (_) {
    return out.isEmpty ? null : out;
  }
}

/// One answer of Sara inside the import window.
class SaraAgentAnswer {
  const SaraAgentAnswer(this.reply, this.ops);
  final String reply;
  final List<Map<String, dynamic>> ops;
}

/// Sends the user's request with the file's OUTLINE (table names, roles,
/// columns, mapping, ≤3 sample rows cut to 60 characters). Null when Sara
/// is unavailable.
Future<SaraAgentAnswer?> saraImportAgent(
  ApiClient api, {
  required String message,
  required String currency,
  required List<TableAnalysis> tables,
  List<Map<String, String>> history = const [],
}) async {
  try {
    final outline = [
      for (final a in tables.take(60))
        {
          'name': a.table.name.length > 120 ? a.table.name.substring(0, 120) : a.table.name,
          'role': a.role.name,
          'rows': await a.table.count(),
          'columns': a.table.columns.take(120).toList(),
          'mapping': a.mapping,
          'sample': [
            for (final r in await a.table.sample(3)) [for (final v in r.take(40)) _cut(v)],
          ],
        },
    ];
    final r = await api.post<Map<String, dynamic>>('/ai/import-agent', data: {
      'message': message.length > 800 ? message.substring(0, 800) : message,
      'currency': currency,
      'tables': outline,
      'history': history.length > 8 ? history.sublist(history.length - 8) : history,
    }, options: _saraOptions);
    final d = r.data?['data'];
    if (d is! Map) return null;
    return SaraAgentAnswer('${d['reply'] ?? ''}', [
      for (final o in (d['ops'] as List? ?? const []))
        if (o is Map) Map<String, dynamic>.from(o),
    ]);
  } catch (_) {
    return null;
  }
}
