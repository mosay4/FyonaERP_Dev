import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../branches/data/branch_scope.dart';
import '../domain/printer_models.dart';

/// Printers known to this device and the default printer of each branch.
///
/// Kept on this device only (a printer is a physical thing next to this
/// phone / PC): every branch remembers its own default printer, paper,
/// copies and cut — opening a branch picks its printer automatically.
class PrinterStore {
  PrinterStore({String Function()? scope}) : _scope = scope ?? currentScope;

  final String Function() _scope;

  static const _kSaved = 'print_saved_printers_v2';
  static String _kDefault(String scope) => 'print_default_v2:$scope';

  // Older single-printer keys (one printer for the whole device).
  static const _kOldPrinter = 'biz_print_printer';
  static const _kOldPaper = 'biz_print_paper';
  static const _kOldCopies = 'biz_print_copies';
  static const _kOldAutoCut = 'biz_print_autocut';

  /// `<organization>/<branch>` (or `all`), falling back to `device`.
  static String currentScope() {
    final org = BranchScope.organizationId ?? '';
    if (BranchScope.allMode) return '$org/all';
    final branch = BranchScope.branchId ?? '';
    return org.isEmpty && branch.isEmpty ? 'device' : '$org/$branch';
  }

  Future<List<PrinterDevice>> saved() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kSaved);
    if (raw == null || raw.isEmpty) return [];
    try {
      return [
        for (final e in (jsonDecode(raw) as List).whereType<Map>())
          PrinterDevice.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> remember(PrinterDevice d) async {
    final list = await saved();
    list.removeWhere((x) => x.id == d.id);
    list.insert(0, d);
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kSaved, jsonEncode([for (final x in list.take(20)) x.toJson()]));
  }

  Future<void> forget(String id) async {
    final list = await saved()..removeWhere((x) => x.id == id);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSaved, jsonEncode([for (final x in list) x.toJson()]));
    final prefs = await load();
    if (prefs.printer?.id == id) await save(prefs.copyWith(clearPrinter: true));
  }

  /// Preferences of the current branch (migrates the old device-wide ones
  /// the first time).
  Future<PrintPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kDefault(_scope()));
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        return PrintPrefs(
          printer: j['printer'] is Map
              ? PrinterDevice.fromJson(Map<String, dynamic>.from(j['printer'] as Map))
              : null,
          paper: PrintPaper.values.firstWhere((x) => x.name == j['paper'],
              orElse: () => PrintPaper.thermal80),
          copies: (j['copies'] as num?)?.toInt().clamp(1, 999) ?? 1,
          autoCut: j['autoCut'] != false,
        );
      } catch (_) {}
    }
    return _legacy(p);
  }

  Future<void> save(PrintPrefs prefs) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kDefault(_scope()),
        jsonEncode({
          if (prefs.printer != null) 'printer': prefs.printer!.toJson(),
          'paper': prefs.paper.name,
          'copies': prefs.copies,
          'autoCut': prefs.autoCut,
        }));
    if (prefs.printer != null) await remember(prefs.printer!);
  }

  PrintPrefs _legacy(SharedPreferences p) {
    PrinterDevice? printer;
    final raw = p.getString(_kOldPrinter);
    if (raw != null && raw.isNotEmpty) {
      final m = <String, dynamic>{};
      for (final part in raw.split('&')) {
        final i = part.indexOf('=');
        if (i > 0) m[part.substring(0, i)] = part.substring(i + 1);
      }
      try {
        printer = PrinterDevice.fromJson(m);
      } catch (_) {}
    }
    return PrintPrefs(
      printer: printer,
      paper: PrintPaper.values.firstWhere((x) => x.name == p.getString(_kOldPaper),
          orElse: () => PrintPaper.thermal80),
      copies: p.getInt(_kOldCopies) ?? 1,
      autoCut: p.getBool(_kOldAutoCut) ?? true,
    );
  }
}
