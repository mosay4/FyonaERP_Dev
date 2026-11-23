import 'tool_registry.dart';

/// Normalizes and validates tool parameters before execution.
///
/// Handles:
/// - String → int/double conversion
/// - Amount cleaning (remove commas, currency symbols)
/// - Currency normalization
/// - Date parsing
/// - ID validation
/// - Null safety
/// - Type coercion for all parameters
class ParamNormalizer {
  ParamNormalizer._();

  static const _arabicIndicDigits = '٠١٢٣٤٥٦٧٨٩';
  static const _persianDigits = '۰۱۲۳۴۵۶۷۸۹';

  /// Converts Arabic-Indic (٠-٩), Persian (۰-۹) digits and Arabic separators
  /// (٫ decimal, ٬ thousands) to their ASCII equivalents so amounts dictated
  /// in Arabic ("خمسة آلاف" aside, "٥٠٠٠" / "٥٬٠٠٠" / "٥٫٥") parse correctly.
  static String normalizeDigits(String input) {
    final sb = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      final arIdx = _arabicIndicDigits.indexOf(ch);
      if (arIdx >= 0) {
        sb.write(arIdx);
        continue;
      }
      final faIdx = _persianDigits.indexOf(ch);
      if (faIdx >= 0) {
        sb.write(faIdx);
        continue;
      }
      if (ch == '٫') {
        sb.write('.');
        continue;
      }
      if (ch == '٬' || ch == '،') continue; // thousand separators / Arabic comma
      sb.write(ch);
    }
    return sb.toString();
  }

  /// Extract the first number from free text (Arabic + ASCII digits).
  /// Handles "5 آلاف" → 5000 and word numbers like "خمسة آلاف" → 5000.
  static double? extractFirstNumber(String text) {
    final normalized = normalizeDigits(text);
    // First, check for digit + آلاف/ألف pattern (e.g., "5 آلاف" → 5000)
    final digitWithThousands = RegExp(r'(\d+)\s*(?:آلاف|الاف|ألف|الف)').firstMatch(normalized.toLowerCase());
    if (digitWithThousands != null) {
      final d = double.tryParse(digitWithThousands.group(1)!);
      if (d != null) return d * 1000;
    }
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(normalized);
    if (match == null) {
      return extractWordNumber(text);
    }
    // If the matched number is followed by آلاف/مليون, adjust
    final after = normalized.substring(match.end).toLowerCase();
    final base = double.tryParse(match.group(1)!);
    if (base != null) {
      if (after.trim().startsWith('آلاف') || after.trim().startsWith('الاف') || after.trim().startsWith('ألف') || after.trim().startsWith('الف')) {
        return base * 1000;
      }
      if (after.trim().startsWith('مليون')) return base * 1000000;
      if (after.trim().startsWith('مليار')) return base * 1000000000;
    }
    return base;
  }

  /// Extract number written in Arabic words (e.g., "خمسة آلاف" → 5000).
  /// Only simple, safe forms are handled; complex compounds return null
  /// so Sara asks for clarification instead of guessing.
  static double? extractWordNumber(String text) {
    final lower = normalizeDigits(text).toLowerCase().replaceAll('ـ', '').trim();
    if (lower == 'مليون ونصف' || lower == 'مليون ونص') return 1500000;
    if (lower.contains('و')) {
      // Any compound with "و" is considered ambiguous for now → ask
      // (except the exact "مليون ونصف" above)
      return null;
    }
    final single = _wordPartToNumber(lower);
    if (single != null) return single;
    // Handle "5 آلاف" where 5 is digit + آلاف (already handled above, but keep)
    final digitMatch = RegExp(r'(\d+)\s*(?:آلاف|الاف|ألف|الف)').firstMatch(lower);
    if (digitMatch != null) {
      final d = double.tryParse(digitMatch.group(1)!);
      if (d != null) return d * 1000;
    }
    return null;
  }

  static double? _wordPartToNumber(String part) {
    final lower = part.trim().toLowerCase();
    const units = {
      'صفر': 0, 'واحد': 1, 'واحدة': 1, 'اثنان': 2, 'اثنين': 2, 'ثلاثة': 3, 'ثلاث': 3,
      'اربعة': 4, 'أربعة': 4, 'خمسة': 5, 'خمس': 5, 'ستة': 6, 'ست': 6, 'سبعة': 7, 'سبع': 7,
      'ثمانية': 8, 'ثمان': 8, 'تسعة': 9, 'تسع': 9, 'عشرة': 10, 'عشر': 10,
      'عشرون': 20, 'ثلاثون': 30, 'اربعون': 40, 'أربعون': 40, 'خمسون': 50, 'ستون': 60, 'سبعون': 70, 'ثمانون': 80, 'تسعون': 90,
      'مائة': 100, 'مئة': 100, 'مئتان': 200, 'مئتين': 200, 'ثلاثمائة': 300, 'ثلاث مائة': 300,
      'اربعمائة': 400, 'أربعمائة': 400, 'خمسمائة': 500, 'خمسمئة': 500, 'ستمائة': 600, 'سبعمائة': 700, 'ثمانمائة': 800, 'تسعمائة': 900,
      'الف': 1000, 'ألف': 1000, 'آلاف': 1000, 'الاف': 1000, 'ألفان': 2000, 'الفان': 2000, 'ألفين': 2000, 'الفين': 2000,
      'مليون': 1000000, 'ملايين': 1000000, 'مليار': 1000000000,
      'مليونان': 2000000, 'مليونين': 2000000, 'مليارين': 2000000000,
    };
    final sorted = units.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final entry in sorted) {
      if (lower == entry.key || lower.contains(entry.key)) {
        final val = entry.value;
        if (val >= 1000) return val.toDouble();
        if (lower.contains('آلاف') || lower.contains('الاف') || lower.contains('ألف') || lower.contains('الف')) {
          if (val < 1000) return val * 1000;
        }
        if (lower.contains('مليون')) {
          if (val < 1000000) return val * 1000000;
          return val.toDouble();
        }
        return val.toDouble();
      }
    }
    for (final entry in units.entries) {
      if (entry.value < 1000 && lower.contains(entry.key) && (lower.contains('آلاف') || lower.contains('ألف'))) {
        return entry.value * 1000;
      }
    }
    return null;
  }

  /// Normalize all parameters for a tool according to its schema.
  static Map<String, dynamic> normalize(
    ToolDefinition tool,
    Map<String, dynamic> raw,
  ) {
    final normalized = <String, dynamic>{};

    for (final schema in tool.params) {
      final rawValue = raw[schema.name];
      normalized[schema.name] = _normalizeParam(schema, rawValue);
    }

    return normalized;
  }

  /// Normalize a single parameter value.
  static dynamic _normalizeParam(ParamSchema schema, dynamic value) {
    if (value == null) {
      return schema.defaultValue;
    }

    switch (schema.type) {
      case ParamType.number:
        return _normalizeNumber(schema, value);
      case ParamType.string:
        return _normalizeString(schema, value);
      case ParamType.date:
        return _normalizeDate(value);
      case ParamType.enum_:
        return _normalizeEnum(schema, value);
      case ParamType.bool:
        return _normalizeBool(value);
    }
  }

  /// Normalize a number parameter.
  static dynamic _normalizeNumber(ParamSchema schema, dynamic value) {
    double? parsed;

    if (value is num) {
      parsed = value.toDouble();
    } else if (value is String) {
      String cleaned = normalizeDigits(value)
          .replaceAll(RegExp(r'[,\s]'), '')
          .replaceAll(RegExp(r'[^\d.\-]'), '');
      parsed = double.tryParse(cleaned);
    }

    if (parsed == null) return schema.defaultValue;

    if (schema.min != null && parsed < schema.min!) {
      parsed = schema.min!;
    }
    if (schema.max != null && parsed > schema.max!) {
      parsed = schema.max!;
    }

    if (parsed == parsed.roundToDouble()) {
      return parsed.toInt();
    }
    return parsed;
  }

  /// Normalize a string parameter.
  static String _normalizeString(ParamSchema schema, dynamic value) {
    String str = value.toString().trim();

    // Apply max length
    if (schema.maxLength != null && str.length > schema.maxLength!) {
      str = str.substring(0, schema.maxLength);
    }

    // Apply pattern if specified
    if (schema.pattern != null) {
      final regex = RegExp(schema.pattern!);
      if (!regex.hasMatch(str)) {
        return schema.defaultValue?.toString() ?? '';
      }
    }

    return str;
  }

  /// Normalize a date parameter.
  /// Accepts: ISO 8601, YYYY-MM-DD, DD/MM/YYYY, DD-MM-YYYY
  static String? _normalizeDate(dynamic value) {
    if (value == null) return null;

    String str = value.toString().trim();
    if (str.isEmpty) return null;

    // Already ISO format
    final dt = DateTime.tryParse(str);
    if (dt != null) return dt.toIso8601String();

    // DD/MM/YYYY or DD-MM-YYYY
    final match = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(str);
    if (match != null) {
      final day = int.tryParse(match.group(1)!) ?? 1;
      final month = int.tryParse(match.group(2)!) ?? 1;
      final year = int.tryParse(match.group(3)!) ?? DateTime.now().year;
      try {
        final date = DateTime(year, month, day);
        return date.toIso8601String();
      } catch (_) {}
    }

    // YYYY/MM/DD
    final match2 = RegExp(r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$').firstMatch(str);
    if (match2 != null) {
      final year = int.tryParse(match2.group(1)!) ?? DateTime.now().year;
      final month = int.tryParse(match2.group(2)!) ?? 1;
      final day = int.tryParse(match2.group(3)!) ?? 1;
      try {
        final date = DateTime(year, month, day);
        return date.toIso8601String();
      } catch (_) {}
    }

    return null;
  }

  /// Normalize an enum parameter.
  static String _normalizeEnum(ParamSchema schema, dynamic value) {
    final str = value.toString().trim().toLowerCase();
    if (schema.allowedValues != null) {
      // Exact match
      if (schema.allowedValues!.contains(str)) return str;
      // Partial match (contains)
      for (final allowed in schema.allowedValues!) {
        if (str.contains(allowed.toLowerCase()) || allowed.toLowerCase().contains(str)) {
          return allowed;
        }
      }
    }
    return str;
  }

  /// Normalize a boolean parameter.
  static bool _normalizeBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final str = value.toString().toLowerCase();
    return str == 'true' || str == 'yes' || str == '1' || str == 'نعم';
  }

  /// Validate that all required params are present and valid.
  static List<String> validate(ToolDefinition tool, Map<String, dynamic> params) {
    final errors = <String>[];

    for (final schema in tool.params) {
      if (!schema.required) continue;

      final value = params[schema.name];
      if (value == null || (value is String && value.isEmpty)) {
        errors.add('Missing required parameter: ${schema.name}');
        continue;
      }

      if (schema.type == ParamType.number) {
        if (value is! num) {
          errors.add('Parameter ${schema.name} must be a number, got ${value.runtimeType}');
        } else if (schema.min != null && value < schema.min!) {
          errors.add('Parameter ${schema.name} must be >= ${schema.min}');
        } else if (schema.max != null && value > schema.max!) {
          errors.add('Parameter ${schema.name} must be <= ${schema.max}');
        }
      }

      if (schema.type == ParamType.enum_ && schema.allowedValues != null) {
        if (!schema.allowedValues!.contains(value.toString())) {
          errors.add('Parameter ${schema.name} must be one of: ${schema.allowedValues!.join(", ")}');
        }
      }
    }

    return errors;
  }
}
