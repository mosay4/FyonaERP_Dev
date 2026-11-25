import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/localization/app_localizations.dart';
import 'personal_ledger.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Reminder stores that hold Personal data (Stage 6 of
// docs/PERSONAL_LOCAL_PLAN.md): debt reminders (the whole debt: person,
// amount), recurring-bill reminders and Sara's scheduled notices (texts with
// amounts).
//
// The full store lives in the encrypted Personal ledger (key/value table,
// key `reminders:<store key>`, never sent to other devices). SharedPreferences
// keeps, under the old key, only what the Android boot receiver needs to
// re-arm the alarms after a reboot while the app is closed: instant, request
// code, kind, id, route and a generic text — no name, no amount. A plain
// store written by an older build is moved the copy → verify → wipe way:
// copied into the ledger, read back and compared, then the plain entry is
// replaced by its redacted form.
//
// Without an open ledger (no signed-in user yet) the plain store is used as
// before, and moved the next time the ledger is open.
// ─────────────────────────────────────────────────────────────────────────────

abstract final class PersonalReminderStore {
  static const debt = 'debt_reminders_v2';
  static const recurring = 'recurring_reminders_v2';
  static const sara = 'sara_smart_reminders_v1';
  static const keys = {debt, recurring, sara};

  /// Marks an entry of the plain store as the redacted boot copy.
  static const redactedMark = '_r';

  static String ledgerKey(String key) => 'reminders:$key';

  /// Generic notification texts for alarms re-armed after a reboot, in the
  /// app's language.
  static String _text(String key, String fallback) {
    final t = AppLocalizations.t(key);
    return t == key ? fallback : t;
  }

  static String get genericTitle => _text('reminderBootTitle', 'FYONA');
  static String get genericBody =>
      _text('reminderBootBody', 'لديك تذكير — افتح التطبيق لعرض التفاصيل.');

  static Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final v = jsonDecode(raw);
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    return {};
  }

  static bool _isRedacted(Object? entry) =>
      entry is Map && entry[redactedMark] == 1;

  /// The boot copy of one entry: when and how to fire, nothing else.
  @visibleForTesting
  static Map<String, dynamic> redactEntry(String store, String key, Map entry) {
    final out = <String, dynamic>{
      redactedMark: 1,
      for (final f in const ['millis', 'requestCode', 'kind', 'refId', 'route'])
        if (entry[f] != null) f: entry[f],
      'title': genericTitle,
      'body': genericBody,
    };
    if (store == debt) {
      final d = entry['debt'];
      // The boot receiver needs the debt id (and kind of debt) only.
      out['debt'] = {
        if (d is Map && d['id'] != null) 'id': d['id'],
        if (d is Map && d['debt_type'] != null) 'debt_type': d['debt_type'],
      };
    }
    return out;
  }

  static String redact(String store, Map<String, dynamic> all) => jsonEncode({
        for (final e in all.entries)
          if (e.value is Map) e.key: redactEntry(store, e.key, e.value as Map),
      });

  /// The full store (JSON object), moving a plain store into the ledger.
  static Future<String?> read(String store) async {
    final prefs = await SharedPreferences.getInstance();
    final plain = prefs.getString(store);
    try {
      return await _adopt(store, prefs, plain);
    } catch (e) {
      debugPrint('PersonalReminderStore: ledger unavailable ($e)');
      return plain;
    }
  }

  /// Writes the full store to the ledger and its boot copy to preferences.
  static Future<void> write(String store, String json) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await PersonalLedgerKv.setString(ledgerKey(store), json);
    } catch (e) {
      // No ledger yet: kept as before; moved when the ledger is open.
      debugPrint('PersonalReminderStore: ledger unavailable ($e)');
      await prefs.setString(store, json);
      return;
    }
    await prefs.setString(store, redact(store, _decode(json)));
  }

  static Future<void> remove(String store) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await PersonalLedgerKv.remove(ledgerKey(store));
    } catch (_) {}
    await prefs.remove(store);
  }

  /// Copy → verify → wipe of entries an older build (or the no-ledger
  /// fallback) wrote in plain. Returns the full store.
  static Future<String?> _adopt(
    String store,
    SharedPreferences prefs,
    String? plain,
  ) async {
    final inLedger = await PersonalLedgerKv.getString(ledgerKey(store));
    final plainAll = _decode(plain);
    final legacy = {
      for (final e in plainAll.entries)
        if (e.value is Map && !_isRedacted(e.value)) e.key: e.value,
    };
    if (legacy.isEmpty) return inLedger;
    // Copy: the ledger's entries win; plain-only entries are added.
    final merged = {...legacy, ..._decode(inLedger)};
    final json = jsonEncode(merged);
    await PersonalLedgerKv.setString(ledgerKey(store), json);
    // Verify.
    final back = await PersonalLedgerKv.getString(ledgerKey(store));
    if (back != json) {
      throw StateError('reminder store verify failed');
    }
    // Wipe: only the boot copy stays in plain preferences.
    await prefs.setString(store, redact(store, merged));
    return json;
  }
}
