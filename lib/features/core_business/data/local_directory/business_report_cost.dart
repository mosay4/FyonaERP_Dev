part of 'directory_database.dart';

/// Read the writer's sale allocations, in reverse consumption order for
/// restorations. No lot is consumed, repriced or restored by this projection.
Future<void> _reportSaleCosts(
  DatabaseExecutor db,
  String branch,
  _SalesReportWindow window,
  _ReportAmounts costs,
) async {
  final selected =
      '''
    WITH items AS (
      SELECT l.id, l.branch_id, l.product_id, l.quantity_micro, l.base_micro,
        l.factor_4, l.cost_total_minor, l.price_currency, l.exchange_rate,
        i.id AS invoice_id, i.idempotency_key, i.currency, i.date, i.created_us
      FROM $_commerceLines l JOIN $_commerceInvoices i
        ON i.branch_id = l.branch_id AND i.id = l.invoice_id
      WHERE i.branch_id = ? AND $_reportInvoicePosted AND i.invoice_type = 'sale'
        AND l.is_service = 0
        AND ((1 = 1 ${window.dateWhere('i.date')}) OR EXISTS (
          SELECT 1 FROM $_commerceReturnLines t JOIN $_commerceReturns r
            ON r.branch_id = t.branch_id AND r.id = t.return_id
          WHERE t.branch_id = l.branch_id AND t.item_id = l.id
            AND r.status = 'confirmed' ${window.dateWhere('r.date')}
        ))
    )
  ''';
  final args = [branch, ...window.dateArgs, ...window.dateArgs];
  final items = {
    for (final row in await db.rawQuery('$selected SELECT * FROM items', args))
      row['id'] as String: _ReportCostItem(row),
  };
  if (items.isEmpty) return;

  for (final row in await db.rawQuery('''
    $selected
    SELECT c.item_id, c.created_us, c.quantity_micro, c.restored_micro,
      c.unit_cost_4, c.currency, lot.source
    FROM items l JOIN $_commerceConsumptions c
      ON c.branch_id = l.branch_id AND c.item_id = l.id
    JOIN $_commerceLots lot ON lot.branch_id = c.branch_id AND lot.id = c.lot_id
    ORDER BY c.created_us DESC, c.rowid DESC
    ''', args)) {
    items[row['item_id']]!.slices.add(_ReportCostSlice(row));
  }
  for (final row in await db.rawQuery('''
    $selected
    SELECT e.item_id, e.old_quantity_micro, e.new_quantity_micro, e.created_us
    FROM items l JOIN $_commerceEdits e
      ON e.branch_id = l.branch_id AND e.item_id = l.id
    WHERE e.old_quantity_micro IS NOT NULL AND e.new_quantity_micro IS NOT NULL
    ORDER BY e.created_us, e.rowid
    ''', args)) {
    items[row['item_id']]!.edits.add(row);
  }
  final movements = <(String, String), List<_CommerceRow>>{};
  for (final row in await db.rawQuery('''
    $selected
    SELECT t.item_id, r.id AS return_id, r.date, r.created_us, t.quantity_micro AS returned_micro,
      m.id AS movement_id, m.movement_type, m.quantity_micro,
      (SELECT COUNT(*) FROM $_commerceReturnLines p
        WHERE p.branch_id = t.branch_id AND p.return_id = t.return_id
          AND p.product_id = t.product_id) AS product_lines
    FROM items l JOIN $_commerceReturnLines t
      ON t.branch_id = l.branch_id AND t.item_id = l.id
    JOIN $_commerceReturns r ON r.branch_id = t.branch_id AND r.id = t.return_id
    LEFT JOIN $_commerceMovements m
      ON m.branch_id = r.branch_id AND m.reference_id = r.id
        AND m.product_id = t.product_id AND m.reference_type = 'invoice_return'
        AND m.movement_type IN ('sale_return','sale_return_no_stock')
    WHERE r.status = 'confirmed'
    ORDER BY r.created_us, r.rowid
    ''', args)) {
    final key = (row['item_id'] as String, row['return_id'] as String);
    (movements[key] ??= []).add(row);
  }
  for (final entry in movements.entries) {
    final (item, returned) = entry.key;
    final id = const Uuid().v5(
      returned,
      'fyona.commerce.return.movement.v1:$item',
    );
    final row =
        entry.value.where((m) => m['movement_id'] == id).singleOrNull ??
        (entry.value.length == 1 && entry.value.single['product_lines'] == 1
            ? entry.value.single
            : null);
    items[item]!.returns.add(_ReportCostReturn(entry.value.first, row, id));
  }
  for (final item in items.values) {
    item.addTo(costs, window);
  }
}

final class _ReportCostSlice {
  _ReportCostSlice(this.row);
  final _CommerceRow row;
  int restored = 0;
  int get available => (row['quantity_micro'] as int) - restored;
  int get when => row['created_us'] as int;
  String? get currency => row['currency'] as String?;
  int get unitCost => row['unit_cost_4'] as int;
  bool get documented =>
      _reportDocumentedLotCost(currency, unitCost, row['source']);
}

final class _ReportCostReturn {
  const _ReportCostReturn(this.source, this.movement, this.localId);
  final _CommerceRow source;
  final _CommerceRow? movement;
  final String localId;
  String get day => source['date'] as String;
  int get when => source['created_us'] as int;
  bool get local => movement?['movement_id'] == localId;
}

typedef _CostPiece = (_ReportCostSlice slice, int quantity);

final class _ReportCostItem {
  _ReportCostItem(this.row);
  final _CommerceRow row;
  final slices = <_ReportCostSlice>[];
  final edits = <_CommerceRow>[];
  final returns = <_ReportCostReturn>[];

  String get code => row['currency'] as String;
  int get base => row['base_micro'] as int;
  int get at => _reportOperationUs(row);
  BusinessRate? get quote => _reportLineQuote(row, code);

  bool get local =>
      _reportLocalInvoice(row['idempotency_key'], row['invoice_id']);

  int _baseFor(int quantity) {
    final factor = row['factor_4'] as int?;
    return BusinessMoney.roundRatio(
      BigInt.from(quantity) * BigInt.from(factor ?? base),
      BigInt.from(factor == null ? row['quantity_micro'] as int : 10000),
    ).toInt();
  }

  List<_CostPiece>? _take(int count, int when) {
    if (count < 0) return null;
    final parts = <_CostPiece>[];
    for (final slice in slices) {
      if (count == 0) break;
      if (slice.when > when || slice.available <= 0) continue;
      final take = min(count, slice.available);
      slice.restored += take;
      count -= take;
      parts.add((slice, take));
    }
    return count == 0 ? parts : null;
  }

  static BigInt _quantity(Iterable<_CostPiece> parts) =>
      parts.fold(BigInt.zero, (sum, part) => sum + BigInt.from(part.$2));

  List<_CostPiece> get _outstanding => [
    for (final s in slices)
      if (s.available != 0) (s, s.available),
  ];

  BigInt? _costInInvoice(List<_CostPiece> parts) {
    var value = BigInt.zero;
    final frozen = quote;
    for (final (slice, qty) in parts) {
      if (!slice.documented) return null;
      final amount = BigInt.from(qty) * BigInt.from(slice.unitCost);
      if (slice.currency == code) {
        value += amount;
      } else if (frozen?.from == slice.currency) {
        value += frozen!.convertScaled(amount);
      } else {
        return null;
      }
    }
    return _reportMinor(value);
  }

  void _addPieces(
    _ReportAmounts costs,
    List<_CostPiece> parts, {
    required bool restoring,
  }) {
    for (final (slice, quantity) in parts) {
      if (!slice.documented) {
        costs.unclassified = true;
        continue;
      }
      costs.addPrecise(
        slice.currency!,
        BigInt.from(quantity) *
            BigInt.from(slice.unitCost) *
            (restoring ? -BigInt.one : BigInt.one),
        // Released COGS retains the basis of its original sale, not the
        // return day's market rate. Quantity edits may add later allocations.
        operationUs: local && edits.isNotEmpty ? max(at, slice.when) : at,
        frozen: quote,
      );
    }
  }

  void addTo(_ReportAmounts costs, _SalesReportWindow window) {
    if (costs.unclassified) return;
    final soldInWindow = window.includes(row['date'] as String);
    final isLocal = local;
    var completeIssue = isLocal || edits.isEmpty;
    if (isLocal) {
      for (final edit in edits) {
        final when = edit['created_us'] as int;
        if (returns.isNotEmpty && when > returns.first.when) {
          completeIssue = false;
          break;
        }
        final delta =
            _baseFor(edit['old_quantity_micro'] as int) -
            _baseFor(edit['new_quantity_micro'] as int);
        if (delta > 0 && _take(delta, when) == null) {
          completeIssue = false;
          break;
        }
      }
    }
    final issued = _outstanding;
    final exactIssue =
        completeIssue &&
        _quantity(issued) == BigInt.from(base) &&
        issued.every((p) => p.$1.documented);
    final recorded = row['cost_total_minor'] as int?;
    final calculated = exactIssue ? _costInInvoice(issued) : null;
    // A frozen archived cost may have been converted by the legacy writer;
    // recognize the stored cents, not a new conversion from the sale price.
    // Legacy placeholder zeros are not evidence of free inventory.
    final booked =
        recorded != null &&
            (recorded > 0 && (exactIssue || !isLocal && issued.isEmpty) ||
                recorded == 0 && calculated == BigInt.zero)
        ? BigInt.from(recorded)
        : null;
    final supportedBooked = booked != null && calculated == booked;
    if (soldInWindow) {
      if (booked != null) {
        costs.add(code, booked, operationUs: at, frozen: quote);
      } else if (exactIssue) {
        _addPieces(costs, issued, restoring: false);
      } else {
        costs.unclassified = true;
      }
    }
    if (!returns.any(
      (r) =>
          window.includes(r.day) &&
          r.movement?['movement_type'] != 'sale_return_no_stock',
    )) {
      return;
    }
    final allocations = <(_ReportCostReturn, List<_CostPiece>, BigInt?)>[];
    var provable = exactIssue;
    var stillBooked = booked;
    for (final ret in returns) {
      final movement = ret.movement;
      final qty = _baseFor(ret.source['returned_micro'] as int);
      if (movement == null || movement['quantity_micro'] != qty) {
        provable = false;
        break;
      }
      if (movement['movement_type'] == 'sale_return_no_stock') continue;
      if (!provable) break;
      if (qty == 0) continue;
      final parts = _take(qty, ret.when);
      if (parts == null) {
        provable = false;
        break;
      }
      // Imported slices are not accompanied by per-return allocations. A
      // single, unambiguously linked return can be priced when its order is
      // known (or tied slices have identical prices).
      if ((!isLocal || !ret.local) &&
          allocations.isEmpty &&
          qty != base &&
          _ambiguousRestoration(slices)) {
        provable = false;
        break;
      }
      final left = _outstanding;
      final remaining = left.isEmpty && booked != null
          ? BigInt.zero
          : supportedBooked
          ? _costInInvoice(left)
          : null;
      allocations.add((
        ret,
        parts,
        remaining == null || stillBooked == null
            ? null
            : stillBooked - remaining,
      ));
      stillBooked = remaining;
    }
    final localReturns = isLocal && returns.every((r) => r.local);
    final storedMatches = slices.every(
      (s) => s.restored == s.row['restored_micro'],
    );
    if (!provable ||
        (localReturns
            ? !storedMatches
            : allocations.length > 1 && !storedMatches)) {
      costs.unclassified = true;
      return;
    }
    for (final (ret, parts, released) in allocations) {
      if (!window.includes(ret.day)) continue;
      if (released != null) {
        costs.add(code, -released, operationUs: at, frozen: quote);
      } else if (booked == null) {
        _addPieces(costs, parts, restoring: true);
      } else {
        // The invoice's frozen COGS could not be broken down consistently.
        costs.unclassified = true;
      }
    }
  }
}

bool _reportDocumentedLotCost(String? currency, int cost, Object? source) =>
    currency != null &&
    cost >= 0 &&
    source != 'legacy_cover' &&
    // Some historical writers used zero when an opening/adjustment cost
    // was absent. A zero on an actual receipt or explicit initial lot is
    // distinguishable; do not assume the other placeholder zeroes are free.
    (cost > 0 || const {'purchase', 'initial', 'transfer'}.contains(source));

bool _reportLocalInvoice(Object? command, Object? invoice) =>
    command is String &&
    isDirectoryId(command) &&
    const Uuid().v5(command, BusinessCommerceSales._documentLabel) == invoice;

bool _ambiguousRestoration(List<_ReportCostSlice> slices) {
  for (var i = 1; i < slices.length; i++) {
    final a = slices[i - 1], b = slices[i];
    if (a.when == b.when &&
        (a.currency != b.currency || a.unitCost != b.unitCost)) {
      return true;
    }
  }
  return false;
}
