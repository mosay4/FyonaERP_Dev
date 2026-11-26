import 'dart:async';

import 'package:flutter/material.dart';
import 'business_number_field.dart';

import '../../../../core/responsive/r_api.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/theme/app_colors.dart';

String _fmtQty(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

/// Quantity field with two steppers: (+) on the RIGHT and (−) on the LEFT
/// (the Row is RTL). Typing stays possible in the middle field.
class QtyStepper extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const QtyStepper({super.key, required this.value, required this.onChanged});
  @override
  State<QtyStepper> createState() => _QtyStepperState();
}

class _QtyStepperState extends State<QtyStepper> {
  late final TextEditingController _ctrl =
      TextEditingController(text: _fmtQty(widget.value));
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QtyStepper old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) {
      final current = double.tryParse(_ctrl.text.trim());
      if (current == null || (current - widget.value).abs() > 0.0001) {
        _ctrl.text = _fmtQty(widget.value);
      }
    }
  }

  void _apply(double v) {
    if (v <= 0) return;
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // RTL: the first child is on the RIGHT → plus is on the right.
        IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: () => _apply(widget.value + 1),
          icon: const Icon(Icons.add, size: 16),
        ),
        SizedBox(
          width: 42,
          child: BusinessNumberField(
            controller: _ctrl,
            focusNode: _focus,
            textAlign: TextAlign.center,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                fontWeight: FontWeight.w700),
            decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero),
            onChanged: (v) {
              final parsed = double.tryParse(v.trim());
              if (parsed != null && parsed > 0) _apply(parsed);
            },
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: () => _apply(
              widget.value - 1 < 0.001 ? widget.value : widget.value - 1),
          icon: const Icon(Icons.remove, size: 16),
        ),
      ]),
    );
  }
}

/// Editable number whose font SHRINKS as digits grow, so long amounts stay
/// fully visible inside the fixed field width.
class AutoNumField extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  const AutoNumField(
      {super.key,
      required this.label,
      required this.value,
      required this.onChanged});
  @override
  State<AutoNumField> createState() => _AutoNumFieldState();
}

class _AutoNumFieldState extends State<AutoNumField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: fmtNum(widget.value));
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AutoNumField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) {
      final current = parseFormattedAmount(_ctrl.text);
      if (current == null || (current - widget.value).abs() > 0.0001) {
        _ctrl.text = fmtNum(widget.value);
      }
    }
  }

  double _fontSize(int len) {
    if (len <= 8) return 12.5;
    if (len <= 11) return 11.5;
    if (len <= 14) return 10.5;
    if (len <= 18) return 9.5;
    return 8.5;
  }

  @override
  Widget build(BuildContext context) {
    return BusinessNumberField(
      formField: true,
      controller: _ctrl,
      focusNode: _focus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AmountInputFormatter()],
      textAlign: TextAlign.center,
      style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: _fontSize(_ctrl.text.length),
          fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: TextStyle(fontSize: R.fontSize(context, 10.5)),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onChanged: (v) {
        setState(() {});
        widget.onChanged(parseFormattedAmount(v) ?? 0);
      },
    );
  }
}

/// Unit field: shows the FULL unit name (scaled down if long) and the
/// dropdown arrow ONLY when the product really has more than one unit.
/// With a single unit it is forced and not clickable.
class UnitLineField extends StatefulWidget {
  final String label;
  final String value;
  final String? productId;
  final Future<int> Function()? loadUnitCount;
  final VoidCallback? onTap;
  const UnitLineField({
    super.key,
    required this.label,
    required this.value,
    this.productId,
    this.loadUnitCount,
    this.onTap,
  });
  @override
  State<UnitLineField> createState() => _UnitLineFieldState();
}

class _UnitLineFieldState extends State<UnitLineField> {
  /// Short-lived: units added to a product (Inventory) must show in the
  /// next invoice at once — a count cached for the app's lifetime kept a
  /// product at «قطعة» only until a restart.
  static final Map<String, (int, DateTime)> _countCache = {};
  static const _ttl = Duration(seconds: 15);
  int? _count;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant UnitLineField old) {
    super.didUpdateWidget(old);
    if (old.productId != widget.productId) _load();
  }

  Future<void> _load() async {
    final pid = widget.productId;
    if (pid == null || pid.isEmpty || widget.loadUnitCount == null) {
      setState(() => _count = 1);
      return;
    }
    final hit = _countCache[pid];
    if (hit != null && DateTime.now().difference(hit.$2) < _ttl) {
      setState(() => _count = hit.$1);
      return;
    }
    try {
      final n = await widget.loadUnitCount!();
      _countCache[pid] = (n, DateTime.now());
      if (mounted) setState(() => _count = n);
    } catch (_) {
      if (mounted) setState(() => _count = 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final multiple = (_count ?? 0) > 1;
    final child = InputDecorator(
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: TextStyle(fontSize: R.fontSize(context, 10.5)),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(children: [
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(widget.value,
                maxLines: 1,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w600)),
          ),
        ),
        if (multiple)
          const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
      ]),
    );
    // A product line is always tappable: its units are read fresh on tap
    // (the count shown here may predate units added a moment ago).
    final pid = widget.productId;
    if (widget.onTap == null || pid == null || pid.isEmpty) return child;
    return InkWell(
      onTap: () {
        _countCache.remove(pid);
        unawaited(_load());
        widget.onTap!();
      },
      borderRadius: BorderRadius.circular(10),
      child: child,
    );
  }
}
