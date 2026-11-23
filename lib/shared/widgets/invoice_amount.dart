import 'package:flutter/material.dart';

/// Keeps the entire value inside its allocated column, including in RTL.
class InvoiceAmount extends StatelessWidget {
  final String value;
  final TextStyle? style;
  final AlignmentGeometry alignment;
  const InvoiceAmount(this.value,
      {super.key, this.style, this.alignment = Alignment.center});

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: Text(value, maxLines: 1, style: style,
            textDirection: TextDirection.ltr, textAlign: TextAlign.center),
      );
}
