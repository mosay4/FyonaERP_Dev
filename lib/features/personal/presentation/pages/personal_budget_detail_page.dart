import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../data/models/personal_models.dart';
import '../../di/personal_providers.dart';
import '../../domain/services/budget_aggregation.dart';
import '../providers/personal_providers.dart';
import 'budget_tree_report_pdf.dart';
import '../../../../shared/widgets/dots_loader.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class BudgetDetailPage extends ConsumerStatefulWidget {
  final PersonalBudget budget;
  const BudgetDetailPage({super.key, required this.budget});
  @override
  ConsumerState<BudgetDetailPage> createState() => _BudgetDetailPageState();
}

class _BudgetDetailPageState extends ConsumerState<BudgetDetailPage> {
  late PersonalBudget _budget;
  List<PersonalTransaction> _transactions = [];
  bool _loadingTx = true;
  final ScreenshotController _screenshotController = ScreenshotController();
  CurrencyEngine? _engine;
  double _convertedTotalSpent = 0;
  Map<String, double> _convertedCatSpent = {};
  // Generation guard: overlapping _loadTransactions runs (two provider
  // listeners + SWR phases) must never interleave paints — only the newest
  // run may publish, so the screen can never flicker between values.
  int _txGen = 0;

  // ── Inline "Add Category" form ──
  bool _showAddCategory = false;
  bool _savingCategory = false;
  String? _addCatError;
  double _addCatAmount = 0;
  final _addCatNameCtrl = TextEditingController();
  final _addCatAmountCtrl = TextEditingController();
  final _addCatNameFocus = FocusNode();
  final _addCatAmountFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _budget = widget.budget;
    _loadTransactions();
  }

  @override
  void didUpdateWidget(covariant BudgetDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.budget.id != widget.budget.id) {
      _budget = widget.budget;
      _loadTransactions();
    }
  }

  @override
  void dispose() {
    _addCatNameCtrl.dispose();
    _addCatAmountCtrl.dispose();
    _addCatNameFocus.dispose();
    _addCatAmountFocus.dispose();
    super.dispose();
  }

  double get _allocatedTotal => _budget.categories.fold<double>(0, (s, c) => s + c.allocatedAmount);

  double get _freeCapacity => (_budget.totalAmount - _allocatedTotal).clamp(0.0, double.infinity);

  /// Single source of truth: backend aggregation (IDs + period + dedup).
  /// Membership comes from the server; amounts are converted to the budget
  /// currency with the existing engine. No name matching anywhere.
  Future<void> _loadTransactions() async {
    final gen = ++_txGen;
    // Phase 1 — instant: build the list from the local mirror so the page
    // opens immediately (same local math as the list page). Phase 2 below
    // patches it with the server-computed aggregation truth.
    try {
      final service = ref.read(personalFinanceServiceProvider);
      final eng = ref.read(currencyEngineProvider);
      final all = await service.getTransactions();
      if (gen != _txGen) return;
      // Same membership rule as the provider: budget_id match or a
      // manually-added category of this budget. (Debt/goal links are not
      // counted: that linking was removed — budgets carry only categories.)
      final catIds = _budget.categories.map((c) => c.id).toSet();
      final mine = all
          .where((t) => budgetTxBelongs(
              t: t, budgetId: _budget.id, categoryIds: catIds))
          .toList();
      if (mine.isNotEmpty && mounted) {
        _transactions = mine;
        _convertedTotalSpent = 0;
        _convertedCatSpent = {};
        final byBudgetCat = <String, double>{};
        for (final t in mine) {
          double converted = t.amount;
          if (t.currency != _budget.currency) {
            try {
              final c = eng.convert(t.amount, t.currency, _budget.currency);
              if (c > 0) converted = c;
            } catch (_) {}
          }
          _convertedTotalSpent += converted;
          final bcId = t.budgetCategoryId;
          if (bcId != null && bcId.isNotEmpty) {
            byBudgetCat[bcId] = (byBudgetCat[bcId] ?? 0) + converted;
          }
        }
        // User-added categories always display (even with zero allocation);
        // the summary-only fallback applies solely to category-less budgets.
        final hasCategories = _budget.categories.isNotEmpty;
        if (hasCategories) {
          for (final cat in _budget.categories) {
            _convertedCatSpent[cat.name] = byBudgetCat[cat.id] ?? 0;
          }
        } else {
          _convertedCatSpent[_budget.name] = _convertedTotalSpent;
        }
        if (gen != _txGen || !mounted) return;
        setState(() => _loadingTx = false);
      }
    } catch (_) {}

    // Phase 2 — server truth (existing behavior, unchanged).
    try {
      _engine = ref.read(currencyEngineProvider);
      await _engine!.load();
    } catch (_) {}
    if (gen != _txGen) return;

    try {
      final agg = await ref.read(budgetProvider.notifier).aggregationFor(_budget.id);
      if (gen != _txGen) return;
      if (agg != null) {
        _budget = agg.budget.copyWith(
          totalSpent: _budget.totalSpent,
          categories: _budget.categories.isNotEmpty ? _budget.categories : agg.budget.categories,
        );
        _applyAggregation(agg);
        return;
      }
    } catch (_) {}
    if (gen == _txGen && mounted) setState(() => _loadingTx = false);
  }

  void _applyAggregation(BudgetAggregation agg) {
    // Operations are already filtered by the backend (budget/goal/debt IDs +
    // period + dedup by tx id). Convert each to the budget currency.
    _transactions = agg.operations;

    _convertedTotalSpent = 0;
    _convertedCatSpent = {};

    final byBudgetCat = <String, double>{};
    for (final t in _transactions) {
      double converted = t.amount;
      if (_engine != null && t.currency != _budget.currency) {
        try {
          final c = _engine!.convert(t.amount, t.currency, _budget.currency);
          if (c > 0) converted = c;
        } catch (_) {}
      }
      _convertedTotalSpent += converted;
      final bcId = t.budgetCategoryId;
      if (bcId != null && bcId.isNotEmpty) {
        byBudgetCat[bcId] = (byBudgetCat[bcId] ?? 0) + converted;
      }
    }

    final hasCategories = _budget.categories.isNotEmpty;
    if (hasCategories) {
      for (final cat in _budget.categories) {
        _convertedCatSpent[cat.name] = byBudgetCat[cat.id] ?? 0;
      }
    } else {
      _convertedCatSpent[_budget.name] = _convertedTotalSpent;
    }

    if (mounted) setState(() => _loadingTx = false);
  }

  String _convertTxAmount(double amount, String fromCurrency) {
    if (_engine == null || fromCurrency == _budget.currency) return fmtNum(amount);
    try {
      final converted = _engine!.convert(amount, fromCurrency, _budget.currency);
      if (converted > 0) return fmtNum(converted);
    } catch (_) {}
    return fmtNum(amount);
  }

  Color _colorForCategory(String name, String type) {
    const expenseColors = {
      'طعام': Color(0xFFE65100), 'مواصلات': Color(0xFF1565C0),
      'اتصالات': Color(0xFF0277BD), 'صحة': Color(0xFFC62828),
      'تعليم': Color(0xFF00838F), 'ترفيه': Color(0xFFD81B60),
      'إيجار': Color(0xFF2E7D32), 'فواتير': Color(0xFF6A1B9A),
      'تسوق': Color(0xFFFF8F00), 'أخرى': Color(0xFF37474F),
    };
    const goalColors = {
      'شراء سيارة': Color(0xFF0277BD), 'سفر': Color(0xFF00897B),
      'تعليم': Color(0xFF00838F), 'ادخار طوارئ': Color(0xFF3949AB),
      'شراء جهاز': Color(0xFF6A1B9A), 'زفاف': Color(0xFFC62828),
      'דירה': Color(0xFF2E7D32), 'استثمار': Color(0xFF1B5E20),
      'رحلات عائلية': Color(0xFFD81B60), 'أهداف أخرى': Color(0xFF37474F),
    };
    const debtColors = {
      'ديون': Color(0xFFFFA726), 'قرض': Color(0xFFEF5350),
    };
    if (type == 'goal') return goalColors[name] ?? const Color(0xFF66BB6A);
    if (type == 'debt') return debtColors[name] ?? const Color(0xFFFFA726);
    return expenseColors[name] ?? AppColors.primary;
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'expense': return Icons.receipt_long_rounded;
      case 'debt': return Icons.account_balance_rounded;
      case 'goal': return Icons.savings_rounded;
      default: return Icons.category_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Auto-reload when transactions or budgets change
    ref.listen<PersonalFinanceState>(personalFinanceProvider, (prev, next) {
      final txChanged = !identical(prev?.transactions, next.transactions);
      if (txChanged) {
        _loadTransactions();
      }
    });
    ref.listen<BudgetState>(budgetProvider, (prev, next) {
      final budgetsChanged = !identical(prev?.budgets, next.budgets);
      if (budgetsChanged) {
        _loadTransactions();
      }
    });

    // Group transactions by budget category ID (real relation, no names).
    final txByCat = <String, List<PersonalTransaction>>{};
    final hasCategories = _budget.categories.isNotEmpty;
    if (hasCategories) {
      for (final t in _transactions) {
        final bcId = t.budgetCategoryId;
        if (bcId == null || bcId.isEmpty) continue;
        if (_budget.categories.any((c) => c.id == bcId)) {
          final cat = _budget.categories.firstWhere((c) => c.id == bcId);
          txByCat.putIfAbsent(cat.name, () => []).add(t);
        }
      }
    } else {
      // Budget without categories — group by budget name
      for (final t in _transactions) {
        txByCat.putIfAbsent(_budget.name, () => []).add(t);
      }
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_budget.name, style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: () => context.push(RouteNames.personalBudgetEdit, extra: {'budget': _budget}),
            icon: Icon(Icons.edit_outlined, color: AppColors.primary),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSummaryCard(),
          const SizedBox(height: 12),

          // ── Action Buttons ──
          _buildActionButtons(),
          const SizedBox(height: 16),

          _buildPeriodInfo(),
          const SizedBox(height: 16),

          // ── Add New Category ──
          _buildAddCategorySection(),
          const SizedBox(height: 16),

          if (_budget.categories.isNotEmpty) ...[
            _SectionTitle(title: AppLocalizations.of(context).translate('categories'), count: _budget.categories.length),
            const SizedBox(height: 8),
            ..._budget.categories.map((cat) {
              final catTxs = txByCat[cat.name] ?? [];
              final computedSpent = _convertedCatSpent[cat.name] ?? 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: () => _showCategoryInvoice(context, cat, catTxs),
                  child: _CategoryCard(
                    category: cat,
                    computedSpent: computedSpent,
                    color: _colorForCategory(cat.name, cat.type),
                    icon: _iconForType(cat.type),
                  ),
                ),
              );
            }),
            const SizedBox(height: 16),
          ] else ...[
            _SectionTitle(title: AppLocalizations.of(context).translate('budgetExpenseSummary'), count: _transactions.length),
            const SizedBox(height: 8),
            _buildOverallSpendingCard(),
            const SizedBox(height: 16),
          ],

          if (_budget.bankAccountIds.isNotEmpty) ...[
            _SectionTitle(title: AppLocalizations.of(context).translate('bankAccountsTitle'), count: _budget.bankAccountIds.length),
            const SizedBox(height: 8),
            _buildBanksInfo(),
            const SizedBox(height: 16),
          ],

          _SectionTitle(title: AppLocalizations.of(context).translate('budgetOperations'), count: _transactions.length),
          const SizedBox(height: 8),
          _buildTransactionsList(txByCat),
        ],
      ),
    );
  }


  Widget _buildOverallSpendingCard() {
    final l10n = AppLocalizations.of(context);
    final computedSpent = _convertedTotalSpent;
    final progress = _budget.totalAmount > 0 ? (computedSpent / _budget.totalAmount).clamp(0.0, 1.0) : 0.0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l10n.translate('totalSpentLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
              Text('${fmtNum(computedSpent)} ${_budget.currency}', style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: AppColors.border,
              valueColor: AlwaysStoppedAnimation<Color>(
                progress > 1 ? Color(0xFFEF5350) : progress > 0.8 ? Color(0xFFFFA726) : AppColors.primary,
              ),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l10n.translate('budgetTotalLine', params: {'amount': fmtNum(_budget.totalAmount), 'currency': _budget.currency}), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
              Text('${(progress * 100).toStringAsFixed(0)}%', style: TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.bold, color: progress > 1 ? Color(0xFFEF5350) : AppColors.textPrimary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _actionBtn(
              icon: Icons.picture_as_pdf_rounded,
              label: 'PDF',
              color: Color(0xFFEF5350),
              onTap: () => _showBudgetPdf(context),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _actionBtn(
              icon: Icons.image_rounded,
              label: l10n.translate('budgetActionImage'),
              color: AppColors.primary,
              onTap: () => _shareAsImage(context),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _actionBtn(
              icon: Icons.share_rounded,
              label: l10n.translate('share'),
              color: Color(0xFF2E7D32),
              onTap: () => _shareBudgetPdf(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBtn({required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(40)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  // ── Share as Image ──
  Future<void> _shareAsImage(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      final image = await _screenshotController.capture();
      if (image == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/فاتورة_${_budget.name}.png');
      await file.writeAsBytes(image);
      await Share.shareXFiles([XFile(file.path)], text: l10n.translate('budgetShareBudget', params: {'name': _budget.name}));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.translate('error')}: $e'), backgroundColor: Color(0xFFEF5350)));
      }
    }
  }

  // ── Share PDF directly ──
  Future<void> _shareBudgetPdf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      final pdfBytes = await _generateBudgetPdf();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/فاتورة_${_budget.name}.pdf');
      await file.writeAsBytes(pdfBytes);
      await Share.shareXFiles([XFile(file.path)], text: l10n.translate('budgetShareBudget', params: {'name': _budget.name}));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.translate('error')}: $e'), backgroundColor: Color(0xFFEF5350)));
      }
    }
  }

  // ── PDF Preview ──
  Future<void> _showBudgetPdf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(child: DotsLoader()),
    );
    try {
      final pdfBytes = await _generateBudgetPdf();
      nav.pop();
      await Printing.layoutPdf(onLayout: (format) async => pdfBytes, name: 'فاتورة_${_budget.name}');
    } catch (e) {
      nav.pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.translate('budgetPdfError', params: {'error': e})), backgroundColor: Color(0xFFEF5350)));
      }
    }
  }

  Future<Uint8List> _generateBudgetPdf() async {
    return BudgetTreeReportPdf.generate(
      budget: _budget,
      transactions: _transactions,
      engine: _engine,
    );
  }

  // ── Per-Category Invoice ──
  void _showCategoryInvoice(BuildContext context, BudgetCategory cat, List<PersonalTransaction> txs) {
    final color = _colorForCategory(cat.name, cat.type);
    final convertedSpent = _convertedCatSpent[cat.name] ?? 0;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CategoryInvoiceSheet(
        category: cat,
        transactions: txs,
        color: color,
        budgetCurrency: _budget.currency,
        convertedSpent: convertedSpent,
        engine: _engine,
      ),
    );
  }

  Widget _buildSummaryCard() {
    final l10n = AppLocalizations.of(context);
    final computedTotalSpent = _convertedTotalSpent;
    final computedRemaining = (_budget.totalAmount - computedTotalSpent).clamp(0.0, double.infinity);
    final computedOver = computedTotalSpent > _budget.totalAmount;
    final computedOverAmount = computedOver ? computedTotalSpent - _budget.totalAmount : 0.0;
    final computedProgress = _budget.totalAmount > 0 ? (computedTotalSpent / _budget.totalAmount).clamp(0.0, 1.0) : 0.0;
    final computedUsagePercent = _budget.totalAmount > 0 ? (computedTotalSpent / _budget.totalAmount * 100).clamp(0.0, 100.0) : 0.0;
    final isOver = computedOver;
    final isWarning = computedUsagePercent >= 80 && !isOver;

    return Screenshot(
      controller: _screenshotController,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.primary, AppColors.primary.withAlpha(180)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_budget.name, style: TextStyle(fontFamily: 'Cairo', fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 4),
            Text(_budget.periodLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 20),
            Text(fmtNum(_budget.totalAmount), style: TextStyle(fontFamily: 'Cairo', fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 4),
            Text(l10n.translate('totalBudget'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 16),
            Row(
              children: [
                _SummaryStat(label: l10n.translate('expense'), amount: computedTotalSpent, color: Color(0xFFEF9A9A)),
                const SizedBox(width: 12),
                _SummaryStat(
                  label: isOver ? l10n.translate('budgetOverrun') : l10n.translate('remainingLabel'),
                  amount: isOver ? computedOverAmount : computedRemaining,
                  color: isOver ? Color(0xFFFFCDD2) : Color(0xFFA5D6A7),
                ),
                const SizedBox(width: 12),
                _SummaryStat(label: l10n.translate('percentage'), amount: computedUsagePercent, color: Colors.white70, suffix: '%'),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: computedProgress,
                backgroundColor: Colors.white.withAlpha(30),
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            if (isOver)
              Row(
                children: [
                  Icon(Icons.warning_rounded, size: 16, color: Color(0xFFFFCDD2)),
                  const SizedBox(width: 6),
                  Text(
                    l10n.translate('budgetOverMessage', params: {'amount': fmtNum(computedOverAmount)}),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFFFFCDD2), fontWeight: FontWeight.w600),
                  ),
                ],
              )
            else if (isWarning)
              Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFFFFECB3)),
                  const SizedBox(width: 6),
                  Text(
                    l10n.translate('budgetWarningMessage', params: {'percent': computedUsagePercent.toStringAsFixed(0)}),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFFFFECB3), fontWeight: FontWeight.w600),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodInfo() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.translate('periodLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(height: 2),
                Text(_budget.periodLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              ],
            ),
          ),
          if (_budget.endDate != null && !_budget.isExpired)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _budget.daysRemaining <= 7 ? Color(0xFFEF5350).withAlpha(20) : AppColors.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${_budget.daysRemaining} ${l10n.translate('day')}',
                style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.bold, color: _budget.daysRemaining <= 7 ? Color(0xFFEF5350) : AppColors.primary),
              ),
            ),
          if (_budget.isExpired)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(l10n.translate('budgetExpiredLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
            ),
        ],
      ),
    );
  }

  // ── Add New Category (inline professional form) ──
  void _toggleAddCategory() {
    final l10n = AppLocalizations.of(context);
    if (_freeCapacity <= 0.0001) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.translate('budgetInsufficientBalance'), style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: Color(0xFFEF5350),
      ));
      return;
    }
    if (!_showAddCategory) {
      _addCatNameCtrl.clear();
      _addCatAmountCtrl.clear();
      _addCatAmount = 0;
      _addCatError = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _addCatNameFocus.requestFocus();
      });
    }
    HapticFeedback.lightImpact();
    setState(() => _showAddCategory = !_showAddCategory);
  }

  Widget _buildAddCategorySection() {
    final l10n = AppLocalizations.of(context);
    final freeCapacity = _freeCapacity;
    final canAdd = freeCapacity > 0.0001;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _showAddCategory ? AppColors.primary : (canAdd ? AppColors.border : Color(0xFFEF5350).withAlpha(60)),
          width: _showAddCategory ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: _toggleAddCategory,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primary.withAlpha(35)),
                    ),
                    child: Icon(Icons.add_circle_outline, color: AppColors.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.translate('budgetAddCategory'),
                            style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary)),
                        const SizedBox(height: 2),
                        Text(
                          canAdd
                              ? l10n.translate('budgetAddCategoryBalance', params: {'amount': fmtNum(freeCapacity), 'currency': _budget.currency})
                              : l10n.translate('budgetAddCategoryBalanceZero'),
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: canAdd ? AppColors.textSecondary : Color(0xFFEF5350)),
                        ),
                      ],
                    ),
                  ),
                  Icon(_showAddCategory ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 18, color: AppColors.textSecondary),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _showAddCategory ? _buildAddCategoryForm() : SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildAddCategoryForm() {
    final l10n = AppLocalizations.of(context);
    final freeCapacity = _freeCapacity;
    final hasName = _addCatNameCtrl.text.trim().isNotEmpty;
    final exceeds = _addCatAmount > freeCapacity + 0.0001;
    final canSave = hasName && _addCatAmount > 0 && !exceeds && !_savingCategory;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(color: AppColors.border, height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FyonaTextField(
                controller: _addCatNameCtrl,
                focusNode: _addCatNameFocus,
                decoration: InputDecoration(
                  hintText: l10n.translate('budgetNewCategoryNameHint'),
                  hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textDisabled),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.primary, width: 2)),
                  contentPadding: const EdgeInsets.all(14),
                ),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 14),
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() => _addCatError = null),
                onSubmitted: (_) {
                  if (hasName) _addCatAmountFocus.requestFocus();
                },
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                child: hasName
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 12),
                          FyonaTextField(
                            controller: _addCatAmountCtrl,
                            focusNode: _addCatAmountFocus,
                            keyboardType: TextInputType.number,
                            inputFormatters: [AmountInputFormatter()],
                            decoration: InputDecoration(
                              hintText: '0',
                              hintStyle: TextStyle(color: AppColors.textDisabled),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.primary, width: 2)),
                              contentPadding: const EdgeInsets.all(14),
                              suffixText: ' ${_budget.currency}',
                              suffixStyle: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontFamily: 'Cairo'),
                            ),
                            style: const TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold),
                            onChanged: (v) {
                              _addCatAmount = double.tryParse(v.replaceAll(',', '')) ?? 0;
                              setState(() => _addCatError = null);
                            },
                          ),
                          if (exceeds)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                l10n.translate('budgetAmountExceedsRemaining', params: {'amount': fmtNum(freeCapacity), 'currency': _budget.currency}),
                                style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Color(0xFFEF5350), fontWeight: FontWeight.w600),
                              ),
                            ),
                        ],
                      )
                    : SizedBox.shrink(),
              ),
              if (_addCatError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_addCatError!, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Color(0xFFEF5350), fontWeight: FontWeight.w600)),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _saveNewCategory(context),
                  icon: const Icon(Icons.check_rounded, size: 20),
                  label: Text(_savingCategory ? l10n.translate('saving') : l10n.translate('save'),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: canSave ? AppColors.primary : AppColors.primary.withAlpha(55),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _saveNewCategory(BuildContext context) async {
    if (_savingCategory) return;
    final l10n = AppLocalizations.of(context);
    final name = _addCatNameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _addCatError = l10n.translate('budgetNewCategoryRequired'));
      return;
    }
    final amount = _addCatAmount;
    if (amount <= 0) {
      setState(() => _addCatError = l10n.translate('budgetNewCategoryAmountRequired'));
      return;
    }
    final freeCapacity = _freeCapacity;
    if (amount > freeCapacity + 0.0001) {
      HapticFeedback.heavyImpact();
      return;
    }
    if (_budget.categories.any((c) => c.name.trim().toLowerCase() == name.toLowerCase())) {
      setState(() => _addCatError = l10n.translate('budgetCategoryExists'));
      return;
    }

    final newCategory = BudgetCategory(
      id: '',
      budgetId: _budget.id,
      name: name,
      type: 'expense',
      allocatedAmount: amount,
      spentAmount: 0,
      currency: _budget.currency,
    );
    final updatedCategories = List<BudgetCategory>.from(_budget.categories);
    updatedCategories.add(newCategory);
    final updatedBudget = _budget.copyWith(categories: updatedCategories);

    setState(() {
      _savingCategory = true;
      _addCatError = null;
    });
    HapticFeedback.lightImpact();

    final notifier = ref.read(budgetProvider.notifier);
    await notifier.updateBudget(updatedBudget);
    if (!mounted) return;

    final providerState = ref.read(budgetProvider);
    if (providerState.error != null) {
      setState(() {
        _savingCategory = false;
        _addCatError = providerState.error;
      });
      return;
    }

    PersonalBudget? fresh;
    for (final b in providerState.budgets) {
      if (b.id == _budget.id) {
        fresh = b;
        break;
      }
    }
    if (fresh != null) {
      final hasNew = fresh.categories.any((c) => c.name.trim().toLowerCase() == name.toLowerCase());
      _budget = hasNew ? fresh : fresh.copyWith(categories: List<BudgetCategory>.from(fresh.categories)..add(newCategory));
    } else {
      _budget = updatedBudget;
    }
    await _loadTransactions();
    if (!mounted) return;

    _addCatNameCtrl.clear();
    _addCatAmountCtrl.clear();
    setState(() {
      _showAddCategory = false;
      _savingCategory = false;
      _addCatError = null;
      _addCatAmount = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(l10n.translate('budgetCategoryAdded', params: {'name': name}), style: TextStyle(fontFamily: 'Cairo')),
      backgroundColor: Color(0xFF2E7D32),
    ));
  }

  Widget _buildBanksInfo() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(Icons.account_balance_rounded, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.translate('budgetLinkedBanks', params: {'count': _budget.bankAccountIds.length}),
              style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionsList(Map<String, List<PersonalTransaction>> txByCat) {
    final l10n = AppLocalizations.of(context);
    if (_loadingTx) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
        child: Center(child: DotsLoader()),
      );
    }
    if (_transactions.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
        child: Column(
          children: [
            Icon(Icons.receipt_long_rounded, size: 36, color: AppColors.textDisabled),
            const SizedBox(height: 8),
            Text(l10n.translate('budgetNoOps'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    return Column(
      children: txByCat.entries.map((entry) {
        final catName = entry.key;
        final txs = entry.value;
        final color = _colorForCategory(catName, 'expense');
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              leading: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.receipt_long_rounded, color: color, size: 18),
              ),
              title: Text(catName, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
              subtitle: Text(l10n.translate('budgetTxCount', params: {'count': txs.length}), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
              trailing: Icon(Icons.expand_more, size: 20, color: AppColors.textSecondary),
              children: txs.map((tx) => Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.remove_circle_outline, size: 14, color: Color(0xFFEF5350)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tx.description ?? tx.category, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                          if (tx.date != null)
                            Text(DateFormat('dd/MM/yyyy').format(tx.date!), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${fmtNum(tx.amount)} ${tx.currency}', style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFEF5350))),
                        if (tx.currency != _budget.currency)
                          Text('≈ ${_convertTxAmount(tx.amount, tx.currency)} ${_budget.currency}', style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
                      ],
                    ),
                  ],
                ),
              )).toList(),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Category Invoice Bottom Sheet ──
class _CategoryInvoiceSheet extends StatelessWidget {
  final BudgetCategory category;
  final List<PersonalTransaction> transactions;
  final Color color;
  final String budgetCurrency;
  final double convertedSpent;
  final CurrencyEngine? engine;

  const _CategoryInvoiceSheet({
    required this.category,
    required this.transactions,
    required this.color,
    required this.budgetCurrency,
    this.convertedSpent = 0,
    this.engine,
  });

  String _convertAmount(double amount, String fromCurrency) {
    if (fromCurrency == budgetCurrency || engine == null) return fmtNum(amount);
    try {
      final converted = engine!.convert(amount, fromCurrency, budgetCurrency);
      if (converted > 0) return fmtNum(converted);
    } catch (_) {}
    return fmtNum(amount);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                    child: Icon(Icons.receipt_long_rounded, color: color, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(category.name, style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                        Text(l10n.translate('budgetCategoryInvoice'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withAlpha(10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withAlpha(30)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _invoiceStat(l10n.translate('budgetCap'), fmtNum(category.allocatedAmount), budgetCurrency),
                  Container(width: 1, height: 44, color: color.withAlpha(30)),
                  _invoiceStat(l10n.translate('expense'), fmtNum(convertedSpent), budgetCurrency),
                  Container(width: 1, height: 44, color: color.withAlpha(30)),
                  _invoiceStat(l10n.translate('remainingLabel'),
                      fmtNum((category.allocatedAmount - convertedSpent).clamp(0.0, double.infinity)), budgetCurrency),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // ── Action Buttons for Category ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _catActionBtn(
                      context: context,
                      icon: Icons.picture_as_pdf_rounded,
                      label: 'PDF',
                      color: Color(0xFFEF5350),
                      onTap: () => _previewCategoryPdf(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _catActionBtn(
                      context: context,
                      icon: Icons.share_rounded,
                      label: l10n.translate('share'),
                      color: Color(0xFF2E7D32),
                      onTap: () => _shareCategoryPdf(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.translate('budgetOperationsCount', params: {'count': transactions.length}), style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: transactions.isEmpty
                  ? Center(child: Text(l10n.translate('budgetNoCatOps'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)))
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: transactions.length,
                      itemBuilder: (context, i) {
                        final tx = transactions[i];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8, height: 8,
                                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(tx.description ?? tx.category, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                    if (tx.date != null)
                                      Text(DateFormat('dd/MM/yyyy').format(tx.date!), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('${fmtNum(tx.amount)} ${tx.currency}', style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFFEF5350))),
                                  if (tx.currency != budgetCurrency && engine != null)
                                    Text('≈ ${_convertAmount(tx.amount, tx.currency)} $budgetCurrency', style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _catActionBtn({required BuildContext context, required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(40)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _invoiceStat(String label, String amount, String currency) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(amount,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 2),
          Text(currency,
              textDirection: ui.TextDirection.ltr,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  // ── Preview Category PDF ──
  Future<void> _previewCategoryPdf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(child: DotsLoader()),
    );
    try {
      final pdfBytes = await _generateCategoryPdf();
      nav.pop();
      await Printing.layoutPdf(onLayout: (format) async => pdfBytes, name: 'فاتورة_${category.name}');
    } catch (e) {
      nav.pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.translate('error')}: $e'), backgroundColor: Color(0xFFEF5350)));
      }
    }
  }

  // ── Share Category PDF ──
  Future<void> _shareCategoryPdf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      final pdfBytes = await _generateCategoryPdf();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/فاتورة_${category.name}.pdf');
      await file.writeAsBytes(pdfBytes);
      await Share.shareXFiles([XFile(file.path)], text: l10n.translate('budgetShareCategory', params: {'name': category.name}));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.translate('error')}: $e'), backgroundColor: Color(0xFFEF5350)));
      }
    }
  }

  Future<Uint8List> _generateCategoryPdf() async {
    return BudgetTreeReportPdf.generateCategory(
      category: category,
      transactions: transactions,
      currency: budgetCurrency,
      engine: engine,
    );
  }
}

// ── Shared Widgets ──
class _SummaryStat extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final String? suffix;

  const _SummaryStat({required this.label, required this.amount, required this.color, this.suffix});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Colors.white70)),
          const SizedBox(height: 4),
          Text(
            suffix != null ? '${fmtNum(amount)}$suffix' : fmtNum(amount),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final BudgetCategory category;
  final double computedSpent;
  final Color color;
  final IconData icon;

  const _CategoryCard({required this.category, required this.computedSpent, required this.color, required this.icon});

  String _typeName(BuildContext context, String type) {
    final l10n = AppLocalizations.of(context);
    switch (type) {
      case 'expense': return l10n.translate('budgetTypeExpenses');
      case 'debt': return l10n.translate('budgetTypeDebts');
      case 'goal': return l10n.translate('budgetTypeGoals');
      default: return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final spent = computedSpent;
    final remaining = (category.allocatedAmount - spent).clamp(0.0, double.infinity);
    final isOver = spent > category.allocatedAmount;
    final overAmount = isOver ? spent - category.allocatedAmount : 0.0;
    final progress = category.allocatedAmount > 0 ? (spent / category.allocatedAmount).clamp(0.0, 1.0) : 0.0;
    final isWarning = progress >= 0.8 && !isOver;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOver ? Color(0xFFEF5350).withAlpha(80) : isWarning ? Color(0xFFFFA726).withAlpha(60) : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(category.name, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    Text(_typeName(context, category.type), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(fmtNum(category.allocatedAmount), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  Text(l10n.translate('budgetCap'), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: color.withAlpha(30),
              valueColor: AlwaysStoppedAnimation<Color>(isOver ? Color(0xFFEF5350) : isWarning ? Color(0xFFFFA726) : color),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l10n.translate('budgetSpentValue', params: {'amount': fmtNum(spent)}), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: isOver ? Color(0xFFEF5350) : AppColors.textSecondary)),
              Text(
                isOver ? l10n.translate('budgetOverBadge', params: {'amount': fmtNum(overAmount)}) : l10n.translate('budgetRemainingValue', params: {'amount': fmtNum(remaining)}),
                style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: isOver ? Color(0xFFEF5350) : Color(0xFF66BB6A)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final int count;
  const _SectionTitle({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.category_rounded, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        const Spacer(),
        if (count > 0) Text('$count', style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary)),
      ],
    );
  }
}
