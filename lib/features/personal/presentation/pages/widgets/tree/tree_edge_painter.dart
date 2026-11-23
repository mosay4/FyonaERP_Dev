import 'package:flutter/material.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import 'tree_node_card.dart';

/// Premium edge painter with smooth cubic bezier connectors.
class TreeEdgePainter extends CustomPainter {
  final Map<String, Offset> positions;
  final List<FinancialTreeNode> nodes;

  TreeEdgePainter({required this.positions, required this.nodes});

  @override
  void paint(Canvas canvas, Size size) {
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    final dotPaint = Paint()
      ..style = PaintingStyle.fill;

    final nodeById = {for (final n in nodes) n.id: n};

    for (final n in nodes) {
      if (n.isRoot) continue;
      final parentPos = positions[n.parentId];
      final childPos = positions[n.id];
      if (parentPos == null || childPos == null) continue;

      final parentColor = Color((nodeById[n.parentId]?.type ?? FinancialTreeNodeType.custom).color);
      final childColor = Color(n.type.color);

      final start = Offset(
        parentPos.dx + TreeNodeCard.cardWidth / 2,
        parentPos.dy + TreeNodeCard.cardHeight,
      );
      final end = Offset(
        childPos.dx + TreeNodeCard.cardWidth / 2,
        childPos.dy,
      );

      final midY = (start.dy + end.dy) / 2;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx, midY, end.dx, midY, end.dx, end.dy);

      // Glow effect
      glowPaint.color = parentColor.withAlpha(30);
      canvas.drawPath(path, glowPaint);

      // Main line with gradient-like effect
      linePaint.color = parentColor.withAlpha(140);
      canvas.drawPath(path, linePaint);

      // Endpoint dot
      dotPaint.color = childColor;
      canvas.drawCircle(end, 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant TreeEdgePainter oldDelegate) =>
      oldDelegate.positions != positions || oldDelegate.nodes != nodes;
}
