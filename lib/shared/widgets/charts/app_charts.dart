import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/currency_formatter.dart';

const appChartColors = [
  Color(0xFFA01530),
  Color(0xFFB82040),
  Color(0xFF7A1020),
  Color(0xFFD4A373),
  Color(0xFF6C9BCF),
  Color(0xFF77DD77),
  Color(0xFFFFB347),
  Color(0xFFCB99C9),
  Color(0xFF00838F),
  Color(0xFF4E342E),
];

// ════════════════════════════════════════════════════════════
//  GROUPED BAR CHART (Income vs Expense per month)
// ════════════════════════════════════════════════════════════
class GroupedBarChart extends StatelessWidget {
  final List<String> labels;
  final List<double> incomeData;
  final List<double> expenseData;
  final double? height;

  const GroupedBarChart({
    super.key,
    required this.labels,
    required this.incomeData,
    required this.expenseData,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final maxY = [...incomeData, ...expenseData].fold(0.0, (a, b) => b > a ? b : a);
    final topY = maxY > 0 ? maxY * 1.2 : 100.0;

    return Container(
      height: height ?? 220,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: BarChart(BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: topY,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final label = rodIndex == 0 ? AppLocalizations.of(context).translate('income') : AppLocalizations.of(context).translate('expense');
              return BarTooltipItem(
                '$label\n${fmtNum(rod.toY)}',
                TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= labels.length) return SizedBox.shrink();
              return Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(labels[i], style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textDisabled)),
              );
            },
          )),
          leftTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            getTitlesWidget: (v, _) => Text(fmtNum(v), style: TextStyle(fontFamily: 'Cairo', fontSize: 8, color: AppColors.textDisabled)),
          )),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: topY / 4,
          getDrawingHorizontalLine: (v) => FlLine(color: AppColors.border, strokeWidth: 0.5),
        ),
        borderData: FlBorderData(show: false),
        barGroups: List.generate(labels.length, (i) {
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: i < incomeData.length ? incomeData[i] : 0,
                color: AppColors.success,
                width: 12,
                borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
              ),
              BarChartRodData(
                toY: i < expenseData.length ? expenseData[i] : 0,
                color: AppColors.danger,
                width: 12,
                borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
              ),
            ],
          );
        }),
      )),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  HORIZONTAL BAR CHART (Categories)
// ════════════════════════════════════════════════════════════
class HorizontalBarChart extends StatelessWidget {
  final List<MapEntry<String, double>> data;
  final int maxItems;
  final double? height;

  const HorizontalBarChart({
    super.key,
    required this.data,
    this.maxItems = 6,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final items = data.take(maxItems).toList();
    final maxY = items.isNotEmpty ? items.first.value : 1.0;

    return Container(
      height: height ?? (items.length * 40.0 + 32),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: BarChart(BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY * 1.15,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final name = items[group.x.toInt()].key;
              return BarTooltipItem(
                '$name\n${fmtNum(rod.toY)}',
                TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 60,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= items.length) return SizedBox.shrink();
              return Text(items[i].key, style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis);
            },
          )),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(color: AppColors.border, strokeWidth: 0.3),
        ),
        borderData: FlBorderData(show: false),
        barGroups: List.generate(items.length, (i) {
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: items[i].value,
                color: appChartColors[i % appChartColors.length],
                width: 16,
                borderRadius: BorderRadius.horizontal(right: Radius.circular(6)),
              ),
            ],
          );
        }),
      )),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  PIE CHART (Distribution)
// ════════════════════════════════════════════════════════════
class AppPieChart extends StatelessWidget {
  final List<MapEntry<String, double>> data;
  final double? height;
  final bool showCenter;

  const AppPieChart({
    super.key,
    required this.data,
    this.height,
    this.showCenter = true,
  });

  @override
  Widget build(BuildContext context) {
    final total = data.fold(0.0, (s, e) => s + e.value);
    if (total == 0) return SizedBox.shrink();

    return Container(
      height: height ?? 240,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: PieChart(PieChartData(
              centerSpaceRadius: showCenter ? 36 : 0,
              sectionsSpace: 2,
              sections: List.generate(data.length, (i) {
                final pct = (data[i].value / total * 100);
                return PieChartSectionData(
                  value: data[i].value,
                  title: pct >= 8 ? '${pct.toStringAsFixed(0)}%' : '',
                  color: appChartColors[i % appChartColors.length],
                  radius: 60,
                  titleStyle: TextStyle(fontFamily: 'Cairo', fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
                );
              }),
            )),
          ),
          SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: data.take(5).toList().asMap().entries.map((e) {
                final i = e.key;
                final item = e.value;
                final pct = (item.value / total * 100).toStringAsFixed(1);
                return Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: appChartColors[i % appChartColors.length], borderRadius: BorderRadius.circular(3))),
                    SizedBox(width: 6),
                    Expanded(child: Text(item.key, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
                    Text('$pct%', style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textDisabled)),
                  ]),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  LINE CHART (Trends)
// ════════════════════════════════════════════════════════════
class AppLineChart extends StatelessWidget {
  final List<String> labels;
  final List<double> data;
  final Color? lineColor;
  final double? height;
  final String? label;

  const AppLineChart({
    super.key,
    required this.labels,
    required this.data,
    this.lineColor,
    this.height,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final color = lineColor ?? AppColors.primary;
    final maxY = data.fold(0.0, (a, b) => b > a ? b : a);
    final topY = maxY > 0 ? maxY * 1.25 : 100.0;

    return Container(
      height: height ?? 200,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(label!, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            SizedBox(height: 8),
          ],
          Expanded(
            child: LineChart(LineChartData(
              maxY: topY,
              minY: 0,
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((s) => LineTooltipItem(
                    fmtNum(s.y),
                    TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                  )).toList(),
                ),
              ),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 24,
                  interval: (labels.length / 6).ceilToDouble().clamp(1, double.infinity),
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
                    if (i < 0 || i >= labels.length) return SizedBox.shrink();
                    return Text(labels[i], style: TextStyle(fontFamily: 'Cairo', fontSize: 8, color: AppColors.textDisabled));
                  },
                )),
                leftTitles: AxisTitles(sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 32,
                  getTitlesWidget: (v, _) => Text(fmtNum(v), style: TextStyle(fontFamily: 'Cairo', fontSize: 8, color: AppColors.textDisabled)),
                )),
                topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (v) => FlLine(color: AppColors.border, strokeWidth: 0.3),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: List.generate(data.length, (i) => FlSpot(i.toDouble(), data[i])),
                  isCurved: true,
                  curveSmoothness: 0.3,
                  color: color,
                  barWidth: 2.5,
                  isStrokeCapRound: true,
                  dotData: FlDotData(
                    show: data.length <= 14,
                    getDotPainter: (spot, pct, bar, idx) => FlDotCirclePainter(
                      radius: 3,
                      color: color,
                      strokeWidth: 1.5,
                      strokeColor: AppColors.surface,
                    ),
                  ),
                  belowBarData: BarAreaData(
                    show: true,
                    color: color.withAlpha(25),
                  ),
                ),
              ],
            )),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  DONUT CHART (Savings ratio)
// ════════════════════════════════════════════════════════════
class AppDonutChart extends StatelessWidget {
  final double value;
  final double max;
  final String centerLabel;
  final Color? color;
  final double? size;

  const AppDonutChart({
    super.key,
    required this.value,
    required this.max,
    required this.centerLabel,
    this.color,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primary;
    final pct = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;

    return Container(
      width: size ?? 140,
      height: size ?? 140,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PieChart(PieChartData(
            centerSpaceRadius: (size ?? 140) / 2 - 12,
            sectionsSpace: 0,
            sections: [
              PieChartSectionData(
                value: pct * 100,
                color: c,
                radius: 10,
                title: '',
              ),
              PieChartSectionData(
                value: (1 - pct) * 100,
                color: AppColors.border,
                radius: 10,
                title: '',
              ),
            ],
          )),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(centerLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              SizedBox(height: 2),
              Text('${(pct * 100).toStringAsFixed(0)}%', style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textDisabled)),
            ],
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  CHART LEGEND (Reusable)
// ════════════════════════════════════════════════════════════
class AppChartLegend extends StatelessWidget {
  final List<MapEntry<String, Color>> items;

  const AppChartLegend({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: items.map((e) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: e.value, borderRadius: BorderRadius.circular(3))),
          SizedBox(width: 4),
          Text(e.key, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
        ],
      )).toList(),
    );
  }
}
