import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How monetary amounts are formatted app-wide.
class MoneyFormatSettings {
  final bool useThousandsSeparator;
  final bool showDecimals;

  const MoneyFormatSettings({
    this.useThousandsSeparator = true,
    this.showDecimals = true,
  });

  MoneyFormatSettings copyWith({
    bool? useThousandsSeparator,
    bool? showDecimals,
  }) {
    return MoneyFormatSettings(
      useThousandsSeparator: useThousandsSeparator ?? this.useThousandsSeparator,
      showDecimals: showDecimals ?? this.showDecimals,
    );
  }
}

/// Global in-memory settings (defaults) so core formatting helpers can read
/// them synchronously. Updated on every change (and on login/user switch) so
/// the effect is immediate and app-wide for the signed-in user.
MoneyFormatSettings currentMoneyFormat = const MoneyFormatSettings();

/// Bumped whenever the money-format preference changes so the whole app can
/// repaint immediately (never waiting for a section switch).
final ValueNotifier<int> moneyFormatRevision = ValueNotifier<int>(0);

void _applyMoneyFormat(MoneyFormatSettings next) {
  if (currentMoneyFormat.useThousandsSeparator == next.useThousandsSeparator &&
      currentMoneyFormat.showDecimals == next.showDecimals) {
    return;
  }
  currentMoneyFormat = next;
  moneyFormatRevision.value++;
}

/// Which per-user key-prefix to use. Scoped by user id so each account keeps
/// its own money-format preferences.
String _prefix(String userId) {
  final scope = userId.trim().isEmpty ? 'global' : userId;
  return 'money_format_$scope';
}

class MoneyFormatService {
  /// Loads (and caches into [currentMoneyFormat]) the settings for [userId].
  static Future<MoneyFormatSettings> loadAll([String userId = '']) async {
    final prefs = await SharedPreferences.getInstance();
    final p = _prefix(userId);
    final useSep = prefs.getBool('${p}_sep') ?? true;
    final showDec = prefs.getBool('${p}_dec') ?? true;
    final settings = MoneyFormatSettings(
      useThousandsSeparator: useSep,
      showDecimals: showDec,
    );
    _applyMoneyFormat(settings);
    return settings;
  }

  /// Persists the settings for [userId] and applies them immediately to
  /// [currentMoneyFormat].
  static Future<MoneyFormatSettings> save(MoneyFormatSettings settings, [String userId = '']) async {
    final prefs = await SharedPreferences.getInstance();
    final p = _prefix(userId);
    await prefs.setBool('${p}_sep', settings.useThousandsSeparator);
    await prefs.setBool('${p}_dec', settings.showDecimals);
    _applyMoneyFormat(settings);
    return settings;
  }
}
