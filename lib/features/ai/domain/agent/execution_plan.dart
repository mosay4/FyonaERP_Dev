import 'tool_executor.dart';

/// Represents a single step in a multi-step execution plan.
class ExecutionStep {
  final int index;
  final String toolName;
  final Map<String, dynamic> params;
  final String descriptionAr;
  final String descriptionEn;
  bool executed;
  ToolExecutionResult? result;

  ExecutionStep({
    required this.index,
    required this.toolName,
    required this.params,
    required this.descriptionAr,
    required this.descriptionEn,
    this.executed = false,
    this.result,
  });

  bool get canExecute => !executed;
  bool get succeeded => result?.success == true;
}

/// Multi-step execution plan for complex operations.
///
/// Example: Create bank account → Add currencies → Verify → Refresh UI
/// Each step is validated before the next one executes.
/// Idempotent: re-running skips already-executed steps.
class ExecutionPlan {
  final List<ExecutionStep> steps;

  ExecutionPlan({required this.steps});

  /// Get current step that needs execution.
  ExecutionStep? get currentStep {
    for (final step in steps) {
      if (step.canExecute) return step;
    }
    return null;
  }

  /// Get progress (0.0 to 1.0).
  double get progress {
    if (steps.isEmpty) return 1.0;
    final executedCount = steps.where((s) => s.executed).length;
    return executedCount / steps.length;
  }

  /// Check if plan is complete.
  bool get isComplete => steps.every((s) => s.executed);

  /// Check if all executed steps succeeded.
  bool get allSucceeded => steps.where((s) => s.executed).every((s) => s.succeeded);

  /// Get summary of results.
  String summary({String lang = 'ar'}) {
    final lines = <String>[];
    for (final step in steps) {
      final status = step.executed
          ? (step.succeeded ? '✅' : '❌')
          : '⏳';
      final desc = lang == 'ar' ? step.descriptionAr : step.descriptionEn;
      lines.add('$status ${step.index + 1}/$steps.length: $desc');
    }
    return lines.join('\n');
  }

  /// Mark current step as executed with result.
  void completeCurrentStep(ToolExecutionResult result) {
    final step = currentStep;
    if (step != null) {
      step.executed = true;
      step.result = result;
    }
  }

  /// Skip current step (mark as executed with null result).
  void skipCurrentStep() {
    final step = currentStep;
    if (step != null) {
      step.executed = true;
    }
  }

  /// Reset all steps for re-execution.
  void reset() {
    for (final step in steps) {
      step.executed = false;
      step.result = null;
    }
  }
}

/// Factory for building common execution plans.
class ExecutionPlanFactory {
  ExecutionPlanFactory._();

  /// Plan: Create entity with verification.
  static ExecutionPlan createWithVerification({
    required String toolName,
    required Map<String, dynamic> params,
    required String verifyTool,
    required Map<String, dynamic> verifyParams,
    required String entityName,
    required String entityType,
  }) {
    return ExecutionPlan(steps: [
      ExecutionStep(
        index: 0,
        toolName: toolName,
        params: params,
        descriptionAr: 'إنشاء $entityName',
        descriptionEn: 'Create $entityName',
      ),
      ExecutionStep(
        index: 1,
        toolName: verifyTool,
        params: verifyParams,
        descriptionAr: 'التحقق من إنشاء $entityName',
        descriptionEn: 'Verify $entityName creation',
      ),
    ]);
  }

  /// Plan: Update entity with verification.
  static ExecutionPlan updateWithVerification({
    required String toolName,
    required Map<String, dynamic> params,
    required String verifyTool,
    required Map<String, dynamic> verifyParams,
    required String entityName,
  }) {
    return ExecutionPlan(steps: [
      ExecutionStep(
        index: 0,
        toolName: toolName,
        params: params,
        descriptionAr: 'تحديث $entityName',
        descriptionEn: 'Update $entityName',
      ),
      ExecutionStep(
        index: 1,
        toolName: verifyTool,
        params: verifyParams,
        descriptionAr: 'التحقق من تحديث $entityName',
        descriptionEn: 'Verify $entityName update',
      ),
    ]);
  }

  /// Plan: Delete with confirmation verification.
  static ExecutionPlan deleteWithVerification({
    required String toolName,
    required Map<String, dynamic> params,
    required String verifyTool,
    required Map<String, dynamic> verifyParams,
    required String entityName,
  }) {
    return ExecutionPlan(steps: [
      ExecutionStep(
        index: 0,
        toolName: toolName,
        params: params,
        descriptionAr: 'حذف $entityName',
        descriptionEn: 'Delete $entityName',
      ),
      ExecutionStep(
        index: 1,
        toolName: verifyTool,
        params: verifyParams,
        descriptionAr: 'التحقق من حذف $entityName',
        descriptionEn: 'Verify $entityName deletion',
      ),
    ]);
  }

  /// Plan: Create bank account + add exchange rates.
  static ExecutionPlan createBankWithCurrencies({
    required Map<String, dynamic> bankParams,
    required List<Map<String, dynamic>> currencies,
  }) {
    final steps = <ExecutionStep>[
      ExecutionStep(
        index: 0,
        toolName: 'create_bank_account',
        params: bankParams,
        descriptionAr: 'إنشاء الحساب البنكي',
        descriptionEn: 'Create bank account',
      ),
    ];

    for (int i = 0; i < currencies.length; i++) {
      steps.add(ExecutionStep(
        index: i + 1,
        toolName: 'add_exchange_rate',
        params: currencies[i],
        descriptionAr: 'إضافة عملة ${currencies[i]['from_currency'] ?? ''}',
        descriptionEn: 'Add currency ${currencies[i]['from_currency'] ?? ''}',
      ));
    }

    steps.add(ExecutionStep(
      index: steps.length,
      toolName: 'get_bank_accounts',
      params: {},
      descriptionAr: 'التحقق من الحساب والعملات',
      descriptionEn: 'Verify account and currencies',
    ));

    return ExecutionPlan(steps: steps);
  }
}
