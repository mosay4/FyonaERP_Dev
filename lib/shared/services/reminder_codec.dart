// ─────────────────────────────────────────────────────────────
// ReminderCodec — pure helpers shared by debt + recurring reminders.
//
// - FNV-1a 32-bit request codes (stable across launches; Dart's
//   String.hashCode is NOT stable and must never be used).
// - Reminder-store entry builders + pruning (prefs-map pure parts).
// - No Flutter, no plugins: safe to unit-test in isolation.
// ─────────────────────────────────────────────────────────────

/// Stable FNV-1a 32-bit hash of [input], masked to 31 bits so it is a
/// valid non-negative Android request code.
int fnv1a31(String input) {
  var h = 0x811C9DC5;
  for (var i = 0; i < input.length; i++) {
    h ^= input.codeUnitAt(i);
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x7FFFFFFF;
}

class ReminderCodec {
  ReminderCodec._();

  /// Stable id per rule id (mirrors the legacy RecurringReminderService
  /// stableId exactly — same algorithm, same output).
  static int stableId(String id) => fnv1a31(id);

  /// Native alarm request code for a namespaced key:
  /// `'debt:<id>'` or `'recur:<id>'`. NEVER Dart hashCode.
  static int requestCode(String namespacedKey) => fnv1a31(namespacedKey);

  static int debtRequestCode(String debtId) => requestCode('debt:$debtId');

  static int recurringRequestCode(String ruleId) => requestCode('recur:$ruleId');

  /// Deep-link opened when a debt alarm tap is routed.
  static String debtRouteFor(String debtId) => '/personal/debts?debtId=$debtId';

  /// Deep-link opened when a recurring alarm tap is routed.
  static String recurringRouteFor(String ruleId) =>
      '/personal/recurring/detail?id=$ruleId';

  /// Store entry persisted under `debt_reminders_v2['debt_<id>']` or
  /// `recurring_reminders_v2['recur_<id>']`.
  static Map<String, dynamic> buildEntry({
    required int millis,
    required String title,
    required String body,
    required String kind,
    required String refId,
    required int requestCode,
    required String route,
    Map<String, dynamic>? extra,
  }) {
    return <String, dynamic>{
      'millis': millis,
      'title': title,
      'body': body,
      'kind': kind,
      'refId': refId,
      'requestCode': requestCode,
      'route': route,
      ...?extra,
    };
  }

  /// Keys of entries that must be dropped (missing or past fire instant).
  static List<String> prunePastKeys(
      Map<String, Map<String, dynamic>> all, int nowMillis) {
    final out = <String>[];
    for (final e in all.entries) {
      final millis = (e.value['millis'] as num?)?.toInt() ?? 0;
      if (millis <= 0 || millis < nowMillis) out.add(e.key);
    }
    return out;
  }

  /// Keys of entries due at [nowMillis] (fire instant passed).
  static List<String> dueKeys(
      Map<String, Map<String, dynamic>> all, int nowMillis) {
    final out = <String>[];
    for (final e in all.entries) {
      final millis = (e.value['millis'] as num?)?.toInt() ?? 0;
      if (millis > 0 && millis <= nowMillis) out.add(e.key);
    }
    return out;
  }
}
