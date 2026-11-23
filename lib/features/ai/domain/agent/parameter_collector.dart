import 'param_normalizer.dart';
import 'tool_registry.dart';

/// Result of parameter collection.
class ParameterCollectionResult {
  final bool isComplete;
  final Map<String, dynamic> collectedParams;
  final List<MissingParamInfo> missingRequired;
  final List<MissingParamInfo> missingOptional;

  const ParameterCollectionResult({
    required this.isComplete,
    required this.collectedParams,
    this.missingRequired = const [],
    this.missingOptional = const [],
  });
}

class MissingParamInfo {
  final ParamSchema schema;
  final String questionAr;
  final String questionEn;

  const MissingParamInfo({
    required this.schema,
    required this.questionAr,
    required this.questionEn,
  });
}

/// Collects parameters for a tool from user input + conversation context.
///
/// Flow:
/// 1. Extract params from user message (via OpenAI or regex)
/// 2. Check what's missing
/// 3. Generate questions for missing required params
/// 4. Return collection result
class ParameterCollector {
  /// Merge extracted params with existing collected params.
  static Map<String, dynamic> mergeParams(
    Map<String, dynamic> existing,
    Map<String, dynamic> newParams,
  ) {
    final merged = Map<String, dynamic>.from(existing);
    for (final entry in newParams.entries) {
      if (entry.value != null && entry.value.toString().isNotEmpty) {
        merged[entry.key] = entry.value;
      }
    }
    return merged;
  }

  /// Check which required params are missing.
  static ParameterCollectionResult checkCompletion(
    ToolDefinition tool,
    Map<String, dynamic> collected,
  ) {
    final missingRequired = <MissingParamInfo>[];
    final missingOptional = <MissingParamInfo>[];

    for (final param in tool.params) {
      final value = collected[param.name];
      if (value == null || value.toString().trim().isEmpty || !_satisfiesMin(param, value)) {
        if (param.required) {
          missingRequired.add(MissingParamInfo(
            schema: param,
            questionAr: _buildQuestionAr(param),
            questionEn: _buildQuestionEn(param),
          ));
        } else if (param.defaultValue == null) {
          missingOptional.add(MissingParamInfo(
            schema: param,
            questionAr: _buildQuestionAr(param),
            questionEn: _buildQuestionEn(param),
          ));
        }
      }
    }

    return ParameterCollectionResult(
      isComplete: missingRequired.isEmpty,
      collectedParams: collected,
      missingRequired: missingRequired,
      missingOptional: missingOptional,
    );
  }

  /// Numeric `min` declared in the schema is enforced here (with Arabic
  /// digit support) so an invalid amount is re-asked instead of executed.
  static bool _satisfiesMin(ParamSchema param, dynamic value) {
    if (param.min == null) return true;
    double? parsed;
    if (value is num) {
      parsed = value.toDouble();
    } else {
      final s = value.toString().trim();
      if (s.isEmpty) return false;
      parsed = ParamNormalizer.extractFirstNumber(s) ?? double.tryParse(s);
    }
    if (parsed == null) return false;
    return parsed >= param.min!;
  }

  /// Generate the next question to ask the user.
  static String? nextQuestion(
    ToolDefinition tool,
    Map<String, dynamic> collected, {
    bool askOptional = false,
    String lang = 'ar',
  }) {
    final result = checkCompletion(tool, collected);
    final useEn = lang == 'en';

    if (result.missingRequired.isNotEmpty) {
      final q = result.missingRequired.first;
      return useEn ? q.questionEn : q.questionAr;
    }

    if (askOptional && result.missingOptional.isNotEmpty) {
      final q = result.missingOptional.first;
      return useEn ? q.questionEn : q.questionAr;
    }

    return null;
  }

  /// Build a summary of what was collected for confirmation.
  static String buildConfirmationSummary(
    ToolDefinition tool,
    Map<String, dynamic> params, {
    String lang = 'ar',
  }) {
    final lines = <String>[];
    for (final param in tool.params) {
      final value = params[param.name];
      if (value != null) {
        final label = lang == 'ar' ? param.descriptionAr : param.descriptionEn;
        lines.add('• $label: $value');
      }
    }
    if (lang == 'ar') {
      return 'ملخص الطلب:\n${tool.nameAr}\n${lines.join('\n')}';
    }
    return 'Request summary:\n${tool.descriptionEn}\n${lines.join('\n')}';
  }

  static String _buildQuestionAr(ParamSchema param) {
    switch (param.name) {
      case 'amount':
        return 'كم المبلغ؟';
      case 'type':
        return 'نوع العملية (دخل / مصروف)؟';
      case 'tx_type':
        return 'نوع المعاملة (دخل / مصروف)؟';
      case 'debt_type':
        return 'نوع الدين (مدين = أنت المدين / دائن = أنت الدائن)؟';
      case 'frequency':
        return 'كرر المعاملة كل (يومي / أسبوعي / شهري / سنوي)؟';
      case 'currency':
      case 'from_currency':
        return 'ما العملة؟';
      case 'category':
        return 'ما التصنيف؟';
      case 'bank_name':
        return 'ما الاسم؟';
      case 'name':
        return 'ما ${param.descriptionAr}؟';
      case 'person_name':
        return 'ما اسم الشخص؟';
      case 'account_id':
      case 'from_account_id':
        return 'من أي حساب بنكي؟';
      case 'to_account_id':
        return 'إلى أي حساب بنكي؟';
      case 'goal_id':
        return 'ما معرف الهدف؟';
      case 'debt_id':
        return 'ما معرف الدين؟';
      case 'budget_id':
        return 'ما معرف الميزانية؟';
      case 'recurring_id':
        return 'ما معرف المعاملة المتكررة؟';
      case 'transaction_id':
        return 'ما معرف المعاملة؟';
      case 'entity_id':
        return 'ما معرف العنصر؟';
      case 'screen':
        return 'أي شاشة تريد فتحها؟';
      case 'entity_type':
        return 'نوع العنصر (بنك / هدف / دين / ميزانية / متكررة)؟';
      case 'date':
        return 'ما التاريخ؟ (YYYY-MM-DD)';
      case 'due_date':
        return 'ما تاريخ الاستحقاق؟';
      case 'deadline':
        return 'ما تاريخ الاستحقاق؟';
      case 'target_amount':
        return 'كم المبلغ المستهدف؟';
      case 'opening_balance':
        return 'كم الرصيد الابتدائي؟';
      case 'balance':
        return 'كم الرصيد الجديد؟';
      case 'notes':
        return 'هل تريد إضافة ملاحظة؟';
      case 'description':
        return 'هل تريد إضافة وصف؟';
      case 'query':
        return 'ما نص البحث؟';
      default:
        return 'ما ${param.descriptionAr}؟';
    }
  }

  static String _buildQuestionEn(ParamSchema param) {
    switch (param.name) {
      case 'amount':
        return 'How much?';
      case 'type':
        return 'Transaction type (income / expense)?';
      case 'tx_type':
        return 'Transaction type (income / expense)?';
      case 'debt_type':
        return 'Debt type (payable / receivable)?';
      case 'frequency':
        return 'Repeat every (daily / weekly / monthly / yearly)?';
      case 'currency':
      case 'from_currency':
        return 'What currency?';
      case 'category':
        return 'What category?';
      case 'bank_name':
        return 'What name?';
      case 'name':
        return 'What is the ${param.descriptionEn}?';
      case 'person_name':
        return 'What is the person\'s name?';
      case 'account_id':
      case 'from_account_id':
        return 'From which bank account?';
      case 'to_account_id':
        return 'To which bank account?';
      case 'goal_id':
        return 'What is the goal ID?';
      case 'debt_id':
        return 'What is the debt ID?';
      case 'budget_id':
        return 'What is the budget ID?';
      case 'recurring_id':
        return 'What is the recurring transaction ID?';
      case 'transaction_id':
        return 'What is the transaction ID?';
      case 'entity_id':
        return 'What is the entity ID?';
      case 'screen':
        return 'Which screen do you want to open?';
      case 'entity_type':
        return 'Entity type (bank / goal / debt / budget / recurring)?';
      case 'date':
        return 'What date? (YYYY-MM-DD)';
      case 'due_date':
        return 'What is the due date?';
      case 'deadline':
        return 'What is the deadline?';
      case 'target_amount':
        return 'What is the target amount?';
      case 'opening_balance':
        return 'What is the opening balance?';
      case 'balance':
        return 'What is the new balance?';
      case 'notes':
        return 'Any notes to add?';
      case 'description':
        return 'Any description to add?';
      case 'query':
        return 'What are you searching for?';
      default:
        return 'What is the ${param.descriptionEn}?';
    }
  }
}
