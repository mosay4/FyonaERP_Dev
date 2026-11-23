import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import '../../data/models/financial_tree_models.dart';
import '../providers/receipt_design_models.dart';

class FinancialTreeReportPdfGenerator {
  FinancialTreeReportPdfGenerator._();

  static PdfColor _c(int color) => PdfColor.fromInt(color);

  // ── Design tokens (أحجام ومسافات موحّدة) ──
  static const double gapSmall = 6;
  static const double gapMed = 10;
  static const double gapLarge = 14;
  static const double fsH1 = 20;
  static const double fsH2 = 13;
  static const double fsBody = 10;
  static const double fsSmall = 8.5;
  static const double fsCard = 7;

  static String _tr(Map<String, String>? translations, String key, String fallback) =>
      translations?[key] ?? fallback;

  static String _typeLabel(FinancialTreeNodeType type, Map<String, String>? translations) {
    final translated = translations?[type.labelKey];
    if (translated != null && translated.trim().isNotEmpty) return translated;
    switch (type) {
      case FinancialTreeNodeType.root: return 'الجذر';
      case FinancialTreeNodeType.income: return 'الدخل';
      case FinancialTreeNodeType.expense: return 'المصروفات';
      case FinancialTreeNodeType.asset: return 'الأصول';
      case FinancialTreeNodeType.investment: return 'الاستثمارات';
      case FinancialTreeNodeType.debt: return 'الديون';
      case FinancialTreeNodeType.liability: return 'الالتزامات';
      case FinancialTreeNodeType.transfer: return 'التحويلات';
      case FinancialTreeNodeType.saving: return 'الادخار';
      case FinancialTreeNodeType.payment: return 'الدفعات';
      case FinancialTreeNodeType.receivable: return 'المستحقات';
      case FinancialTreeNodeType.custom: return 'أخرى';
    }
  }

  static pw.Font? _fontRegular;
  static pw.Font? _fontBold;

  static Future<pw.Font> _getRegular() async {
    _fontRegular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
    return _fontRegular!;
  }

  static Future<pw.Font> _getBold() async {
    _fontBold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
    return _fontBold!;
  }

  static Future<Uint8List> generate({
    required FinancialTreeReportSnapshot snapshot,
    required ReceiptDesignPreset preset,
    required Map<String, String>? translations,
    required String reportTitle,
    required String periodLabel,
    bool showTree = true,
    bool showKpis = true,
    bool showCharts = true,
    bool showPayments = true,
    bool showNotes = true,
    bool showChangelog = true,
    bool landscape = false,
  }) async {
    final reg = await _getRegular();
    final bold = await _getBold();
    final doc = pw.Document();
    final nf = NumberFormat('#,##0');
    final nfCard = NumberFormat('#,##0.##');
    final tree = snapshot.tree;
    final comp = snapshot.computation;
    final nodes = snapshot.nodes;
    final cur = tree.currency.isEmpty ? '' : ' ${tree.currency}';
    final format = landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

    final pColor = _c(preset.primaryColor.toARGB32());
    final cardColor = _c(preset.cardBackground.toARGB32());
    final txtColor = _c(preset.textColor.toARGB32());
    final subColor = _c(preset.secondaryTextColor.toARGB32());
    final divColor = _c(preset.dividerColor.toARGB32());
    final amountColor = _c(preset.amountColor.toARGB32());
    final successColor = _c(preset.successColor.toARGB32());
    final dangerColor = _c(preset.dangerColor.toARGB32());
    // خلفية سوداء نقية موحّدة لكل صفحات الملف (بما فيها صفحة الشجرة)
    final pureBlack = _c(0xFF000000);

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: format,
          margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 22),
          textDirection: pw.TextDirection.rtl,
          buildBackground: (ctx) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: pureBlack),
          ),
        ),
        build: (pw.Context context) {
          final children = <pw.Widget>[];
          final pageW = format.width - 56;

          // ── Cover ──
          if (preset.showBrandLogo && preset.logoBytes != null) {
            children.add(pw.Center(child: pw.Image(pw.MemoryImage(preset.logoBytes!), height: 38)));
            children.add(pw.SizedBox(height: gapMed));
          }
          children.add(pw.Center(child: pw.Text(reportTitle, style: pw.TextStyle(font: bold, fontSize: fsH1, color: pColor))));
          children.add(pw.SizedBox(height: gapSmall));
          if (tree.name.isNotEmpty) {
            children.add(pw.Center(child: pw.Text(tree.name, style: pw.TextStyle(font: bold, fontSize: fsH2, color: txtColor))));
            children.add(pw.SizedBox(height: gapSmall));
          }
          if (tree.clientName.isNotEmpty) {
            children.add(pw.Center(child: pw.Text('${_tr(translations, 'clientName', 'العميل')}: ${tree.clientName}', style: pw.TextStyle(font: reg, fontSize: fsBody, color: subColor))));
            children.add(pw.SizedBox(height: gapSmall));
          }
          if (periodLabel.isNotEmpty) {
            children.add(pw.Center(child: pw.Text(periodLabel, style: pw.TextStyle(font: reg, fontSize: fsBody, color: subColor))));
            children.add(pw.SizedBox(height: gapSmall));
          }
          children.add(pw.Center(child: pw.Text('${_tr(translations, 'reportCreatedOn', 'تاريخ الإنشاء')}: ${_formatDate(snapshot.createdAt)}', style: pw.TextStyle(font: reg, fontSize: fsSmall, color: subColor))));
          children.add(pw.SizedBox(height: gapLarge));
          children.add(pw.Container(height: 1.5, width: pageW, color: pColor));
          children.add(pw.SizedBox(height: gapLarge));

          if (showNotes && tree.notes.isNotEmpty) {
            children.add(pw.Container(
              padding: const pw.EdgeInsets.all(8),
              margin: const pw.EdgeInsets.only(bottom: gapMed),
              decoration: pw.BoxDecoration(color: cardColor, borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Text(tree.notes, style: pw.TextStyle(font: reg, fontSize: fsBody, color: subColor)),
            ));
          }

          // ── KPIs ──
          if (showKpis) {
            children.add(_sectionTitle(_tr(translations, 'summary', 'الملخص'), pColor, bold, translations));
            children.add(pw.SizedBox(height: gapMed));
            children.add(_kpiGrid(comp, cur, nf, reg, bold, txtColor, subColor, successColor, dangerColor, amountColor, pColor, translations));
            children.add(pw.SizedBox(height: gapMed));
            children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
            children.add(pw.SizedBox(height: gapLarge));
          }

          // ── Charts ──
          if (showCharts) {
            children.add(_sectionTitle(_tr(translations, 'distributionChart', 'التوزيع حسب النوع'), pColor, bold, translations));
            children.add(pw.SizedBox(height: gapSmall));
            children.add(_distributionBars(comp, nf, reg, bold, txtColor, subColor, translations));
            children.add(pw.SizedBox(height: gapMed));
            children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
            children.add(pw.SizedBox(height: gapLarge));
          }

          // ── Changelog ──
          if (showChangelog) {
            children.add(_sectionTitle(_tr(translations, 'changelogSection', 'سجل التغييرات'), pColor, bold, translations));
            children.add(pw.SizedBox(height: gapSmall));
            final changes = [
              '${_tr(translations, 'createdAt', 'تاريخ الإنشاء')}: ${_formatDate(tree.createdAt)}',
              '${_tr(translations, 'updatedAt', 'آخر تحديث')}: ${_formatDate(tree.updatedAt)}',
              '${_tr(translations, 'nodesCount', 'عدد العقد')}: ${nodes.length}',
              '${_tr(translations, 'paymentsCount', 'عدد الدفعات')}: ${nodes.fold<int>(0, (s, n) => s + n.payments.length)}',
            ];
            children.add(pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(color: cardColor, borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: changes.map((c) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.Text('• $c', style: pw.TextStyle(font: reg, fontSize: fsSmall, color: txtColor)),
                )).toList(),
              ),
            ));
            children.add(pw.SizedBox(height: gapMed));
            children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
            children.add(pw.SizedBox(height: gapLarge));
          }

          // ── Footer ──
          if (preset.showFooter) {
            children.add(_buildFooter(preset, reg, subColor, translations, _formatDate(DateTime.now())));
          }
          children.add(pw.SizedBox(height: gapSmall));

          return children;
        },
      ),
    );

    if (showTree) {
      doc.addPage(_infographicPage(
        nodes: nodes,
        tree: tree,
        comp: comp,
        cur: cur,
        nf: nfCard,
        reportTitle: reportTitle,
        translations: translations,
        reg: reg,
        bold: bold,
        brand: pColor,
        bg: pureBlack,
        panel: pureBlack,
        panelBorder: divColor,
        white: txtColor,
        muted: subColor,
        danger: dangerColor,
      ));
    }

    return Uint8List.fromList(await doc.save());
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static pw.Widget _sectionTitle(String text, PdfColor pColor, pw.Font bold, [Map<String, String>? translations]) {
    return pw.Row(
      children: [
        pw.Container(width: 3, height: 18, decoration: pw.BoxDecoration(color: pColor, borderRadius: pw.BorderRadius.circular(1.5))),
        pw.SizedBox(width: 8),
        pw.Text(text, style: pw.TextStyle(font: bold, fontSize: fsH2, color: PdfColors.white)),
      ],
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  Financial Infographic (Organic Relationship Map)
  //  Colors follow the app palette (FinancialTreeNodeType.color).
  // ────────────────────────────────────────────────────────────────

  /// تقدير تقريبي لعرض المحرف الواحد (بكسل) للتحكم في حجم الخط دون قصّ.
  static double _charWidth(int code, double size) {
    if (code == 0x20 || code == 0x2E || code == 0x2C) return size * 0.30;
    if (code >= 0x600 && code <= 0x8FF) return size * 0.47; // Arabic
    if (code >= 0x30 && code <= 0x39) return size * 0.55; // digits
    if ((code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A)) {
      return size * 0.55; // latin
    }
    return size * 0.5;
  }

  /// تقدير تقريبي لعرض النص (بكسل) للتحكم في حجم الخط دون قصّ.
  static double _estWidth(String text, double size) {
    var w = 0.0;
    for (final code in text.runes) {
      w += _charWidth(code, size);
    }
    return w;
  }

  static double _fitSize(String text, double maxW, double base, double min) {
    var s = base;
    while (s > min && _estWidth(text, s) > maxW) {
      s -= 0.5;
    }
    return s;
  }

  static PdfColor _mix(PdfColor a, PdfColor b, double t) => PdfColor(
        a.red + (b.red - a.red) * t,
        a.green + (b.green - a.green) * t,
        a.blue + (b.blue - a.blue) * t,
        a.alpha + (b.alpha - a.alpha) * t,
      );

  // ── خوارزمية التخطيط: Leaf-weighted مع توسيط الأب فوق أبنائه ──
  // كل ابن يحصل على مساحة تتناسب مع عدد أوراقه (لا تداخل مهما تغيّر العدد)،
  // الأب يتركز فوق نطاق أبنائه، والفجوات العمودية تتناقص مع العمق لإحساس
  // أورجانيك متدرج. القماش يتكيف مع حدود الشجرة الفعلية (لا فراغ ثابت).

  static const double _kHUnit = 150; // عرض "ورقة" (خلية) واحدة
  static const double _kMinCanvasW = 300;
  static const double _kMaxCanvasW = 4800; // تجاوز → ضغط نسبي موحّد
  static const double _kRootW = 216;
  static const double _kRootH = 92;
  static const double _kCatW = 150;
  static const double _kCatH = 76;
  static const double _kLeafW = 124;
  static const double _kLeafH = 66;
  static const double _kGap0 = 100; // مسافة الجذر ← الفئات الرئيسية
  static const double _kGapN = 74; // المستويات الأعمق
  static const double _kAnchorGap = 4.5; // مسافة نقطة الاتصال عن البطاقة

  static _TreeLayout _buildLayout(List<FinancialTreeNode> nodes, PdfColor brand) {
    final byParent = <String?, List<FinancialTreeNode>>{};
    for (final n in nodes) {
      byParent.putIfAbsent(n.parentId, () => []).add(n);
    }
    for (final l in byParent.values) {
      l.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }
    final roots = byParent[null] ?? const <FinancialTreeNode>[];
    if (roots.isEmpty) {
      return _TreeLayout(<_LayoutNode>[], <String, _LayoutNode>{}, <_TreeEdge>[], byParent, _kMinCanvasW, 240, 1.0);
    }

    final weights = <String, double>{};
    double weight(FinancialTreeNode n) {
      final cached = weights[n.id];
      if (cached != null) return cached;
      final ch = byParent[n.id] ?? const <FinancialTreeNode>[];
      if (ch.isEmpty) return weights[n.id] = 1;
      var s = 0.0;
      for (final c in ch) {
        s += weight(c);
      }
      return weights[n.id] = s;
    }

    var totalLeaves = 0.0;
    for (final r in roots) {
      totalLeaves += weight(r);
    }
    final multiRoot = roots.length > 1;

    // ضغط نسبي موحّد عند تجاوز العرض الأقصى (تبقى النسب متناسقة)
    var scale = 1.0;
    final naturalW = totalLeaves * _kHUnit;
    if (naturalW > _kMaxCanvasW) {
      scale = _kMaxCanvasW / naturalW;
    }

    double cardW(int depth) =>
        depth == 0 ? _kRootW * scale : (depth == 1 ? _kCatW * scale : _kLeafW * scale);
    double cardH(int depth) =>
        depth == 0 ? _kRootH * scale : (depth == 1 ? _kCatH * scale : _kLeafH * scale);
    double vGap(int depth) => (depth == 0 ? _kGap0 : _kGapN) * scale;

    final out = <_LayoutNode>[];
    final byId = <String, _LayoutNode>{};
    final visited = <String>{};

    void place(FinancialTreeNode n, double left, double right, int depth, double top) {
      // هامش أفقي صغير بين البطاقات المتجاورة (لا تتلامس حدودياً)
      const gapX = 12.0;
      final cw = depth == 0
          ? (multiRoot
              ? min(220.0 * scale, max(140.0 * scale, (right - left) - gapX * scale))
              : cardW(depth))
          : min(cardW(depth), max(100.0 * scale, (right - left) - gapX * scale));
      final ch = cardH(depth);
      final x = (left + right) / 2;
      final ln = _LayoutNode(n, x, top, depth, _c(n.type.color), cw, ch);
      out.add(ln);
      byId[n.id] = ln;
      visited.add(n.id);

      final kids = byParent[n.id] ?? const <FinancialTreeNode>[];
      if (kids.isEmpty) return;
      final span = right - left;
      final wN = weight(n);
      final childTop = top + ch + vGap(depth);
      var cLeft = left;
      for (final k in kids) {
        final cw2 = span * (weight(k) / wN);
        place(k, cLeft, cLeft + cw2, depth + 1, childTop);
        cLeft += cw2;
      }
    }

    var left = 0.0;
    for (final r in roots) {
      final rw = weight(r) * _kHUnit * scale;
      place(r, left, left + rw, 0, 0);
      left += rw;
    }

    // عقد يتيمة (أب غير موجود) — تُوضع كفروع من المستوى الأول
    for (final n in nodes) {
      if (visited.contains(n.id)) continue;
      final rw = weight(n) * _kHUnit * scale;
      place(n, left, left + rw, 1, vGap(0));
      left += rw;
    }

    // حدود الشجرة (أطراف البطاقات) ثم توسيطها في القماش
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final ln in out) {
      minX = min(minX, ln.x - ln.cardW / 2);
      maxX = max(maxX, ln.x + ln.cardW / 2);
      maxY = max(maxY, ln.y + ln.cardH);
    }
    if (minX.isInfinite) {
      minX = 0;
      maxX = _kMinCanvasW;
      maxY = 240;
    }
    final canvasW = max(_kMinCanvasW, maxX - minX);
    final padTop = 26 * scale; // مساحة لتوهج الجذر
    final canvasH = padTop + maxY + 12 * scale;
    final extraX = (canvasW - (maxX - minX)) / 2;
    for (final ln in out) {
      ln.x += -minX + extraX;
      ln.y += padTop;
    }

    // الحواف: بيزيه مكعب من أسفل الأب إلى أعلى كل ابن (إحداثيات Flutter)
    final edges = <_TreeEdge>[];
    for (final ln in out) {
      final kids = byParent[ln.node.id] ?? const <FinancialTreeNode>[];
      if (kids.isEmpty) continue;
      final px = ln.x;
      final py = ln.y + ln.cardH + _kAnchorGap;
      for (final k in kids) {
        final kl = byId[k.id];
        if (kl == null) continue;
        final cx = kl.x;
        final cy = kl.y - _kAnchorGap;
        final dx = cx - px;
        final dy = cy - py;
        edges.add(_TreeEdge(
          ln,
          kl,
          px, py,
          px + dx * 0.18, py + dy * 0.52,
          cx - dx * 0.18, cy - dy * 0.52,
          cx, cy,
        ));
      }
    }

    return _TreeLayout(out, byId, edges, byParent, canvasW, canvasH, scale);
  }

  // ── صفحة الإنفوغرافيك الكاملة (عنوان + شجرة + ملخص) ──

  static pw.Page _infographicPage({
    required List<FinancialTreeNode> nodes,
    required FinancialTree tree,
    required TreeComputation comp,
    required String cur,
    required NumberFormat nf,
    required String reportTitle,
    required Map<String, String>? translations,
    required pw.Font reg,
    required pw.Font bold,
    required PdfColor brand,
    required PdfColor bg,
    required PdfColor panel,
    required PdfColor panelBorder,
    required PdfColor white,
    required PdfColor muted,
    required PdfColor danger,
  }) {
    final layout = _buildLayout(nodes, brand);

    const pad = 30.0;
    const panelPad = 20.0;
    const headerH = 112.0;
    const gaps = 16.0;
    const summaryH = 150.0;

    // العرض يتكيف مع عرض الشجرة الفعلي → صفحة Landscape تلقائياً عند الحاجة
    final contentW = max(520.0, layout.width + panelPad * 2);
    final contentH = headerH + gaps + (panelPad * 2 + layout.height) + gaps + summaryH;
    final pageW = contentW + pad * 2;
    final pageH = contentH + pad * 2;

    // عرض بطاقة الملخص لتكييف حجم قيمة صافي التدفق تلقائياً
    final summaryValueW = ((contentW - 36) - 36) / 4 - 20;

    return pw.Page(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat(
          pageW,
          pageH,
          marginTop: pad,
          marginBottom: pad,
          marginLeft: pad,
          marginRight: pad,
        ),
        textDirection: pw.TextDirection.rtl,
        buildBackground: (ctx) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Container(color: bg),
        ),
      ),
      build: (ctx) => pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          _infographicHeader(tree, reportTitle, brand, reg, bold, white, muted, translations),
          pw.SizedBox(height: gaps),
          pw.Container(
            width: contentW,
            alignment: pw.Alignment.center,
            padding: const pw.EdgeInsets.all(panelPad),
            decoration: pw.BoxDecoration(
              color: panel,
              borderRadius: pw.BorderRadius.circular(22),
              border: pw.Border.all(color: panelBorder, width: 1),
            ),
            child: _treeCanvas(
              layout: layout,
              white: white,
              bg: bg,
              muted: muted,
              danger: danger,
              reg: reg,
              bold: bold,
              nf: nf,
            ),
          ),
          pw.SizedBox(height: gaps),
          pw.Container(
            width: contentW,
            padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: pw.BoxDecoration(
              color: panel,
              borderRadius: pw.BorderRadius.circular(18),
              border: pw.Border.all(color: panelBorder, width: 1),
            ),
            child: _summaryDashboard(
              comp: comp,
              cur: cur,
              nf: nf,
              brand: brand,
              white: white,
              muted: muted,
              panel: panel,
              panelBorder: panelBorder,
              reg: reg,
              bold: bold,
              translations: translations,
              valueMaxW: summaryValueW,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _infographicHeader(
    FinancialTree tree,
    String reportTitle,
    PdfColor brand,
    pw.Font reg,
    pw.Font bold,
    PdfColor white,
    PdfColor muted,
    Map<String, String>? translations,
  ) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        if (tree.name.isNotEmpty)
          pw.Text(tree.name, style: pw.TextStyle(font: reg, fontSize: 10.5, color: muted)),
        if (tree.name.isNotEmpty) pw.SizedBox(height: 6),
        pw.Text(_tr(translations, 'treeSection', 'الشجرة المالية'),
            style: pw.TextStyle(font: bold, fontSize: 22, color: white)),
        pw.SizedBox(height: 8),
        pw.Text(
            _tr(translations, 'treeSubtitle',
                'نظرة شاملة على تدفق الأموال وفئات الإنفاق والاستثمار'),
            style: pw.TextStyle(font: reg, fontSize: 10.5, color: muted)),
        pw.SizedBox(height: 12),
        pw.Container(
          width: 46,
          height: 3,
          decoration: pw.BoxDecoration(color: brand, borderRadius: pw.BorderRadius.circular(1.5)),
        ),
      ],
    );
  }

  // ── رسم الشجرة: حواف بيزيه منحنية + نقاط اتصال + بطاقات مدمجة ──

  static pw.Widget _treeCanvas({
    required _TreeLayout layout,
    required PdfColor white,
    required PdfColor bg,
    required PdfColor muted,
    required PdfColor danger,
    required pw.Font reg,
    required pw.Font bold,
    required NumberFormat nf,
  }) {
    if (layout.nodes.isEmpty) {
      return pw.Container(
        width: layout.width,
        height: layout.height,
        alignment: pw.Alignment.center,
        child: pw.Text('—', style: pw.TextStyle(font: reg, fontSize: fsBody, color: muted)),
      );
    }

    // موصلات + نقاط اتصال (تُرسم قبل البطاقات)
    final painter = pw.CustomPaint(
      size: PdfPoint(layout.width, layout.height),
      painter: (canvas, size) {
        // قماش PDF أصله أسفل-يسار وY صاعد، بينما التخطيط بأسلوب Flutter
        // (الأصل أعلى وY نازل) → نقلب المحور الرأسي قبل الرسم.
        final h = size.y;
        double py(double y) => h - y;

        // توهج خفيف خلف عقدة الجذر بلون الفرع
        _LayoutNode? hero;
        for (final l in layout.nodes) {
          if (l.depth == 0) {
            hero = l;
            break;
          }
        }
        if (hero != null) {
          final hx = hero.x;
          final hy = py(hero.y + hero.cardH / 2);
          for (var i = 3; i >= 1; i--) {
            final r = 46.0 + (3 - i) * 22.0;
            canvas.setFillColor(_mix(bg, hero.color, 0.05 * (4 - i)));
            canvas.drawEllipse(hx, hy, r, r);
          }
        }

        // الحواف: بيزيه مكعب مستقل لكل أب → ابن (مروّح بشكل أورجانيك)
        for (final e in layout.edges) {
          final edgeColor = _mix(bg, e.parent.color, 0.55);
          canvas
            ..setStrokeColor(edgeColor)
            ..setLineWidth(1.5)
            ..moveTo(e.x1, py(e.y1))
            ..curveTo(e.x2, py(e.y2), e.x3, py(e.y3), e.x4, py(e.y4))
            ..strokePath();
        }

        // حلقة المحور أسفل كل أب له أبناء (ظل ثم مركز بلون الفرع)
        for (final ln in layout.nodes) {
          if ((layout.byParent[ln.node.id] ?? const []).isEmpty) continue;
          final ax = ln.x;
          final ay = py(ln.y + ln.cardH + _kAnchorGap);
          canvas.setFillColor(_mix(bg, ln.color, 0.28));
          canvas.drawEllipse(ax, ay, 5.4, 5.4);
          canvas.setFillColor(ln.color);
          canvas.drawEllipse(ax, ay, 3.2, 3.2);
        }

        // نقاط الاتصال أعلى كل ابن
        for (final ln in layout.nodes) {
          if (ln.depth == 0) continue;
          final ax = ln.x;
          final ay = py(ln.y - _kAnchorGap);
          canvas.setFillColor(_mix(bg, ln.color, 0.35));
          canvas.drawEllipse(ax, ay, 4.4, 4.4);
          canvas.setFillColor(ln.color);
          canvas.drawEllipse(ax, ay, 2.3, 2.3);
        }
      },
    );

    final cards = <pw.Widget>[];
    for (final ln in layout.nodes) {
      cards.add(pw.Positioned(
        left: ln.x - ln.cardW / 2,
        top: ln.y,
        child: _nodeCard(
          ln: ln,
          white: white,
          bg: bg,
          muted: muted,
          danger: danger,
          reg: reg,
          bold: bold,
          nf: nf,
          fontScale: max(0.8, layout.scale),
        ),
      ));
    }

    return pw.SizedBox(
      width: layout.width,
      height: layout.height,
      child: pw.Stack(children: [painter, ...cards]),
    );
  }

  static pw.Widget _nodeCard({
    required _LayoutNode ln,
    required PdfColor white,
    required PdfColor bg,
    required PdfColor muted,
    required PdfColor danger,
    required pw.Font reg,
    required pw.Font bold,
    required NumberFormat nf,
    required double fontScale,
  }) {
    final n = ln.node;
    final c = ln.color;
    final isHero = ln.depth == 0;
    final name = n.name.trim().isEmpty ? (isHero ? '—' : '') : n.name.trim();
    final amount = nf.format(n.amount);
    final cur = n.currency.trim();
    final padX = isHero ? 14.0 : 10.0;
    final padY = isHero ? 12.0 : 9.0;
    final innerW = ln.cardW - padX * 2;

    // المبالغ السالبة (مصروف/دين/التزام) بلون الخطر مثل التطبيق
    final amountColor = (n.type == FinancialTreeNodeType.expense ||
            n.type == FinancialTreeNodeType.debt ||
            n.type == FinancialTreeNodeType.liability)
        ? danger
        : white;

    // هرمية بصرية: الجذر الأكبر، الفئات أوسط، الأوراق الأصغر
    final baseValue = isHero ? 17.0 : (ln.depth == 1 ? 12.0 : 11.0);
    final minValue = isHero ? 12.0 : 8.0;
    final baseName = isHero ? 13.0 : (ln.depth == 1 ? 9.5 : 8.5);
    final minName = isHero ? 10.0 : 7.0;
    final curSize = isHero ? 8.5 : (ln.depth == 1 ? 7.5 : 7.0);

    final valueSize = _fitSize(amount, innerW, baseValue * fontScale, minValue * fontScale);
    final nameSize = _fitSize(name, innerW, baseName * fontScale, minName * fontScale);

    return pw.Container(
      width: ln.cardW,
      height: ln.cardH,
      padding: pw.EdgeInsets.symmetric(horizontal: padX, vertical: padY),
      decoration: pw.BoxDecoration(
        color: _mix(bg, c, isHero ? 0.15 : 0.07),
        borderRadius: pw.BorderRadius.circular(isHero ? 18 : 13),
        border: pw.Border.all(
          color: isHero ? _mix(c, white, 0.35) : _mix(bg, c, 0.6),
          width: isHero ? 2 : 1.3,
        ),
        boxShadow: [
          if (isHero)
            pw.BoxShadow(color: _mix(bg, c, 0.35), blurRadius: 14, spreadRadius: 2),
        ],
      ),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Text(name,
              maxLines: 1,
              style: pw.TextStyle(font: bold, fontSize: nameSize, color: white)),
          pw.SizedBox(height: isHero ? 5 : 4),
          pw.Text(amount,
              maxLines: 1,
              style: pw.TextStyle(font: bold, fontSize: valueSize, color: amountColor)),
          if (cur.isNotEmpty) ...[
            pw.SizedBox(height: 1),
            pw.Text(cur,
                maxLines: 1,
                style: pw.TextStyle(
                    font: reg,
                    fontSize: curSize * fontScale,
                    color: muted)),
          ],
        ],
      ),
    );
  }

  // ── ملخص الأداء (بيانات محسوبة فعلياً) ──

  static pw.Widget _summaryDashboard({
    required TreeComputation comp,
    required String cur,
    required NumberFormat nf,
    required PdfColor brand,
    required PdfColor white,
    required PdfColor muted,
    required PdfColor panel,
    required PdfColor panelBorder,
    required pw.Font reg,
    required pw.Font bold,
    Map<String, String>? translations,
    required double valueMaxW,
  }) {
    final netFlow = (comp.cashIn != 0 || comp.cashOut != 0)
        ? comp.cashIn - comp.cashOut
        : comp.totalIncome - comp.totalExpenses;
    final income = comp.totalIncome;
    final savingsRate = income > 0 ? comp.totalSavings / income : null;
    final expenseRate = income > 0 ? comp.totalExpenses / income : null;
    final investRate = income > 0 ? comp.totalInvestments / income : null;
    final pct = NumberFormat('#,##0.#');

    pw.Widget metric(String title, String value, PdfColor accent) {
      final valueSize = _fitSize(value, valueMaxW, 13.0, 9.0);
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: pw.BoxDecoration(
          color: _mix(panel, accent, 0.06),
          borderRadius: pw.BorderRadius.circular(14),
          border: pw.Border.all(color: _mix(panelBorder, accent, 0.35), width: 1),
        ),
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.center,
              children: [
                pw.Container(
                  width: 7,
                  height: 7,
                  decoration: pw.BoxDecoration(color: accent, shape: pw.BoxShape.circle),
                ),
                pw.SizedBox(width: 6),
                pw.Text(title, style: pw.TextStyle(font: reg, fontSize: 9, color: muted)),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Text(value, style: pw.TextStyle(font: bold, fontSize: valueSize, color: white)),
          ],
        ),
      );
    }

    final cards = <pw.Widget>[
      metric(
        _tr(translations, 'netFlow', 'صافي التدفق'),
        '${nf.format(netFlow)}$cur'.trim(),
        netFlow >= 0 ? _c(0xFF22C55E) : _c(0xFFEF4444),
      ),
      metric(
        _tr(translations, 'savingsRate', 'معدل الادخار'),
        savingsRate == null ? '—' : '${pct.format(savingsRate * 100)}%',
        _c(0xFF3B82F6),
      ),
      metric(
        _tr(translations, 'expenseRate', 'نسبة المصروفات'),
        expenseRate == null ? '—' : '${pct.format(expenseRate * 100)}%',
        _c(0xFF8B5CF6),
      ),
      metric(
        _tr(translations, 'investRate', 'نسبة الاستثمارات'),
        investRate == null ? '—' : '${pct.format(investRate * 100)}%',
        _c(0xFF22C55E),
      ),
    ];

    final row = <pw.Widget>[];
    for (var i = 0; i < cards.length; i++) {
      row.add(pw.Expanded(child: cards[i]));
      if (i < cards.length - 1) {
        row.add(pw.SizedBox(width: 12));
      }
    }

    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Container(
              width: 26,
              height: 2,
              decoration: pw.BoxDecoration(color: brand, borderRadius: pw.BorderRadius.circular(1)),
            ),
            pw.SizedBox(width: 8),
            pw.Text(_tr(translations, 'summarySection', 'ملخص الأداء'),
                style: pw.TextStyle(font: bold, fontSize: 11.5, color: white)),
            pw.SizedBox(width: 8),
            pw.Container(
              width: 26,
              height: 2,
              decoration: pw.BoxDecoration(color: brand, borderRadius: pw.BorderRadius.circular(1)),
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        pw.Row(children: row),
      ],
    );
  }

  static pw.Widget _kpiGrid(
    TreeComputation comp,
    String cur,
    NumberFormat nf,
    pw.Font reg,
    pw.Font bold,
    PdfColor txtColor,
    PdfColor subColor,
    PdfColor successColor,
    PdfColor dangerColor,
    PdfColor amountColor,
    PdfColor pColor,
    Map<String, String>? translations,
  ) {
    final netColor = comp.netWorth >= 0 ? successColor : dangerColor;
    final availableColor = comp.available >= 0 ? successColor : dangerColor;
    final items = <pw.Widget>[];
    pw.Widget item(String key, String fallback, double value, PdfColor color) {
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(_tr(translations, key, fallback), style: pw.TextStyle(font: reg, fontSize: fsSmall, color: subColor)),
            pw.SizedBox(height: 3),
            pw.Text('${nf.format(value)}$cur', style: pw.TextStyle(font: bold, fontSize: fsBody, color: color)),
          ],
        ),
      );
    }

    items.add(item('totalAssets', 'إجمالي الأصول', comp.totalAssets, amountColor));
    items.add(item('totalIncome', 'إجمالي الدخل', comp.totalIncome, successColor));
    items.add(item('totalExpenses', 'إجمالي المصروفات', comp.totalExpenses, dangerColor));
    items.add(item('totalInvestments', 'إجمالي الاستثمارات', comp.totalInvestments, pColor));
    items.add(item('totalReceivable', 'ديون لي', comp.totalReceivable, successColor));
    items.add(item('totalPayable', 'ديون مستحقة', comp.totalPayable, dangerColor));
    items.add(item('totalPaidLabel', 'إجمالي المدفوع', comp.totalPaid, amountColor));
    items.add(item('totalRemainingLabel', 'إجمالي المتبقي', comp.totalRemaining, subColor));
    items.add(item('availableBalance', 'الرصيد المتاح', comp.available, availableColor));
    items.add(item('netWorth', 'صافي الثروة', comp.netWorth, netColor));

    final grid = <pw.Widget>[];
    for (var i = 0; i < items.length; i += 5) {
      final row = items.sublist(i, i + 5 > items.length ? items.length : i + 5);
      final cells = <pw.Widget>[];
      for (var j = 0; j < row.length; j++) {
        cells.add(pw.Expanded(child: row[j]));
        if (j < row.length - 1) {
          cells.add(pw.Container(width: 0.5, height: 34, color: const PdfColor.fromInt(0xFF333333)));
        }
      }
      grid.add(pw.Container(
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF2A2A2A), width: 0.5))),
        child: pw.Row(children: cells),
      ));
    }
    return pw.Column(children: grid);
  }

  static pw.Widget _distributionBars(
    TreeComputation comp,
    NumberFormat nf,
    pw.Font reg,
    pw.Font bold,
    PdfColor txtColor,
    PdfColor subColor,
    Map<String, String>? translations,
  ) {
    final entries = comp.chartDistribution.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) {
      return pw.Text('—', style: pw.TextStyle(font: reg, fontSize: fsBody, color: subColor));
    }
    final max = entries.first.value > 0 ? entries.first.value : 1;
    return pw.Column(
      children: entries.map((e) {
        final type = FinancialTreeNodeType.fromId(e.key);
        final color = _c(type.color);
        final width = 300 * (e.value / max);
        return pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 5),
          child: pw.Row(
            children: [
              pw.Container(width: 90, child: pw.Text(_typeLabel(type, translations), style: pw.TextStyle(font: reg, fontSize: fsSmall, color: subColor))),
              pw.Expanded(
                child: pw.Container(
                  height: 12,
                  decoration: pw.BoxDecoration(color: const PdfColor.fromInt(0xFF222222), borderRadius: pw.BorderRadius.circular(3)),
                  child: pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Container(
                      width: width,
                      height: 12,
                      decoration: pw.BoxDecoration(color: color, borderRadius: pw.BorderRadius.circular(3)),
                    ),
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Text(nf.format(e.value), style: pw.TextStyle(font: bold, fontSize: fsSmall, color: txtColor)),
            ],
          ),
        );
      }).toList(),
    );
  }

  static pw.Widget _buildFooter(ReceiptDesignPreset preset, pw.Font reg, PdfColor subColor, [Map<String, String>? translations, String? dateStr]) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(preset.footerText.isNotEmpty ? preset.footerText : 'FYONA', style: pw.TextStyle(font: reg, fontSize: fsBody, color: const PdfColor.fromInt(0xFF666666))),
        pw.Text('${_tr(translations, 'exportedOn', 'تم التصدير')}: ${dateStr ?? ''}', style: pw.TextStyle(font: reg, fontSize: fsBody, color: const PdfColor.fromInt(0xFF666666))),
      ],
    );
  }
}

/// عقدة تخطيط داخل خريطة الشجرة.
class _LayoutNode {
  final FinancialTreeNode node;
  double x; // مركز البطاقة (إحداثيات Flutter: الأصل أعلى وY نازل)
  double y; // أعلى البطاقة
  final int depth;
  final PdfColor color; // لون الفرع
  double cardW;
  double cardH;
  _LayoutNode(this.node, this.x, this.y, this.depth, this.color, this.cardW, this.cardH);
}

/// حافة (وصلة) بين أب وابنه: بيزيه مكعب بإحداثيات Flutter.
class _TreeEdge {
  final _LayoutNode parent;
  final _LayoutNode child;
  final double x1, y1, x2, y2, x3, y3, x4, y4;
  _TreeEdge(this.parent, this.child, this.x1, this.y1, this.x2, this.y2, this.x3, this.y3, this.x4, this.y4);
}

/// نتيجة التخطيط الكامل للشجرة.
class _TreeLayout {
  final List<_LayoutNode> nodes;
  final Map<String, _LayoutNode> byId;
  final List<_TreeEdge> edges;
  final Map<String?, List<FinancialTreeNode>> byParent;
  final double width;
  final double height;
  final double scale; // معامل الضغط النسبي (1.0، أو أقل عند الأشجار الضخمة)
  _TreeLayout(this.nodes, this.byId, this.edges, this.byParent, this.width, this.height, this.scale);
}
