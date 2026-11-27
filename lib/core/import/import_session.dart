import 'import_plan.dart';
import 'import_schema.dart';
import 'import_source.dart';

/// One smart import from file to review: every table of the file, where
/// each goes, the currency of amounts the file does not name, the file's
/// branch to import, and the review of each table that is imported.
///
/// Sara's operations (from the import window's chat) are applied HERE with
/// the app's own rules; every row is checked again afterwards and nothing
/// is saved until the user confirms the review.
class ImportSession {
  ImportSession(this.analysis, this.context, {this.currency = 'SAR', ImportImages? images}) : images = images ?? ImportImages.none;

  final List<TableAnalysis> analysis;
  final ImportContext context;
  final ImportImages images;

  /// Currency of amounts the file does not name (and of cost prices).
  String currency;

  /// The file's branch to import (display name); null: all branches.
  String? sourceBranch;

  /// Names / codes already in the FYONA branch (the "exists" check).
  Set<String> existing = const {};

  final reviews = <TableAnalysis, ImportReview>{};

  /// Sara's value changes (prices, a field for all rows, rows left out):
  /// applied again to a review that is rebuilt, so they are never lost.
  final _valueOps = <Map<String, dynamic>>[];

  static Future<ImportSession> analyze(List<ImportTable> tables,
      {String currency = 'SAR', ImportImages? images, String? currentBranchName}) async {
    final ctx = ImportContext();
    final a = await analyzeImportSchema(tables, context: ctx);
    final s = ImportSession(a, ctx, currency: currency, images: images);
    // The file's branch named like the FYONA branch is chosen first.
    final choices = s.branchChoices;
    if (currentBranchName != null && choices.length > 1) {
      final want = importFold(currentBranchName);
      s.sourceBranch = choices.keys.where((b) => importFold(b) == want).firstOrNull;
    }
    return s;
  }

  /// The file's branches (display name → every key that means it).
  Map<String, Set<String>> get branchChoices => importBranchChoices(context);

  Set<String>? get _branchKeys => sourceBranch == null ? null : branchChoices[sourceBranch];

  List<TableAnalysis> get importable => [for (final a in analysis) if (a.role.importable) a];
  List<TableAnalysis> get linked => [for (final a in analysis) if ((a.role.part && a.link != null) || a.role == TableRole.categories && a.link != null) a];
  List<TableAnalysis> get reference => [for (final a in analysis) if (a.role.reference) a];
  List<TableAnalysis> get skipped => [
        for (final a in analysis)
          if (!a.role.importable && !a.role.reference && !((a.role.part || a.role == TableRole.categories) && a.link != null)) a,
      ];

  /// Tables Sara should look at: unclear ones and those the rules were
  /// not sure of (the user's own choices are never overridden).
  List<TableAnalysis> get forSara =>
      [for (final a in analysis) if (a.by != 'user' && (a.role == TableRole.unknown || a.confidence < .9)) a];

  Future<int> applySara(List<Map<String, dynamic>> answers) async {
    final n = await applySaraSchema(analysis, answers, context: context);
    reviews.clear();
    return n;
  }

  Future<void> setRole(TableAnalysis a, TableRole role) async {
    await setTableRole(analysis, a, role, context: context);
    reviews.clear();
  }

  void setMapping(TableAnalysis a, Map<String, String> mapping) {
    a.mapping = mapping;
    reviews.clear();
  }

  void setCurrency(String code) {
    if (code == currency) return;
    currency = code;
    reviews.clear();
  }

  void setSourceBranch(String? name) {
    if (name == sourceBranch) return;
    sourceBranch = name;
    reviews.clear();
  }

  /// Builds the review of every imported table (rows checked).
  Future<void> buildReviews({void Function(String table, int rows)? onRows}) async {
    final keys = _branchKeys;
    for (final a in importable) {
      if (reviews.containsKey(a)) continue;
      final target = a.role.target!;
      final parts = a.role == TableRole.products ? await joinProductParts(analysis, a.table, branchKeys: keys) : null;
      final party = target == ImportTarget.parties && analysis.any((x) => x.role.partyPart && x.link?.parent == a.table)
          ? await joinPartyParts(analysis, a.table, currencyCodes: context.currencyCodes)
          : null;
      reviews[a] = await ImportReview.load(a.table, target, a.mapping,
          defaultKind: a.role == TableRole.suppliers ? 'supplier' : 'customer',
          defaultCurrency: currency,
          existing: existing,
          branches: keys ?? const {},
          images: images.names,
          blobImages: images.has('fyblob:'),
          parts: parts,
          partyParts: party,
          currencyCodes: context.currencyCodes,
          onRows: (n) => onRows?.call(a.table.name, n));
      for (final o in _valueOps) {
        _applyValue(o, {a: reviews[a]!});
      }
    }
  }

  int get readyCount => reviews.values.fold(0, (a, r) => a + r.acceptedCount);

  /// Applies Sara's operations (already checked by the server) with the
  /// app's own rules; returns how many rows / tables each changed.
  Future<List<String>> applyOps(List<Map<String, dynamic>> ops) async {
    final done = <String>[];
    final byName = {for (final a in analysis) a.table.name: a};
    for (final o in ops) {
      switch (o['op']) {
        case 'set_role':
          final a = byName['${o['table']}'];
          final role = TableRole.values.where((r) => r.name == o['role']).firstOrNull;
          if (a == null || role == null) continue;
          await setRole(a, role);
          done.add('role:${a.table.name}:${a.role.name}');
        case 'map':
          final a = byName['${o['table']}'];
          final field = '${o['field']}';
          final col = o['column'] == null ? null : '${o['column']}';
          if (a == null) continue;
          final fields = a.role.target != null ? importFields[a.role.target]! : partFields[a.role] ?? const <ImportField>[];
          if (!fields.any((f) => f.key == field) || (col != null && !a.table.columns.contains(col))) continue;
          final m = Map.of(a.mapping)..removeWhere((k, v) => v == col);
          if (col == null) {
            m.remove(field);
          } else {
            m[field] = col;
          }
          setMapping(a, m);
          if (a.role.part) await linkImportSchema(analysis, context: context);
          done.add('map:${a.table.name}:$field');
        case 'set_currency':
          final code = '${o['currency']}'.toUpperCase();
          if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) continue;
          setCurrency(code);
          done.add('currency:$code');
        case 'set_field':
        case 'adjust':
        case 'reject':
        case 'accept':
          await buildReviews();
          _valueOps.add(o);
          done.add('${o['op']}:${_applyValue(o, reviews)}');
      }
    }
    return done;
  }

  /// One value change on [on]; returns how many rows it touched.
  int _applyValue(Map<String, dynamic> o, Map<TableAnalysis, ImportReview> on) {
    Iterable<ImportReview> of(String target) => [
          for (final e in on.entries)
            if (e.key.role.name == target) e.value,
        ];
    var n = 0;
    switch (o['op']) {
      case 'set_field':
        final field = '${o['field']}', value = '${o['value']}';
        final onlyEmpty = o['only_empty'] == true;
        for (final r in of('${o['target']}')) {
          for (final row in r.rows) {
            if (onlyEmpty && row[field] != null) continue;
            row.values[field] = value;
            n++;
          }
          r.revalidate();
        }
      case 'adjust':
        final field = '${o['field']}';
        final pct = (o['percent'] as num?)?.toDouble();
        final add = (o['add'] as num?)?.toDouble();
        for (final r in of('products')) {
          for (final row in r.rows) {
            final d = importDecimal(row[field]);
            if (d == null) continue;
            final v = double.parse(d);
            final next = pct != null ? v * (1 + pct / 100) : v + (add ?? 0);
            if (next < 0) continue;
            row.values[field] = importRound(next.toStringAsFixed(6), 2)!.value;
            n++;
          }
          r.revalidate();
        }
      case 'reject':
      case 'accept':
        final where = (o['where'] as Map?) ?? const {};
        final field = '${where['field']}', op = '${where['op']}';
        final value = where['value']?.toString();
        for (final r in of('${o['target']}')) {
          final hits = r.rows.where((row) => _matches(row[field], op, value)).toList();
          r.setRejected(hits, o['op'] == 'reject');
          r.revalidate();
          n += hits.length;
        }
    }
    return n;
  }

  static bool _matches(String? v, String op, String? want) {
    switch (op) {
      case 'empty':
        return v == null || v.trim().isEmpty;
      case 'not_empty':
        return v != null && v.trim().isNotEmpty;
      case 'equals':
        return v != null && want != null && importFold(v) == importFold(want);
      case 'contains':
        return v != null && want != null && importFold(v).contains(importFold(want));
      case 'lt':
      case 'gt':
        final a = importDecimal(v), b = importDecimal(want);
        if (a == null || b == null) return false;
        final x = double.parse(a), y = double.parse(b);
        return op == 'lt' ? x < y : x > y;
    }
    return false;
  }
}
