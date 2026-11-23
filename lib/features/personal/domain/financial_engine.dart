import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../data/models/financial_tree_models.dart';

/// تصنيف مالي لكل نوع عقدة؛ أساس كل حسابات المحرك.
enum FinancialNodeCategory {
  /// أصل: يزيد صافي الثروة ويستهلك نقدًا عند الشراء.
  asset,

  /// استثمار: يزيد صافي الثروة ويستهلك نقدًا.
  investment,

  /// مدخرات: تزيد صافي الثروة وتستهلك نقدًا.
  saving,

  /// مستحق قبض: يزيد صافي الثروة ولا يستهلك نقدًا الآن.
  receivable,

  /// دخل: تدفق وارد يزيد النقد المتاح.
  income,

  /// مصروف: تدفق صادر يستهلك النقد.
  expense,

  /// دَين/التزام: يستهلك النقد (الأصل) ويقلل الصافي (المتبقي).
  debt,

  /// دفعة صادرة: تستهلك النقد ولا تؤثر على صافي الثروة.
  payment,

  /// تحويل داخلي: لا يؤثر على النقد ولا على الصافي.
  transfer,

  /// جذر/عقدة مخصصة: لا تُحسب ضمن الأبناء.
  neutral,
}

FinancialNodeCategory categoryOf(FinancialTreeNodeType type) {
  switch (type) {
    case FinancialTreeNodeType.asset:
      return FinancialNodeCategory.asset;
    case FinancialTreeNodeType.investment:
      return FinancialNodeCategory.investment;
    case FinancialTreeNodeType.saving:
      return FinancialNodeCategory.saving;
    case FinancialTreeNodeType.receivable:
      return FinancialNodeCategory.receivable;
    case FinancialTreeNodeType.income:
      return FinancialNodeCategory.income;
    case FinancialTreeNodeType.expense:
      return FinancialNodeCategory.expense;
    case FinancialTreeNodeType.debt:
    case FinancialTreeNodeType.liability:
      return FinancialNodeCategory.debt;
    case FinancialTreeNodeType.payment:
      return FinancialNodeCategory.payment;
    case FinancialTreeNodeType.transfer:
      return FinancialNodeCategory.transfer;
    case FinancialTreeNodeType.root:
    case FinancialTreeNodeType.custom:
      return FinancialNodeCategory.neutral;
  }
}

/// هل تستهلك العقدة نقدًا متاحًا (تُخصم من قاعدة النقد)؟
bool consumesCash(FinancialNodeCategory category) {
  switch (category) {
    case FinancialNodeCategory.asset:
    case FinancialNodeCategory.investment:
    case FinancialNodeCategory.saving:
    case FinancialNodeCategory.expense:
    case FinancialNodeCategory.debt:
    case FinancialNodeCategory.payment:
      return true;
    default:
      return false;
  }
}

/// فئات التدفق النقدي الصادر (أقساط/دفعات مدفوعة على خصوم ومصروفات).
bool isDebitCategory(FinancialNodeCategory category) =>
    category == FinancialNodeCategory.expense ||
    category == FinancialNodeCategory.debt ||
    category == FinancialNodeCategory.payment;

class TreeValidationIssue {
  final FinancialTreeNode? node;
  final String message;
  const TreeValidationIssue({this.node, required this.message});
}

/// محرك مالي خالص قابل للاختبار (بدون Flutter/Riverpod).
class FinancialEngine {
  const FinancialEngine();

  /// يحسب مؤشرات الشجرة بأرقام صحيحة دون مضاعفة:
  /// `netWorth = freeCash + assets + investments + savings + receivable − payable`
  /// حيث `freeCash = base + income − allocated`.
  static TreeComputation computeTree({
    required FinancialTree tree,
    required List<FinancialTreeNode> nodes,
    required double Function(String from, String to, double amount) convert,
  }) {
    final roots = nodes.where((n) => n.isRoot).toList();
    final root = roots.isNotEmpty ? roots.first : null;
    final baseBalance =
        root != null ? convert(root.currency, tree.currency, root.amount) : tree.baseAmount;

    final warnings = <String>[];
    if (roots.length > 1) warnings.add(AppLocalizations.t('finEngMultipleRoots'));
    if (roots.isEmpty) warnings.add(AppLocalizations.t('finEngNoRoot'));
    if (nodes.isEmpty) warnings.add(AppLocalizations.t('finEngEmptyTree'));

    double allocated = 0;
    double totalAssets = 0;
    double totalInvestments = 0;
    double totalSavings = 0;
    double totalIncome = 0;
    double totalExpenses = 0;
    double totalReceivable = 0;
    double totalPayable = 0;
    double totalPaid = 0;
    double totalRemaining = 0;
    double cashIn = 0;
    double cashOut = 0;
    final distribution = <String, double>{};

    final byId = {for (final n in nodes) n.id: n};

    for (final n in nodes) {
      if (n.isRoot) continue;
      final category = categoryOf(n.type);
      final amount = convert(n.currency, tree.currency, n.amount);
      final paid = convert(n.currency, tree.currency, n.paidAmount);
      final remaining = convert(n.currency, tree.currency, n.remainingAmount);

      totalPaid += paid;
      totalRemaining += remaining;

      if (consumesCash(category)) {
        allocated += amount;
        distribution[n.type.id] = (distribution[n.type.id] ?? 0) + amount;
      }

      switch (category) {
        case FinancialNodeCategory.asset:
          totalAssets += amount;
          break;
        case FinancialNodeCategory.investment:
          totalInvestments += amount;
          break;
        case FinancialNodeCategory.saving:
          totalSavings += amount;
          break;
        case FinancialNodeCategory.income:
          totalIncome += amount;
          cashIn += amount;
          break;
        case FinancialNodeCategory.expense:
          totalExpenses += amount;
          break;
        case FinancialNodeCategory.receivable:
          totalReceivable += remaining;
          cashIn += paid;
          break;
        case FinancialNodeCategory.debt:
          totalPayable += remaining;
          break;
        case FinancialNodeCategory.payment:
        case FinancialNodeCategory.transfer:
        case FinancialNodeCategory.neutral:
          break;
      }

      if (isDebitCategory(category)) {
        cashOut += category == FinancialNodeCategory.payment ? amount : paid;
      }
      if (n.parentId != null && !byId.containsKey(n.parentId)) {
        warnings.add(AppLocalizations.t('finEngOrphanNode', {'name': n.name}));
      }
      if (n.amount < 0) {
        warnings.add(AppLocalizations.t('finEngNegativeAmount', {'name': n.name}));
      }
      if (paid > amount + 0.0001) {
        warnings.add(AppLocalizations.t('finEngOverPayment', {'name': n.name}));
      }
    }

    final freeCash = baseBalance + totalIncome - allocated;
    final overAllocated = freeCash < 0;
    if (overAllocated) {
      warnings.add(AppLocalizations.t('finEngOverAllocated'));
    }

    for (final n in nodes) {
      if (n.isRoot) continue;
      final children = nodes.where((c) => c.parentId == n.id);
      final childSum =
          children.fold<double>(0, (sum, c) => sum + convert(c.currency, tree.currency, c.amount));
      if (children.isNotEmpty && childSum > n.amount + 0.0001) {
        warnings.add(AppLocalizations.t('finEngChildrenExceed', {'name': n.name}));
      }
    }

    final netWorth =
        freeCash + totalAssets + totalInvestments + totalSavings + totalReceivable - totalPayable;

    return TreeComputation(
      baseBalance: baseBalance,
      allocated: allocated,
      available: freeCash < 0 ? 0 : freeCash,
      totalAssets: totalAssets,
      totalIncome: totalIncome,
      totalExpenses: totalExpenses,
      totalInvestments: totalInvestments,
      totalSavings: totalSavings,
      totalReceivable: totalReceivable,
      totalPayable: totalPayable,
      netWorth: netWorth,
      totalPaid: totalPaid,
      totalRemaining: totalRemaining,
      distribution: distribution,
      overAllocated: overAllocated,
      cashIn: cashIn,
      cashOut: cashOut,
      warnings: warnings,
      computedAt: DateTime.now(),
    );
  }

  /// تحقق من سلامة الشجرة ويعيد قائمة مشاكل قابلة للعرض.
  static List<TreeValidationIssue> validateTree({
    required FinancialTree tree,
    required List<FinancialTreeNode> nodes,
    required double Function(String from, String to, double amount) convert,
  }) {
    final issues = <TreeValidationIssue>[];
    final roots = nodes.where((n) => n.isRoot).toList();
    if (roots.length > 1) {
      issues.add(TreeValidationIssue(message: AppLocalizations.t('finEngValidateMultipleRoots')));
    }
    if (roots.isEmpty) {
      issues.add(TreeValidationIssue(message: AppLocalizations.t('finEngValidateNoRoot')));
    }
    final byId = {for (final n in nodes) n.id: n};
    for (final n in nodes) {
      if (n.parentId != null && !byId.containsKey(n.parentId)) {
        issues.add(TreeValidationIssue(node: n, message: AppLocalizations.t('finEngValidateOrphan', {'name': n.name})));
      }
      if (n.amount < 0) {
        issues.add(TreeValidationIssue(node: n, message: AppLocalizations.t('finEngValidateNegative', {'name': n.name})));
      }
      final amount = convert(n.currency, tree.currency, n.amount);
      final paid = convert(n.currency, tree.currency, n.paidAmount);
      if (paid > amount + 0.0001) {
        issues.add(TreeValidationIssue(node: n, message: AppLocalizations.t('finEngValidateOverPaid', {'name': n.name})));
      }
    }
    for (final n in nodes) {
      if (n.isRoot) continue;
      final children = nodes.where((c) => c.parentId == n.id);
      final childSum =
          children.fold<double>(0, (s, c) => s + convert(c.currency, tree.currency, c.amount));
      if (children.isNotEmpty && childSum > n.amount + 0.0001) {
        issues.add(TreeValidationIssue(node: n, message: AppLocalizations.t('finEngValidateChildrenExceed', {'name': n.name})));
      }
    }
    return issues;
  }
}
