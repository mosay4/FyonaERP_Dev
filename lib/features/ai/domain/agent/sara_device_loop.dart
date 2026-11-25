import 'dart:async';
import 'dart:convert';

import '../services/ai_service.dart' show AiAgentResponse;

/// Answers one device call ({id, method, path, params}) from this phone.
typedef SaraDeviceCall =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> call);

/// Sends the phone's answers back to the server (/business-sara/continue,
/// /ai/continue for Personal).
typedef SaraDeviceResume =
    Future<AiAgentResponse> Function(
      Map<String, dynamic> state,
      List<Map<String, dynamic>> results,
    );

/// Sara's device read loop, shared by Business (device-ledger branch and
/// «جميع الفروع») and Personal (the Personal ledger lives only on the
/// phone): the server pauses with `device_calls`, the phone answers them
/// from its own ledger, the server continues — until Sara has a reply.
///
/// Guarantees that Sara always ends with a message:
/// * every device read has its own deadline (a slow or stuck read is
///   answered as an honest "could not read" instead of waiting);
/// * the whole conversation has a time budget and a round cap;
/// * an answer the server would refuse as too large is trimmed here with
///   an honest coverage note, so Sara reads a useful part in one round
///   instead of retrying round after round.
abstract final class SaraDeviceLoop {
  static const maxRounds = 12;
  static const callTimeout = Duration(seconds: 25);
  static const budget = Duration(seconds: 200);

  /// The server refuses a tool result above 40,000 characters.
  static const resultLimit = 30000;

  /// Runs the loop. Returns null when [alive] turns false (page closed or
  /// branch changed): the caller then shows nothing.
  static Future<AiAgentResponse?> run(
    AiAgentResponse first, {
    required SaraDeviceCall handle,
    required SaraDeviceResume resume,
    bool Function()? alive,
    void Function(int round)? onRound,
    bool arabic = true,
    Duration perCall = callTimeout,
    Duration total = budget,
    Stopwatch? clock,
    String Function(bool arabic)? unfinishedText,
    String Function(bool arabic)? timeoutText,
  }) async {
    final watch = clock ?? (Stopwatch()..start());
    var response = first;
    for (var round = 0;
        response.deviceCalls.isNotEmpty && response.state != null;
        round++) {
      if (alive?.call() == false) return null;
      if (round >= maxRounds || watch.elapsed >= total) {
        return _unfinished(response, arabic, unfinishedText);
      }
      onRound?.call(round);
      final results = <Map<String, dynamic>>[];
      for (final call in response.deviceCalls) {
        final left = total - watch.elapsed;
        final limit = left < perCall ? (left.isNegative ? Duration.zero : left) : perCall;
        results.add({
          'id': call['id'],
          'result': compact(await _answer(handle, call, limit, arabic, timeoutText)),
        });
        if (alive?.call() == false) return null;
      }
      if (alive?.call() == false) return null;
      final left = total - watch.elapsed;
      try {
        response = await resume(response.state!, results).timeout(
          left > const Duration(seconds: 20) ? left : const Duration(seconds: 20),
        );
      } on TimeoutException {
        return _unfinished(response, arabic, unfinishedText);
      }
    }
    return response;
  }

  static Future<Map<String, dynamic>> _answer(
    SaraDeviceCall handle,
    Map<String, dynamic> call,
    Duration limit,
    bool arabic,
    String Function(bool arabic)? timeoutText,
  ) async {
    final reason = timeoutText != null ? timeoutText(arabic) : arabic
        ? 'تعذرت قراءة هذه البيانات من الجهاز خلال المهلة. لا تكرري نفس الطلب؛ '
              'أجيبي بما قرأتِه أو اقترحي سؤالًا أضيق (فرع أو فترة أو نوع واحد).'
        : 'This data could not be read on the device in time. Do not repeat the '
              'same request; answer with what you have or suggest a narrower question.';
    try {
      return await handle(call).timeout(limit);
    } on TimeoutException {
      return {'success': false, 'error': reason, 'message': reason, 'coverage': 'timeout'};
    } catch (error) {
      final text = '$error';
      final message = text.isEmpty || text.length > 300
          ? (arabic ? 'رفض التطبيق القراءة.' : 'The app refused the read.')
          : text;
      return {'success': false, 'error': message, 'message': message};
    }
  }

  static AiAgentResponse _unfinished(AiAgentResponse last, bool arabic,
          String Function(bool arabic)? unfinishedText) =>
      AiAgentResponse(
        text: unfinishedText != null ? unfinishedText(arabic) : arabic
            ? 'استغرق جمع البيانات وقتًا أطول من المعتاد فلم أكمل الإجابة. '
                  'جرّب سؤالًا أضيق: فرعًا واحدًا، أو فترة محددة، أو نوعًا واحدًا (البنوك، الفواتير، المخزون…).'
            : 'Collecting the data took longer than usual, so I could not finish. '
                  'Try a narrower question: one branch, a period, or one kind (banks, invoices, stock…).',
        actions: last.actions,
        userQuery: last.userQuery,
      );

  /// Trims a device answer so it fits what the server reads ([limit]
  /// characters of JSON): very long strings (pictures, notes) are dropped,
  /// then the largest lists are halved until the answer fits. Every trimmed
  /// list leaves `<key>_coverage` with what was shown out of the total, so
  /// Sara never presents a partial list as complete.
  static Map<String, dynamic> compact(
    Map<String, dynamic> result, {
    int limit = resultLimit,
  }) {
    String encode(Object? v) {
      try {
        return jsonEncode(v, toEncodable: (o) => '$o');
      } catch (_) {
        return '$v';
      }
    }

    if (encode(result).length <= limit) return result;
    final copy = _strip(result) as Map<String, dynamic>;
    for (var pass = 0; pass < 40 && encode(copy).length > limit; pass++) {
      final target = _largestList(copy, encode);
      if (target == null) break;
      final (parent, key, list) = target;
      final total = (parent['${key}_coverage'] as Map?)?['total'] ?? list.length;
      final keep = list.length <= 1 ? 0 : (list.length / 2).floor();
      parent[key] = list.sublist(0, keep);
      parent['${key}_coverage'] = {
        'shown': keep,
        'total': total,
        'note': 'partial: only the first $keep of $total rows are included. '
            'Say so, or ask with filters (search, branch, period, per_page).',
      };
    }
    if (encode(copy).length > limit) {
      return {
        'success': result['success'],
        'coverage': 'response_too_large',
        'message': 'The answer is too large. Ask with filters (search, period, per_page).',
      };
    }
    return copy;
  }

  static Object? _strip(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries) '${entry.key}': _strip(entry.value),
      };
    }
    if (value is List) return [for (final item in value) _strip(item)];
    if (value is String && value.length > 1200) return '[omitted ${value.length} chars]';
    return value;
  }

  static (Map<String, dynamic>, String, List<dynamic>)? _largestList(
    Map<String, dynamic> root,
    String Function(Object?) encode,
  ) {
    // Lists of several rows are halved first; a single huge row (one
    // document with many lines) has its inner lists trimmed instead.
    (Map<String, dynamic>, String, List<dynamic>)? best, single;
    var bestSize = 0, singleSize = 0;
    void visit(Object? node) {
      if (node is Map<String, dynamic>) {
        for (final entry in node.entries) {
          final value = entry.value;
          if (value is List && value.isNotEmpty) {
            final size = encode(value).length;
            if (value.length > 1 && size > bestSize) {
              bestSize = size;
              best = (node, entry.key, value);
            } else if (value.length == 1 && size > singleSize) {
              singleSize = size;
              single = (node, entry.key, value);
            }
          }
          visit(value);
        }
      } else if (node is List) {
        for (final item in node) {
          visit(item);
        }
      }
    }

    visit(root);
    return best ?? single;
  }
}
