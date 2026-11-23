import 'tool_registry.dart';
import 'sara_display.dart';

/// Handles confirmation flow for sensitive operations.
class ConfirmationHandler {
  ConfirmationHandler._();

  /// Check if a tool requires confirmation before execution.
  static bool requiresConfirmation(ToolDefinition tool) {
    return tool.requiresConfirmation || tool.riskLevel == RiskLevel.critical;
  }

  /// Build confirmation message for a write operation.
  static String buildConfirmationMessage(
    ToolDefinition tool,
    Map<String, dynamic> params, {
    String lang = 'ar',
  }) {
    if (lang == 'ar') {
      return _buildArabicConfirmation(tool, params);
    }
    return _buildEnglishConfirmation(tool, params);
  }

  /// Parse user's confirmation response.
  static ConfirmResult parseConfirmation(String response) {
    final lower = response.toLowerCase().trim();
    // Arabic yes
    if (lower.contains('نعم') || lower.contains('أجل') || lower.contains('تمام') ||
        lower.contains('موافق') || lower.contains('أي') || lower == 'y' || lower == 'yes' || lower == 'ok') {
      return ConfirmResult.confirmed;
    }
    // Arabic no
    if (lower.contains('لا') || lower.contains('لأ') || lower.contains('إلغاء') ||
        lower == 'n' || lower == 'no' || lower == 'cancel') {
      return ConfirmResult.cancelled;
    }
    return ConfirmResult.unknown;
  }

  static String _buildArabicConfirmation(ToolDefinition tool, Map<String, dynamic> params) {
    final lines = <String>[];
    lines.add('⚠️ أنت على وشك تنفيذ عملية حساسة:');
    lines.add('');
    lines.add('📋 ${tool.nameAr}');

    for (final row in saraDetailRows(params, arabic: true)) {
      lines.add('${row.key}\n${row.value}\n');
    }

    if (tool.riskLevel == RiskLevel.critical) {
      lines.add('');
      lines.add('🔴 تحذير: هذه العملية لا يمكن التراجع عنها!');
    }

    lines.add('');
    lines.add('هل أنت متأكد من التنفيذ؟ (نعم / لا)');

    return lines.join('\n');
  }

  static String _buildEnglishConfirmation(ToolDefinition tool, Map<String, dynamic> params) {
    final lines = <String>[];
    lines.add('⚠️ You are about to perform a sensitive operation:');
    lines.add('');
    lines.add('📋 ${tool.descriptionEn}');

    for (final param in tool.params) {
      final value = params[param.name];
      if (value != null) {
        lines.add('• ${param.descriptionEn}: $value');
      }
    }

    if (tool.riskLevel == RiskLevel.critical) {
      lines.add('');
      lines.add('🔴 Warning: This action cannot be undone!');
    }

    lines.add('');
    lines.add('Are you sure you want to proceed? (yes / no)');

    return lines.join('\n');
  }
}

enum ConfirmResult { confirmed, cancelled, unknown }
