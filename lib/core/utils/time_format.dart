import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'currency_formatter.dart' show appLocale;

/// Test seam: forces 12h (false) / 24h (true) when set.
@visibleForTesting
bool? debugUse24HourOverride;

/// Whether DISPLAYED times follow a 24-hour clock — the phone's own setting.
///
/// With a [context] the ambient [MediaQuery.alwaysUse24HourFormat] decides
/// (that is what the platform reports, and what time pickers use); without
/// one the platform dispatcher's value is read directly.
bool use24HourClock([BuildContext? context]) {
  final forced = debugUse24HourOverride;
  if (forced != null) return forced;
  if (context != null) {
    final mq = MediaQuery.maybeAlwaysUse24HourFormatOf(context);
    if (mq != null) return mq;
  }
  try {
    return WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat;
  } catch (_) {
    return false;
  }
}

/// Clock time for DISPLAY only («3:05 م» / «3:05 PM» on a 12-hour phone,
/// «15:05» on a 24-hour phone). Digits stay Latin like every amount in the
/// app. Machine formats (API / ISO / storage keys) must NOT use this.
String formatClock(
  DateTime time, {
  BuildContext? context,
  String? locale,
  bool? use24h,
  bool seconds = false,
}) {
  final h24 = use24h ?? use24HourClock(context);
  String two(int v) => v.toString().padLeft(2, '0');
  // Built by hand (no intl locale data needed — works in PDFs, isolates and
  // before date formatting is initialised).
  final sec = seconds ? ':${two(time.second)}' : '';
  if (h24) return '${two(time.hour)}:${two(time.minute)}$sec';
  final lang = locale ??
      (context != null
          ? (Localizations.maybeLocaleOf(context)?.languageCode ?? appLocale)
          : appLocale);
  final h12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final clock = '$h12:${two(time.minute)}$sec';
  final pm = time.hour >= 12;
  final marker = lang == 'ar' ? (pm ? 'م' : 'ص') : (pm ? 'PM' : 'AM');
  return '$clock $marker';
}

/// [TimeOfDay] variant of [formatClock].
String formatTimeOfDay(
  TimeOfDay t, {
  BuildContext? context,
  String? locale,
  bool? use24h,
}) =>
    formatClock(DateTime(2000, 1, 1, t.hour, t.minute),
        context: context, locale: locale, use24h: use24h);

/// «date clock» for DISPLAY, e.g. `formatDateTimeDisplay(d)` →
/// «2026/11/25 3:05 م». [datePattern] is an intl date-only pattern.
String formatDateTimeDisplay(
  DateTime time, {
  String datePattern = 'yyyy/MM/dd',
  String separator = ' ',
  BuildContext? context,
  String? locale,
  bool? use24h,
}) =>
    '${_safeDate(time, datePattern)}$separator'
    '${formatClock(time, context: context, locale: locale, use24h: use24h)}';

/// Display form of a stored «HH:mm» (or «HH:mm:ss») clock string. Returns
/// the input unchanged when it does not parse.
String formatStoredClock(
  String hhmm, {
  BuildContext? context,
  String? locale,
  bool? use24h,
}) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2})').firstMatch(hhmm);
  if (m == null) return hhmm;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return hhmm;
  return formatClock(DateTime(2000, 1, 1, h, min),
      context: context, locale: locale, use24h: use24h);
}

String _safeDate(DateTime t, String pattern) {
  try {
    return DateFormat(pattern, 'en').format(t);
  } catch (_) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}/${two(t.month)}/${two(t.day)}';
  }
}
