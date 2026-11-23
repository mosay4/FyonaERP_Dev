import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import '../../data/models/personal_models.dart';
import '../../../../core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class BudgetTreeReportPdf {
  BudgetTreeReportPdf._();

  static pw.Font? _regular;
  static pw.Font? _bold;

  static Future<pw.Font> _getRegular() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
    return _regular!;
  }

  static Future<pw.Font> _getBold() async {
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
    return _bold!;
  }

  static PdfColor _c(int argb) => PdfColor.fromInt(argb);

  static final _black = PdfColor.fromHex('#000000');
  static final _darkCard = PdfColor.fromHex('#1A1A1A');
  static final _darkPanel = PdfColor.fromHex('#111111');
  static final _red = PdfColor.fromHex('#D32F2F');
  static final _white = PdfColors.white;
  static final _muted = PdfColor.fromHex('#888888');
  static final _green = PdfColor.fromHex('#4CAF50');
  static final _orange = PdfColor.fromHex('#FF9800');
  static final _divider = PdfColor.fromHex('#333333');

  static const _cardColors = [
    0xFFD32F2F, 0xFF1565C0, 0xFF2E7D32, 0xFFFF8F00,
    0xFF6A1B9A, 0xFF00838F, 0xFFD81B60, 0xFF37474F,
    0xFFE65100, 0xFF0277BD,
  ];

  static PdfColor _mix(PdfColor a, PdfColor b, double t) => PdfColor(
    a.red + (b.red - a.red) * t,
    a.green + (b.green - a.green) * t,
    a.blue + (b.blue - a.blue) * t,
    a.alpha + (b.alpha - a.alpha) * t,
  );

  static Future<Uint8List> generate({
    required PersonalBudget budget,
    required List<PersonalTransaction> transactions,
    CurrencyEngine? engine,
  }) async {
    final reg = await _getRegular();
    final bold = await _getBold();
    final doc = pw.Document();
    final nf = NumberFormat('#,##0');
    final now = DateTime.now();
    final dateStr = DateFormat('dd/MM/yyyy').format(now);
    final pageW = PdfPageFormat.a4.width - 56;
    final cur = budget.currency;

    // Helper: convert amount to budget currency
    double toBudgetCurrency(double amount, String fromCurrency) {
      if (fromCurrency == cur || engine == null) return amount;
      try {
        final converted = engine.convert(amount, fromCurrency, cur);
        return converted > 0 ? converted : amount;
      } catch (_) {
        return amount;
      }
    }

    // Compute total spent in budget currency
    final totalSpentConverted = transactions.fold<double>(0, (s, t) => s + toBudgetCurrency(t.amount, t.currency));

    // Build tree data
    final catsWithTx = <_BudgetTreeNode>[];
    for (int i = 0; i < budget.categories.length; i++) {
      final cat = budget.categories[i];
      if (cat.allocatedAmount <= 0) continue;
      final catTxs = transactions.where((t) => t.budgetCategoryId == cat.id).toList();
      final computedSpent = catTxs.fold<double>(0, (s, t) => s + toBudgetCurrency(t.amount, t.currency));
      final children = catTxs.map((tx) => _BudgetTreeNode(
        name: tx.description ?? tx.category,
        amount: tx.amount,
        currency: tx.currency,
        color: _c(_cardColors[catsWithTx.length % _cardColors.length]),
      )).toList();
      catsWithTx.add(_BudgetTreeNode(
        name: cat.name,
        amount: cat.allocatedAmount,
        spent: computedSpent,
        currency: budget.currency,
        color: _c(_cardColors[catsWithTx.length % _cardColors.length]),
        children: children,
      ));
    }

    // ── Page 1: Cover + Summary ──
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        textDirection: pw.TextDirection.rtl,
        buildBackground: (ctx) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Container(color: _black),
        ),
      ),
      build: (context) {
        final children = <pw.Widget>[];

        // Title
        children.add(pw.SizedBox(height: 20));
        children.add(pw.Center(child: pw.Text(budget.name, style: pw.TextStyle(font: bold, fontSize: 28, color: _red))));
        children.add(pw.SizedBox(height: 4));
        children.add(pw.Center(child: pw.Text(AppLocalizations.t('financialTree'), style: pw.TextStyle(font: bold, fontSize: 20, color: _white))));
        children.add(pw.SizedBox(height: 6));
        children.add(pw.Center(child: pw.Text(AppLocalizations.t('budgPdfSubtitle'), style: pw.TextStyle(font: reg, fontSize: 10, color: _muted))));
        children.add(pw.SizedBox(height: 8));
        children.add(pw.Center(child: pw.Container(width: 50, height: 2, color: _red)));
        children.add(pw.SizedBox(height: 20));

        // ── Summary Section ──
        children.add(_sectionTitle(AppLocalizations.t('budgPdfSummaryTitle'), bold));
        children.add(pw.SizedBox(height: 10));
        children.add(_summaryGrid(budget, totalSpentConverted, nf, reg, bold));
        children.add(pw.SizedBox(height: 14));
        children.add(pw.Container(height: 0.5, width: pageW, color: _divider));
        children.add(pw.SizedBox(height: 14));

        // ── Distribution ──
        children.add(_sectionTitle(AppLocalizations.t('distributionChart'), bold));
        children.add(pw.SizedBox(height: 10));
        children.add(_distributionBar(budget, catsWithTx, totalSpentConverted, nf, reg, bold));
        children.add(pw.SizedBox(height: 14));
        children.add(pw.Container(height: 0.5, width: pageW, color: _divider));
        children.add(pw.SizedBox(height: 14));

        // ── Changelog ──
        children.add(_sectionTitle(AppLocalizations.t('changelogSection'), bold));
        children.add(pw.SizedBox(height: 10));
        children.add(_changelogCard(budget, transactions.length, reg));
        children.add(pw.SizedBox(height: 20));

        // ── Footer ──
        children.add(pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('FYONA ERP', style: pw.TextStyle(font: bold, fontSize: 9, color: _muted)),
            pw.Text('${AppLocalizations.t('exportedOn')}: $dateStr', style: pw.TextStyle(font: reg, fontSize: 9, color: _muted)),
          ],
        ));

        return children;
      },
    ));

    // ── Page 2: Tree Diagram ──
    if (catsWithTx.isNotEmpty) {
      final layout = _buildTreeLayout(catsWithTx, budget);

      final contentW = max(520.0, layout.canvasW + 40);
      final headerH = 90.0;
      final treeH = layout.canvasH + 40;
      final summaryH = 120.0;
      final gaps = 16.0;
      final contentH = headerH + gaps + treeH + gaps + summaryH;
      final pageH2 = contentH + 80;

      doc.addPage(pw.Page(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat(
            contentW + 56,
            pageH2,
            marginTop: 22,
            marginBottom: 22,
            marginLeft: 28,
            marginRight: 28,
          ),
          textDirection: pw.TextDirection.rtl,
          buildBackground: (ctx) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: _black),
          ),
        ),
        build: (ctx) => pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            // Header
            pw.Text(budget.name, style: pw.TextStyle(font: reg, fontSize: 10, color: _muted)),
            pw.SizedBox(height: 4),
            pw.Text(AppLocalizations.t('financialTree'), style: pw.TextStyle(font: bold, fontSize: 22, color: _white)),
            pw.SizedBox(height: 4),
            pw.Text(AppLocalizations.t('budgPdfSubtitle'), style: pw.TextStyle(font: reg, fontSize: 10, color: _muted)),
            pw.SizedBox(height: 8),
            pw.Container(width: 46, height: 3, decoration: pw.BoxDecoration(color: _red, borderRadius: pw.BorderRadius.circular(1.5))),
            pw.SizedBox(height: gaps),

            // Tree panel
            pw.Container(
              width: contentW,
              alignment: pw.Alignment.center,
              padding: const pw.EdgeInsets.all(20),
              decoration: pw.BoxDecoration(
                color: _darkPanel,
                borderRadius: pw.BorderRadius.circular(22),
                border: pw.Border.all(color: _divider, width: 1),
              ),
              child: _buildTreeCanvas(layout, reg, bold, nf),
            ),
            pw.SizedBox(height: gaps),

            // Performance Summary
            pw.Container(
              width: contentW,
              padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: pw.BoxDecoration(
                color: _darkPanel,
                borderRadius: pw.BorderRadius.circular(18),
                border: pw.Border.all(color: _divider, width: 1),
              ),
              child: _performanceSummary(budget, totalSpentConverted, nf, reg, bold),
            ),
            pw.SizedBox(height: 14),

            // Footer
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('FYONA ERP', style: pw.TextStyle(font: bold, fontSize: 9, color: _muted)),
                pw.Text('${AppLocalizations.t('exportedOn')}: $dateStr', style: pw.TextStyle(font: reg, fontSize: 9, color: _muted)),
              ],
            ),
          ],
        ),
      ));
    }

    return Uint8List.fromList(await doc.save());
  }

  // ── Section Title ──
  static pw.Widget _sectionTitle(String text, pw.Font bold) {
    return pw.Row(
      children: [
        pw.Container(width: 3, height: 18, decoration: pw.BoxDecoration(color: _red, borderRadius: pw.BorderRadius.circular(1.5))),
        pw.SizedBox(width: 8),
        pw.Text(text, style: pw.TextStyle(font: bold, fontSize: 14, color: _white)),
      ],
    );
  }

  // ── Summary Grid ──
  static pw.Widget _summaryGrid(PersonalBudget budget, double convertedSpent, NumberFormat nf, pw.Font reg, pw.Font bold) {
    final remaining = budget.totalAmount - convertedSpent;
    final usagePercent = budget.totalAmount > 0 ? (convertedSpent / budget.totalAmount * 100).clamp(0.0, 100.0) : 0.0;
    final isOver = convertedSpent > budget.totalAmount;
    final items = [
      (AppLocalizations.t('totalBudget'), '${nf.format(budget.totalAmount)} ${budget.currency}', _red),
      (AppLocalizations.t('totalExpenses'), '${nf.format(convertedSpent)} ${budget.currency}', _red),
      (AppLocalizations.t('totalRemainingLabel'), '${nf.format(remaining)} ${budget.currency}', _green),
      (AppLocalizations.t('budgPdfUsageRate'), '${usagePercent.toStringAsFixed(1)}%', _orange),
      (AppLocalizations.t('budgPdfCatsCount'), '${budget.categories.where((c) => c.allocatedAmount > 0).length}', _white),
    ];
    final items2 = [
      (AppLocalizations.t('budgPdfNetStatus'), isOver ? AppLocalizations.t('overBudgetBadge') : AppLocalizations.t('budgPdfHealthy'), isOver ? _red : _green),
      (AppLocalizations.t('periodLabel'), budget.periodLabel, _white),
      (AppLocalizations.t('currencyLabel'), budget.currency, _white),
      (AppLocalizations.t('budgPdfDaysLeft'), '${budget.daysRemaining}', _white),
      (AppLocalizations.t('statusDetail'), budget.isExpired ? AppLocalizations.t('budgPdfExpired') : AppLocalizations.t('budgPdfActive'), budget.isExpired ? _red : _green),
    ];

    return pw.Column(
      children: [
        _statRow(items, reg, bold),
        pw.SizedBox(height: 8),
        _statRow(items2, reg, bold),
      ],
    );
  }

  static pw.Widget _statRow(List<(String, String, PdfColor)> items, pw.Font reg, pw.Font bold) {
    return pw.Row(
      children: items.map((item) {
        return pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            decoration: pw.BoxDecoration(
              border: pw.Border(left: pw.BorderSide(color: _divider, width: 0.5)),
            ),
            child: pw.Column(
              children: [
                pw.Text(item.$1, style: pw.TextStyle(font: reg, fontSize: 8, color: _muted), textAlign: pw.TextAlign.center),
                pw.SizedBox(height: 3),
                pw.Text(item.$2, style: pw.TextStyle(font: bold, fontSize: 10, color: item.$3), textAlign: pw.TextAlign.center),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── Distribution Bar ──
  static pw.Widget _distributionBar(PersonalBudget budget, List<_BudgetTreeNode> cats, double convertedSpent, NumberFormat nf, pw.Font reg, pw.Font bold) {
    if (budget.totalAmount <= 0) return pw.SizedBox();
    final pct = (convertedSpent / budget.totalAmount).clamp(0.0, 1.0);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(AppLocalizations.t('expense'), style: pw.TextStyle(font: reg, fontSize: 9, color: _muted)),
            pw.Text('${nf.format(convertedSpent)} ${budget.currency}', style: pw.TextStyle(font: bold, fontSize: 10, color: _white)),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Container(
          height: 16,
          decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Stack(
            children: [
              pw.Container(
                width: pct * (PdfPageFormat.a4.width - 56),
                height: 16,
                decoration: pw.BoxDecoration(color: _red, borderRadius: pw.BorderRadius.circular(4)),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 6),
        ...cats.map((cat) {
          final catPct = budget.totalAmount > 0 ? (cat.amount / budget.totalAmount).clamp(0.0, 1.0) : 0.0;
          return pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Row(
              children: [
                pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(color: cat.color, borderRadius: pw.BorderRadius.circular(2))),
                pw.SizedBox(width: 6),
                pw.Expanded(child: pw.Text(cat.name, style: pw.TextStyle(font: reg, fontSize: 8, color: _muted))),
                pw.Text('${nf.format(cat.amount)} ${budget.currency}', style: pw.TextStyle(font: reg, fontSize: 8, color: _white)),
                pw.SizedBox(width: 8),
                pw.Container(
                  width: 60, height: 6,
                  decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(3)),
                  child: pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Container(width: 60 * catPct, height: 6, decoration: pw.BoxDecoration(color: cat.color, borderRadius: pw.BorderRadius.circular(3))),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ── Changelog Card ──
  static pw.Widget _changelogCard(PersonalBudget budget, int txCount, pw.Font reg) {
    final items = [
      '${AppLocalizations.t('createdAt')}: ${budget.startDate != null ? DateFormat('dd/MM/yyyy').format(budget.startDate!) : '--'}',
      '${AppLocalizations.t('updatedAt')}: ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
      AppLocalizations.t('budgPdfCatsCountLine', {'count': budget.categories.where((c) => c.allocatedAmount > 0).length}),
      AppLocalizations.t('budgPdfTxCountLine', {'count': txCount}),
    ];
    return pw.Container(
      width: 220,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(8), border: pw.Border.all(color: _divider, width: 0.5)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: items.map((item) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Text('• $item', style: pw.TextStyle(font: reg, fontSize: 9, color: _white)),
        )).toList(),
      ),
    );
  }

  // ── Performance Summary ──
  static pw.Widget _performanceSummary(PersonalBudget budget, double convertedSpent, NumberFormat nf, pw.Font reg, pw.Font bold) {
    final remaining = budget.totalAmount - convertedSpent;
    final usagePercent = budget.totalAmount > 0 ? (convertedSpent / budget.totalAmount * 100).clamp(0.0, 100.0) : 0.0;
    final savingPercent = budget.totalAmount > 0 ? ((budget.totalAmount - convertedSpent) / budget.totalAmount * 100).clamp(0.0, 100.0) : 0.0;
    final items = [
      (AppLocalizations.t('netFlow'), '${nf.format(remaining)} ${budget.currency}', convertedSpent > budget.totalAmount ? _red : _green),
      (AppLocalizations.t('savingsRate'), budget.totalAmount > 0 ? '${((1 - convertedSpent / budget.totalAmount) * 100).clamp(0, 100).toStringAsFixed(1)}%' : '--', _green),
      (AppLocalizations.t('expenseRate'), '${usagePercent.toStringAsFixed(1)}%', _orange),
      (AppLocalizations.t('budgPdfSavingsPct'), budget.totalAmount > 0 ? '${savingPercent.toStringAsFixed(1)}%' : '--', _red),
    ];

    return pw.Row(
      children: items.map((item) => pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.symmetric(horizontal: 4),
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(10), border: pw.Border.all(color: _divider, width: 0.5)),
          child: pw.Column(
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Container(width: 6, height: 6, decoration: pw.BoxDecoration(color: item.$3, shape: pw.BoxShape.circle)),
                  pw.SizedBox(width: 4),
                  pw.Text(item.$1, style: pw.TextStyle(font: reg, fontSize: 8, color: _muted)),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Text(item.$2, style: pw.TextStyle(font: bold, fontSize: 12, color: _white)),
            ],
          ),
        ),
      )).toList(),
    );
  }

  // ═══════════════════════════════════════════════
  //  TREE LAYOUT & CANVAS
  // ═══════════════════════════════════════════════

  static const _kRootW = 190.0;
  static const _kRootH = 95.0;
  static const _kCatW = 140.0;
  static const _kCatH = 85.0;
  static const _kLeafW = 115.0;
  static const _kLeafH = 55.0;
  static const _kGap0 = 80.0;
  static const _kGapN = 65.0;
  static const _kHUnit = 130.0;

  static _TreeLayoutData _buildTreeLayout(List<_BudgetTreeNode> cats, PersonalBudget budget) {
    final nodes = <_LayoutNode>[];
    final edges = <_Edge>[];

    final catCount = cats.length;
    final totalLeaves = cats.fold<int>(0, (s, c) => s + max(1, c.children.length));
    final naturalW = totalLeaves * _kHUnit;
    final scale = naturalW > 500 ? 500 / naturalW : 1.0;

    double cw(int depth) => depth == 0 ? _kRootW * scale : (depth == 1 ? _kCatW * scale : _kLeafW * scale);
    double ch(int depth) => depth == 0 ? _kRootH * scale : (depth == 1 ? _kCatH * scale : _kLeafH * scale);
    double vGap(int depth) => (depth == 0 ? _kGap0 : _kGapN) * scale;

    // Root node
    final rootX = naturalW / 2;
    final rootY = 0.0;
    final rootColor = _red;
    nodes.add(_LayoutNode(0, rootX, rootY, 0, rootColor, cw(0), ch(0), budget.name, budget.totalAmount, budget.totalSpent, budget.currency));

    // Category nodes
    var catLeft = 0.0;
    final catSpacing = naturalW / catCount;
    final catTop = ch(0) + vGap(0);

    for (int i = 0; i < catCount; i++) {
      final cat = cats[i];
      final catW2 = cw(1);
      final catX = catLeft + catSpacing / 2;
      final catY = catTop;

      nodes.add(_LayoutNode(i + 1, catX, catY, 1, cat.color, catW2, ch(1), cat.name, cat.amount, cat.spent, budget.currency));
      edges.add(_Edge(0, i + 1, rootX, rootY + ch(0), catX, catY));

      // Leaf nodes (transactions)
      final children = cat.children;
      if (children.isNotEmpty) {
        final leafGap = catSpacing / children.length;
        final leafTop = catTop + ch(1) + vGap(1);
        for (int j = 0; j < children.length; j++) {
          final child = children[j];
          final leafX = catLeft + j * leafGap + leafGap / 2;
          final leafY = leafTop;
          nodes.add(_LayoutNode(100 + i * 50 + j, leafX, leafY, 2, child.color, cw(2), ch(2), child.name, child.amount, 0, child.currency.isNotEmpty ? child.currency : budget.currency));
          edges.add(_Edge(i + 1, 100 + i * 50 + j, catX, catY + ch(1), leafX, leafY));
        }
      }

      catLeft += catSpacing;
    }

    var maxY = 0.0;
    for (final n in nodes) {
      maxY = max(maxY, n.y + n.cardH);
    }

    return _TreeLayoutData(nodes, edges, naturalW, maxY + 30, scale);
  }

  static pw.Widget _buildTreeCanvas(_TreeLayoutData layout, pw.Font reg, pw.Font bold, NumberFormat nf) {
    if (layout.nodes.isEmpty) {
      return pw.Container(
        width: layout.canvasW, height: layout.canvasH,
        alignment: pw.Alignment.center,
        child: pw.Text('—', style: pw.TextStyle(font: reg, fontSize: 10, color: _muted)),
      );
    }

    final painter = pw.CustomPaint(
      size: PdfPoint(layout.canvasW, layout.canvasH),
      painter: (canvas, size) {
        final h = size.y;
        double py(double y) => h - y;

        // Glow behind root
        final root = layout.nodes.first;
        final hx = root.x;
        final hy = py(root.y + root.cardH / 2);
        for (var i = 3; i >= 1; i--) {
          final r = 40.0 + (3 - i) * 18.0;
          canvas.setFillColor(_mix(_black, root.color, 0.05 * (4 - i)));
          canvas.drawEllipse(hx, hy, r, r);
        }

        // Edges (bezier curves)
        for (final e in layout.edges) {
          final parent = layout.nodes.firstWhere((n) => n.id == e.parentId);
          final edgeColor = _mix(_black, parent.color, 0.55);
          final dx = e.childX - e.parentX;
          final dy = e.childY - e.parentY;
          canvas
            ..setStrokeColor(edgeColor)
            ..setLineWidth(1.5)
            ..moveTo(e.parentX, py(e.parentY))
            ..curveTo(
              e.parentX + dx * 0.18, py(e.parentY + dy * 0.52),
              e.childX - dx * 0.18, py(e.childY - dy * 0.52),
              e.childX, py(e.childY),
            )
            ..strokePath();
        }

        // Anchor circles at parent bottom
        for (final n in layout.nodes) {
          final hasChildren = layout.edges.any((e) => e.parentId == n.id);
          if (!hasChildren) continue;
          final ax = n.x;
          final ay = py(n.y + n.cardH + 4);
          canvas.setFillColor(_mix(_black, n.color, 0.28));
          canvas.drawEllipse(ax, ay, 5, 5);
          canvas.setFillColor(n.color);
          canvas.drawEllipse(ax, ay, 3, 3);
        }

        // Anchor circles at child top
        for (final n in layout.nodes) {
          if (n.depth == 0) continue;
          final ax = n.x;
          final ay = py(n.y - 4);
          canvas.setFillColor(_mix(_black, n.color, 0.35));
          canvas.drawEllipse(ax, ay, 4, 4);
          canvas.setFillColor(n.color);
          canvas.drawEllipse(ax, ay, 2, 2);
        }
      },
    );

    final cards = <pw.Widget>[];
    for (final ln in layout.nodes) {
      cards.add(pw.Positioned(
        left: ln.x - ln.cardW / 2,
        top: ln.y,
        child: _budgetNodeCard(ln, reg, bold, nf, max(0.8, layout.scale)),
      ));
    }

    return pw.SizedBox(
      width: layout.canvasW,
      height: layout.canvasH,
      child: pw.Stack(children: [painter, ...cards]),
    );
  }

  static pw.Widget _budgetNodeCard(_LayoutNode ln, pw.Font reg, pw.Font bold, NumberFormat nf, double fontScale) {
    final isRoot = ln.depth == 0;
    final isCat = ln.depth == 1;
    final padX = isRoot ? 14.0 : 10.0;
    final padY = isRoot ? 12.0 : 9.0;
    final amountText = nf.format(ln.amount);

    final valueSize = isRoot ? 17.0 * fontScale : (isCat ? 12.0 * fontScale : 11.0 * fontScale);
    final nameSize = isRoot ? 12.0 * fontScale : (isCat ? 9.5 * fontScale : 8.0 * fontScale);
    final curSize = isRoot ? 8.0 * fontScale : (isCat ? 7.5 * fontScale : 7.0 * fontScale);
    final cardH = isRoot ? 90.0 : (isCat ? 78.0 : 58.0);

    return pw.Container(
      width: ln.cardW,
      height: cardH,
      padding: pw.EdgeInsets.symmetric(horizontal: padX, vertical: padY),
      decoration: pw.BoxDecoration(
        color: _mix(_black, ln.color, isRoot ? 0.15 : 0.07),
        borderRadius: pw.BorderRadius.circular(isRoot ? 16 : 10),
        border: pw.Border.all(
          color: isRoot ? _mix(ln.color, _white, 0.35) : _mix(_black, ln.color, 0.6),
          width: isRoot ? 2 : 1.2,
        ),
        boxShadow: [
          if (isRoot) pw.BoxShadow(color: _mix(_black, ln.color, 0.35), blurRadius: 14, spreadRadius: 2),
        ],
      ),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Text(ln.name, maxLines: 1, style: pw.TextStyle(font: bold, fontSize: nameSize, color: _white)),
          pw.SizedBox(height: isRoot ? 5 : 3),
          pw.Text(amountText, maxLines: 1, style: pw.TextStyle(font: bold, fontSize: valueSize, color: _red)),
          if (ln.currency.isNotEmpty) ...[
            pw.SizedBox(height: 1),
            pw.Text(ln.currency, maxLines: 1, style: pw.TextStyle(font: reg, fontSize: curSize, color: _muted)),
          ],
          if (isCat && ln.spent > 0) ...[
            pw.SizedBox(height: 2),
            pw.Text(AppLocalizations.t('budgPdfSpentLine', {'amount': nf.format(ln.spent)}), maxLines: 1, style: pw.TextStyle(font: reg, fontSize: 6.5 * fontScale, color: _orange)),
            pw.Text(AppLocalizations.t('budgPdfRemainingLine', {'amount': nf.format(ln.amount - ln.spent)}), maxLines: 1, style: pw.TextStyle(font: reg, fontSize: 6.5 * fontScale, color: _green)),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════
  //  CATEGORY TREE PDF
  // ═══════════════════════════════════════════════

  static Future<Uint8List> generateCategory({
    required BudgetCategory category,
    required List<PersonalTransaction> transactions,
    required String currency,
    CurrencyEngine? engine,
  }) async {
    final reg = await _getRegular();
    final bold = await _getBold();
    final doc = pw.Document();
    final nf = NumberFormat('#,##0');
    final now = DateTime.now();
    final dateStr = DateFormat('dd/MM/yyyy').format(now);

    // Helper: convert amount to budget currency
    double toBudgetCurrency(double amount, String fromCurrency) {
      if (fromCurrency == currency || engine == null) return amount;
      try {
        final converted = engine.convert(amount, fromCurrency, currency);
        return converted > 0 ? converted : amount;
      } catch (_) {
        return amount;
      }
    }

    final catColor = _c(_cardColors[0]);
    final computedSpent = transactions.fold<double>(0, (s, t) => s + toBudgetCurrency(t.amount, t.currency));

    // Build leaf nodes from transactions
    final leafNodes = <_BudgetTreeNode>[];
    for (int i = 0; i < transactions.length; i++) {
      final tx = transactions[i];
      leafNodes.add(_BudgetTreeNode(
        name: tx.description ?? tx.category,
        amount: tx.amount,
        currency: tx.currency,
        color: _c(_cardColors[(i + 1) % _cardColors.length]),
      ));
    }

    // ── Page 1: Cover ──
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        textDirection: pw.TextDirection.rtl,
        buildBackground: (ctx) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Container(color: _black),
        ),
      ),
      build: (context) {
        final children = <pw.Widget>[];
        final pageW = PdfPageFormat.a4.width - 56;

        children.add(pw.SizedBox(height: 20));
        children.add(pw.Center(child: pw.Text(category.name, style: pw.TextStyle(font: bold, fontSize: 28, color: _red))));
        children.add(pw.SizedBox(height: 4));
        children.add(pw.Center(child: pw.Text(AppLocalizations.t('budgPdfCategoryTree'), style: pw.TextStyle(font: reg, fontSize: 16, color: _white))));
        children.add(pw.SizedBox(height: 6));
        children.add(pw.Center(child: pw.Text(AppLocalizations.t('budgPdfCategorySubtitle'), style: pw.TextStyle(font: reg, fontSize: 10, color: _muted))));
        children.add(pw.SizedBox(height: 8));
        children.add(pw.Center(child: pw.Container(width: 50, height: 2, color: _red)));
        children.add(pw.SizedBox(height: 20));

        // ── Category Stats ──
        children.add(_sectionTitle(AppLocalizations.t('budgPdfCategorySummary'), bold));
        children.add(pw.SizedBox(height: 10));
        children.add(_categoryStatsGrid(category, computedSpent, currency, nf, reg, bold));
        children.add(pw.SizedBox(height: 14));
        children.add(pw.Container(height: 0.5, width: pageW, color: _divider));
        children.add(pw.SizedBox(height: 14));

        // ── Distribution ──
        children.add(_sectionTitle(AppLocalizations.t('budgPdfDistribution'), bold));
        children.add(pw.SizedBox(height: 10));
        children.add(_categoryDistributionBar(category, computedSpent, leafNodes, currency, nf, reg, bold));
        children.add(pw.SizedBox(height: 14));
        children.add(pw.Container(height: 0.5, width: pageW, color: _divider));
        children.add(pw.SizedBox(height: 14));

        // ── Changelog ──
        children.add(_sectionTitle(AppLocalizations.t('changelogSection'), bold));
        children.add(pw.SizedBox(height: 10));
        children.add(_categoryChangelogCard(category, transactions.length, reg));
        children.add(pw.SizedBox(height: 20));

        // ── Footer ──
        children.add(pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('FYONA ERP', style: pw.TextStyle(font: bold, fontSize: 9, color: _muted)),
            pw.Text('${AppLocalizations.t('exportedOn')}: $dateStr', style: pw.TextStyle(font: reg, fontSize: 9, color: _muted)),
          ],
        ));

        return children;
      },
    ));

    // ── Page 2: Tree Diagram ──
    if (leafNodes.isNotEmpty) {
      final layout = _buildCategoryTreeLayout(leafNodes, category, currency, computedSpent);

      final contentW = max(400.0, layout.canvasW + 40);
      final headerH = 90.0;
      final treeH = layout.canvasH + 40;
      final summaryH = 120.0;
      final gaps = 16.0;
      final contentH = headerH + gaps + treeH + gaps + summaryH;
      final pageH2 = contentH + 80;

      doc.addPage(pw.Page(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat(
            contentW + 56,
            pageH2,
            marginTop: 22,
            marginBottom: 22,
            marginLeft: 28,
            marginRight: 28,
          ),
          textDirection: pw.TextDirection.rtl,
          buildBackground: (ctx) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: _black),
          ),
        ),
        build: (ctx) => pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(category.name, style: pw.TextStyle(font: reg, fontSize: 10, color: _muted)),
            pw.SizedBox(height: 4),
            pw.Text(AppLocalizations.t('budgPdfCategoryTree'), style: pw.TextStyle(font: bold, fontSize: 22, color: _white)),
            pw.SizedBox(height: 4),
            pw.Text('${category.allocatedAmount.toStringAsFixed(0)} $currency', style: pw.TextStyle(font: bold, fontSize: 14, color: _red)),
            pw.SizedBox(height: 8),
            pw.Container(width: 46, height: 3, decoration: pw.BoxDecoration(color: _red, borderRadius: pw.BorderRadius.circular(1.5))),
            pw.SizedBox(height: gaps),

            pw.Container(
              width: contentW,
              alignment: pw.Alignment.center,
              padding: const pw.EdgeInsets.all(20),
              decoration: pw.BoxDecoration(
                color: _darkPanel,
                borderRadius: pw.BorderRadius.circular(22),
                border: pw.Border.all(color: _divider, width: 1),
              ),
              child: _buildTreeCanvas(layout, reg, bold, nf),
            ),
            pw.SizedBox(height: gaps),

            // Performance Summary
            pw.Container(
              width: contentW,
              padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: pw.BoxDecoration(
                color: _darkPanel,
                borderRadius: pw.BorderRadius.circular(18),
                border: pw.Border.all(color: _divider, width: 1),
              ),
              child: _categoryPerformanceSummary(category, computedSpent, currency, nf, reg, bold),
            ),
            pw.SizedBox(height: 14),

            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('FYONA ERP', style: pw.TextStyle(font: bold, fontSize: 9, color: _muted)),
                pw.Text('${AppLocalizations.t('exportedOn')}: $dateStr', style: pw.TextStyle(font: reg, fontSize: 9, color: _muted)),
              ],
            ),
          ],
        ),
      ));
    }

    return Uint8List.fromList(await doc.save());
  }

  static pw.Widget _categoryStatsGrid(BudgetCategory category, double computedSpent, String currency, NumberFormat nf, pw.Font reg, pw.Font bold) {
    final remaining = (category.allocatedAmount - computedSpent).clamp(0.0, double.infinity);
    final isOver = computedSpent > category.allocatedAmount;
    final items = [
      (AppLocalizations.t('budgetCap'), '${nf.format(category.allocatedAmount)} $currency', _red),
      (AppLocalizations.t('expense'), '${nf.format(computedSpent)} $currency', _orange),
      (AppLocalizations.t('remainingLabel'), '${nf.format(remaining)} $currency', _green),
      (AppLocalizations.t('percentage'), '${category.allocatedAmount > 0 ? (computedSpent / category.allocatedAmount * 100).clamp(0.0, 100.0).toStringAsFixed(1) : '0'}%', _white),
      (AppLocalizations.t('statusDetail'), isOver ? AppLocalizations.t('overBudgetBadge') : AppLocalizations.t('budgPdfHealthy'), isOver ? _red : _green),
    ];
    return pw.Row(
      children: items.map((item) {
        return pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            decoration: pw.BoxDecoration(
              border: pw.Border(left: pw.BorderSide(color: _divider, width: 0.5)),
            ),
            child: pw.Column(
              children: [
                pw.Text(item.$1, style: pw.TextStyle(font: reg, fontSize: 8, color: _muted), textAlign: pw.TextAlign.center),
                pw.SizedBox(height: 3),
                pw.Text(item.$2, style: pw.TextStyle(font: bold, fontSize: 10, color: item.$3), textAlign: pw.TextAlign.center),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  static pw.Widget _categoryDistributionBar(BudgetCategory category, double computedSpent, List<_BudgetTreeNode> leaves, String currency, NumberFormat nf, pw.Font reg, pw.Font bold) {
    if (category.allocatedAmount <= 0) return pw.SizedBox();
    final pct = (computedSpent / category.allocatedAmount).clamp(0.0, 1.0);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(AppLocalizations.t('expense'), style: pw.TextStyle(font: reg, fontSize: 9, color: _muted)),
            pw.Text(nf.format(computedSpent), style: pw.TextStyle(font: bold, fontSize: 10, color: _white)),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Container(
          height: 16,
          decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Stack(
            children: [
              pw.Container(
                width: pct * (PdfPageFormat.a4.width - 56),
                height: 16,
                decoration: pw.BoxDecoration(color: _red, borderRadius: pw.BorderRadius.circular(4)),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 6),
        ...leaves.map((leaf) {
          final leafPct = computedSpent > 0 ? (leaf.amount / computedSpent).clamp(0.0, 1.0) : 0.0;
          return pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Row(
              children: [
                pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(color: leaf.color, borderRadius: pw.BorderRadius.circular(2))),
                pw.SizedBox(width: 6),
                pw.Expanded(child: pw.Text(leaf.name, style: pw.TextStyle(font: reg, fontSize: 8, color: _muted))),
                pw.Text('${nf.format(leaf.amount)} ${leaf.currency.isNotEmpty ? leaf.currency : currency}', style: pw.TextStyle(font: reg, fontSize: 8, color: _white)),
                pw.SizedBox(width: 8),
                pw.Container(
                  width: 60, height: 6,
                  decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(3)),
                  child: pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Container(width: 60 * leafPct, height: 6, decoration: pw.BoxDecoration(color: leaf.color, borderRadius: pw.BorderRadius.circular(3))),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  static pw.Widget _categoryChangelogCard(BudgetCategory category, int txCount, pw.Font reg) {
    final items = [
      AppLocalizations.t('budgPdfCategoryLabel', {'name': category.name}),
      AppLocalizations.t('budgPdfLimitLabel', {'amount': category.allocatedAmount}),
      AppLocalizations.t('budgPdfTxCountLine', {'count': txCount}),
      '${AppLocalizations.t('currencyLabel')}: ${category.currency}',
    ];
    return pw.Container(
      width: 220,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(8), border: pw.Border.all(color: _divider, width: 0.5)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: items.map((item) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Text('• $item', style: pw.TextStyle(font: reg, fontSize: 9, color: _white)),
        )).toList(),
      ),
    );
  }

  static pw.Widget _categoryPerformanceSummary(BudgetCategory category, double computedSpent, String currency, NumberFormat nf, pw.Font reg, pw.Font bold) {
    final remaining = (category.allocatedAmount - computedSpent).clamp(0.0, double.infinity);
    final usagePercent = category.allocatedAmount > 0 ? (computedSpent / category.allocatedAmount * 100).clamp(0.0, 100.0) : 0.0;
    final items = [
      (AppLocalizations.t('budgetCap'), '${nf.format(category.allocatedAmount)} $currency', _red),
      (AppLocalizations.t('expense'), '${nf.format(computedSpent)} $currency', _orange),
      (AppLocalizations.t('remainingLabel'), '${nf.format(remaining)} $currency', _green),
      (AppLocalizations.t('percentage'), '${usagePercent.toStringAsFixed(1)}%', _white),
    ];

    return pw.Row(
      children: items.map((item) => pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.symmetric(horizontal: 4),
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: _darkCard, borderRadius: pw.BorderRadius.circular(10), border: pw.Border.all(color: _divider, width: 0.5)),
          child: pw.Column(
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Container(width: 6, height: 6, decoration: pw.BoxDecoration(color: item.$3, shape: pw.BoxShape.circle)),
                  pw.SizedBox(width: 4),
                  pw.Text(item.$1, style: pw.TextStyle(font: reg, fontSize: 8, color: _muted)),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Text(item.$2, style: pw.TextStyle(font: bold, fontSize: 12, color: _white)),
            ],
          ),
        ),
      )).toList(),
    );
  }

  static _TreeLayoutData _buildCategoryTreeLayout(List<_BudgetTreeNode> leaves, BudgetCategory category, String currency, double computedSpent) {
    final catColor = _c(_cardColors[0]);
    final nodes = <_LayoutNode>[];
    final edges = <_Edge>[];

    final leafCount = leaves.length;
    final naturalW = leafCount * _kHUnit;
    final scale = naturalW > 400 ? 400 / naturalW : 1.0;

    double cw(int depth) => depth == 0 ? _kRootW * scale : _kLeafW * scale;
    double ch(int depth) => depth == 0 ? 95.0 : _kLeafH * scale;
    double vGap(int depth) => (depth == 0 ? _kGap0 : _kGapN) * scale;

    // Root node (category)
    final rootX = naturalW / 2;
    final rootY = 0.0;
    nodes.add(_LayoutNode(0, rootX, rootY, 0, catColor, cw(0), ch(0), category.name, category.allocatedAmount, computedSpent, currency));
    edges.add(_Edge(0, 1, rootX, rootY + ch(0), rootX, rootY));

    // Leaf nodes (transactions)
    final leafTop = ch(0) + vGap(0);
    var leafLeft = 0.0;
    final leafSpacing = naturalW / max(1, leafCount);

    for (int i = 0; i < leafCount; i++) {
      final leaf = leaves[i];
      final leafX = leafLeft + leafSpacing / 2;
      final leafY = leafTop;
      nodes.add(_LayoutNode(100 + i, leafX, leafY, 2, leaf.color, cw(1), ch(1), leaf.name, leaf.amount, 0, leaf.currency.isNotEmpty ? leaf.currency : currency));
      edges.add(_Edge(0, 100 + i, rootX, rootY + ch(0), leafX, leafY));
      leafLeft += leafSpacing;
    }

    var maxY = 0.0;
    for (final n in nodes) {
      maxY = max(maxY, n.y + n.cardH);
    }

    return _TreeLayoutData(nodes, edges, naturalW, maxY + 30, scale);
  }
}

// ── Data models ──

class _BudgetTreeNode {
  final String name;
  final double amount;
  final double spent;
  final PdfColor color;
  final String currency;
  final List<_BudgetTreeNode> children;

  _BudgetTreeNode({required this.name, required this.amount, this.spent = 0, required this.color, this.currency = '', this.children = const []});
}

class _LayoutNode {
  final int id;
  final double x, y;
  final int depth;
  final PdfColor color;
  final double cardW, cardH;
  final String name;
  final double amount;
  final double spent;
  final String currency;

  _LayoutNode(this.id, this.x, this.y, this.depth, this.color, this.cardW, this.cardH, this.name, this.amount, this.spent, this.currency);
}

class _Edge {
  final int parentId, childId;
  final double parentX, parentY, childX, childY;

  _Edge(this.parentId, this.childId, this.parentX, this.parentY, this.childX, this.childY);
}

class _TreeLayoutData {
  final List<_LayoutNode> nodes;
  final List<_Edge> edges;
  final double canvasW, canvasH, scale;

  _TreeLayoutData(this.nodes, this.edges, this.canvasW, this.canvasH, this.scale);
}
