import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

String _uiLang(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

/// Full weekday date following the UI locale.
/// Arabic keeps its native comma pattern; English uses the ASCII one.
String localizedWeekdayDate(BuildContext context, DateTime date) {
  final loc = _uiLang(context);
  final pattern = loc == 'ar' ? 'EEEE، dd MMMM yyyy' : 'EEEE, dd MMMM yyyy';
  return DateFormat(pattern, loc).format(date);
}

/// Short day-month-year label following the UI locale.
String localizedShortDate(BuildContext context, DateTime date) {
  return DateFormat('dd MMM yyyy', _uiLang(context)).format(date);
}

/// Grouped integer format following the UI locale.
String localizedGroupedNumber(BuildContext context, num value) {
  return NumberFormat('#,##0', _uiLang(context)).format(value);
}
