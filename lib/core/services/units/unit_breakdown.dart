class UnitBreakdownInput {
  final String name;
  final double factor;
  final String group;
  const UnitBreakdownInput({
    required this.name,
    required this.factor,
    required this.group,
  });
}

class UnitBreakdownPart {
  final String name;
  final double qty;
  final double factor;
  const UnitBreakdownPart({
    required this.name,
    required this.qty,
    required this.factor,
  });
}

/// Greedy whole-unit decomposition for indivisible count units.
/// Example: 99 pieces with pack=8, carton=64 →
/// 1 carton + 4 packs + 3 pieces.
List<UnitBreakdownPart> decomposeCountUnits(
  double base,
  List<UnitBreakdownInput> units, {
  double? fromFactor,
}) {
  if (!base.isFinite || base <= 0) return const [];
  final sorted = [...units]
    ..sort((a, b) => b.factor.compareTo(a.factor));
  final unique = <double, UnitBreakdownInput>{};
  for (final u in sorted) {
    if (u.factor <= 0 || !u.factor.isFinite) continue;
    if (!unique.containsKey(u.factor)) unique[u.factor] = u;
  }
  final list = unique.values.toList()
    ..sort((a, b) => b.factor.compareTo(a.factor));
  if (list.isEmpty) return const [];
  if (list.every((u) => u.group != 'count')) return const [];
  var remaining = base;
  final out = <UnitBreakdownPart>[];
  var started = fromFactor == null;
  for (final u in list) {
    if (!started) {
      if (u.factor <= fromFactor! + 1e-9) started = true;
      if (!started) continue;
    }
    final whole = (remaining / u.factor + 1e-9).floorToDouble();
    if (whole <= 0) continue;
    out.add(UnitBreakdownPart(name: u.name, qty: whole, factor: u.factor));
    remaining -= whole * u.factor;
    if (remaining.abs() < 1e-9) {
      remaining = 0;
      break;
    }
  }
  if (remaining > 1e-9) {
    final one = unique[1.0];
    if (one != null) {
      final idx = out.indexWhere((p) => p.factor == 1.0);
      if (idx >= 0) {
        final p = out[idx];
        out[idx] = UnitBreakdownPart(
            name: p.name, qty: p.qty + remaining, factor: 1);
      } else {
        out.add(UnitBreakdownPart(
            name: one.name, qty: remaining, factor: 1));
      }
    }
  }
  return out;
}

String formatUnitBreakdown(List<UnitBreakdownPart> parts) {
  return [
    for (final p in parts)
      '${_fmt(p.qty)} ${p.name}'.trim(),
  ].join(' + ');
}

String _fmt(double v) {
  if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
  return v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}
