// Static scanner that enumerates every interactive element (buttons, menu
// items, tabs, chips, list/card actions, toggles…) declared in the Dart
// sources and the label/tooltip/icon that identifies it at runtime.
//
// Pure dart:io — no Flutter imports — so it runs both inside `flutter test`
// (help_coverage_test.dart) and standalone:
//
//   dart run test/help/help_coverage_scanner.dart > coverage.txt
//
// It is a pragmatic Dart lexer (strings, comments, interpolation, bracket
// stack), not a full parser: it is tuned to the way this codebase writes
// widgets (`translate('key')`, `AppLocalizations.t('key')`, `tr('key')`,
// `isAr ? 'نص' : 'text'`, `Icons.x`).

import 'dart:io';

/// One label/icon source found inside an interactive element.
class ScanItem {
  /// 'key' (ARB key), 'lit' (literal string), 'icon' (Icons.x / HugeIcons.x).
  final String kind;
  final String value;

  /// Named parameter of the interactive call the item came through
  /// (child, label, title, tooltip, icon…).
  final String param;
  const ScanItem(this.kind, this.value, this.param);

  @override
  String toString() => '$kind:$value';
}

class ScanElement {
  final String file;
  final int line;
  final String widget;
  final List<ScanItem> items;
  const ScanElement(this.file, this.line, this.widget, this.items);

  List<String> get keys =>
      [for (final i in items) if (i.kind == 'key') i.value];
  List<String> get literals =>
      [for (final i in items) if (i.kind == 'lit') i.value];
  List<String> get icons =>
      [for (final i in items) if (i.kind == 'icon') i.value];
}

/// Widgets that are interactive by construction (even when disabled).
const Set<String> kAlwaysInteractive = {
  'ElevatedButton', 'FilledButton', 'OutlinedButton', 'TextButton',
  'IconButton', 'FloatingActionButton', 'PopupMenuItem',
  'CheckedPopupMenuItem', 'PopupMenuButton', 'Tab', 'ChoiceChip',
  'FilterChip', 'ActionChip', 'InputChip', 'Switch', 'SwitchListTile',
  'CheckboxListTile', 'RadioListTile', 'Checkbox', 'Radio',
  'DropdownMenuItem', 'ButtonSegment', 'MenuItemButton', 'CupertinoSwitch',
  'BackButton', 'CloseButton', 'DropdownButton', 'DropdownButtonFormField',
};

/// Editable fields: the clicker is always quiet on them.
const Set<String> kEditable = {
  'TextField', 'TextFormField', 'FyonaTextField', 'CupertinoTextField',
  'SearchField', 'EditableText', 'BusinessNumberField', 'AutoNumField',
  'SearchBarWidget', '_numField', '_MiniNum', 'NumberField',
};

const Set<String> kInteractionArgs = {
  'onTap', 'onPressed', 'onSelected', 'onChanged', 'onLongPress',
  'onTapDown', 'onTapUp',
};

/// Parameters whose content is NOT the visible face of the element
/// (callbacks, builders of other routes, data).
bool _isCallbackParam(String p) => p.startsWith('on') || p == 'validator';

const Set<String> _kSkipParams = {
  'fontFamily', 'key', 'heroTag', 'value', 'groupValue', 'restorationId',
  'package', 'fontFamilyFallback', 'style', 'textStyle', 'debugLabel',
  'semanticsValue', 'initialValue',
};

/// AppLocalizations convenience getters (`l10n.save` == translate('save')).
Set<String> loadL10nGetters(String path) {
  final f = File(path);
  if (!f.existsSync()) return {};
  return RegExp(r"String get (\w+) => translate\('(\w+)'\)")
      .allMatches(f.readAsStringSync())
      .map((m) => m.group(2)!)
      .toSet();
}

class _Frame {
  final String callee;
  final int line;
  final String open;
  String param = '';
  final Set<String> named = {};
  final List<ScanItem> items = [];
  bool sawArgBefore = false;
  _Frame(this.callee, this.line, this.open);
}

class HelpCoverageScanner {
  final List<ScanElement> elements = [];
  final Set<String> l10nGetters;
  HelpCoverageScanner({Set<String>? getters})
      : l10nGetters = getters ??
            loadL10nGetters('lib/core/localization/app_localizations.dart');

  void scanFile(String path, String src) {
    final stack = <_Frame>[_Frame('<root>', 1, '')];
    var i = 0;
    var line = 1;
    String lastIdent = '';
    int lastIdentEnd = -1;
    final n = src.length;

    bool isIdentChar(int c) =>
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 95 ||
        c == 36;

    void addItem(ScanItem item) {
      for (final f in stack) {
        if (_kSkipParams.contains(f.param)) return;
      }
      stack.last.items.add(ScanItem(item.kind, item.value,
          stack.last.param.isEmpty ? item.param : stack.last.param));
    }

    // Reads a string literal starting at i (quote at src[i], optional r
    // prefix already consumed by caller via [raw]). Returns the plain
    // content (interpolations stripped) and advances i.
    final interpKeys = <String>[];
    String readString(bool raw) {
      final q = src[i];
      final triple = i + 2 < n && src[i + 1] == q && src[i + 2] == q;
      final buf = StringBuffer();
      i += triple ? 3 : 1;
      while (i < n) {
        final c = src[i];
        if (c == '\n') line++;
        if (!raw && c == '\\') {
          if (i + 1 < n) buf.write(src[i + 1]);
          i += 2;
          continue;
        }
        if (triple) {
          if (c == q && i + 2 < n && src[i + 1] == q && src[i + 2] == q) {
            i += 3;
            return buf.toString();
          }
        } else if (c == q) {
          i++;
          return buf.toString();
        }
        if (!raw && c == r'$' && i + 1 < n && src[i + 1] == '{') {
          // Skip a balanced interpolation (keys used inside it still count:
          // '${l10n.translate('save')} ($count)').
          var depth = 0;
          final interpStart = i;
          i++;
          while (i < n) {
            final d = src[i];
            if (d == '\n') line++;
            if (d == '{') depth++;
            if (d == '}') {
              depth--;
              if (depth == 0) {
                i++;
                break;
              }
            }
            if (d == "'" || d == '"') {
              readString(false);
              continue;
            }
            i++;
          }
          final inner = src.substring(interpStart, i);
          for (final m in RegExp(r"""(?:translate|\bt|\btr)\(\s*'(\w+)'""")
              .allMatches(inner)) {
            interpKeys.add(m.group(1)!);
          }
          buf.write('{}');
          continue;
        }
        buf.write(c);
        i++;
      }
      return buf.toString();
    }

    void closeFrame() {
      if (stack.length <= 1) return;
      final f = stack.removeLast();
      final parent = stack.last;
      final base = f.callee.split('.').first;
      if (f.open == '(' && kEditable.contains(base)) {
        return; // editable: never help, never propagate.
      }
      if (f.callee.endsWith('.styleFrom') ||
          f.callee.endsWith('.copyWith') ||
          base == 'ButtonStyle') {
        for (final it in f.items) {
          parent.items.add(it);
        }
        return;
      }
      final interactive = f.open == '(' &&
          (kAlwaysInteractive.contains(base) ||
              (f.named.any(kInteractionArgs.contains) &&
                  (RegExp(r'^_?[A-Z]').hasMatch(base) ||
                      // private helpers that build a tile: _settingsTile(…)
                      RegExp(r'^_[a-z]\w*$').hasMatch(base))));
      if (interactive) {
        elements.add(ScanElement(path, f.line, f.callee, [
          for (final it in f.items)
            if (!_isCallbackParam(it.param)) it,
        ]));
        return;
      }
      // Translate-style calls: their first string literal is a key.
      for (final it in f.items) {
        if (_isCallbackParam(it.param)) continue;
        parent.items.add(ScanItem(it.kind, it.value,
            parent.param.isEmpty ? it.param : parent.param));
      }
    }

    while (i < n) {
      final c = src[i];
      final code = src.codeUnitAt(i);
      if (c == '\n') {
        line++;
        i++;
        continue;
      }
      // Comments.
      if (c == '/' && i + 1 < n && src[i + 1] == '/') {
        while (i < n && src[i] != '\n') {
          i++;
        }
        continue;
      }
      if (c == '/' && i + 1 < n && src[i + 1] == '*') {
        i += 2;
        while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/')) {
          if (src[i] == '\n') line++;
          i++;
        }
        i += 2;
        continue;
      }
      // Strings.
      if (c == "'" || c == '"') {
        final raw = lastIdent == 'r' && lastIdentEnd == i;
        interpKeys.clear();
        final s = readString(raw);
        for (final k in List.of(interpKeys)) {
          addItem(ScanItem('key', k, ''));
        }
        final top = stack.last;
        final calleeBase = top.callee.split('.').last;
        const translators = {'translate', 't', 'tr', '_tr', 'translateOptional', '_t', 'l'};
        if (top.open == '(' &&
            translators.contains(calleeBase) &&
            !top.sawArgBefore &&
            RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(s)) {
          top.items.add(ScanItem('key', s, ''));
        } else if (s.trim().isNotEmpty &&
            RegExp(r'[A-Za-z؀-ۿ]').hasMatch(s) &&
            !s.contains('/') &&
            !RegExp(r'^[a-z_][A-Za-z0-9_.]*$').hasMatch(s) &&
            s.length <= 40) {
          addItem(ScanItem('lit', s.trim(), ''));
        }
        lastIdent = '';
        continue;
      }
      if (isIdentChar(code)) {
        final start = i;
        while (i < n && isIdentChar(src.codeUnitAt(i))) {
          i++;
        }
        var ident = src.substring(start, i);
        // Dotted names: Icons.add, ElevatedButton.icon, l10n.translate.
        if (start > 0 && src[start - 1] == '.' && lastIdentEnd == start - 1) {
          ident = '$lastIdent.$ident';
        }
        lastIdent = ident;
        lastIdentEnd = i;
        // l10n.save / loc.save / AppLocalizations.of(context).save
        final member = ident.split('.').last;
        if (l10nGetters.contains(member) &&
            (i >= n || src[i] != '(') &&
            ((ident.contains('.') &&
                    RegExp(r'^(l10n|l|loc|s|t|tr|lang|localizations|_l10n|strings|i18n)\.')
                        .hasMatch(ident)) ||
                (start > 1 && src[start - 1] == '.' && src[start - 2] == ')'))) {
          addItem(ScanItem('key', member, ''));
        }
        final iconMatch = RegExp(
                r'(?:^|\.)((?:Icons|HugeIcons|TwoToneIcons|CupertinoIcons)\.[A-Za-z0-9_]+)$')
            .firstMatch(ident);
        if (iconMatch != null && (i >= n || src[i] != '.')) {
          addItem(ScanItem('icon', iconMatch.group(1)!, ''));
        }
        continue;
      }
      if (c == '.') {
        // keep lastIdentEnd chain intact: a.b
        if (lastIdentEnd == i) {
          lastIdentEnd = i;
        }
        i++;
        continue;
      }
      if (c == ':') {
        // Named argument marker (not part of ?: — good enough).
        final top = stack.last;
        if (top.open == '(' && lastIdent.isNotEmpty && lastIdentEnd >= 0) {
          var j = lastIdentEnd;
          while (j < i && (src[j] == ' ' || src[j] == '\n' || src[j] == '\t')) {
            j++;
          }
          if (j == i && !lastIdent.contains('.')) {
            top.param = lastIdent;
            top.named.add(lastIdent);
            top.sawArgBefore = true;
          }
        }
        i++;
        lastIdent = '';
        continue;
      }
      if (c == '(' || c == '[' || c == '{') {
        var callee = '';
        if (c == '(' && lastIdentEnd >= 0) {
          var j = lastIdentEnd;
          // allow generic args: Foo<Bar>(
          while (j < i && (src[j] == ' ')) {
            j++;
          }
          if (j == i) callee = lastIdent;
        }
        if (c == '(' && callee.isEmpty) {
          // generic instantiation: PopupMenuItem<String>(
          final back = src.substring(i - (i > 80 ? 80 : i), i);
          final m = RegExp(r'([A-Za-z_][A-Za-z0-9_.]*)\s*<[^()]*>\s*$')
              .firstMatch(back);
          if (m != null) callee = m.group(1)!;
        }
        stack.add(_Frame(callee, line, c));
        i++;
        lastIdent = '';
        lastIdentEnd = -1;
        continue;
      }
      if (c == ')' || c == ']' || c == '}') {
        closeFrame();
        i++;
        lastIdent = '';
        lastIdentEnd = -1;
        continue;
      }
      if (c == ',') {
        final top = stack.last;
        if (top.open == '(') {
          top.param = '';
          top.sawArgBefore = true;
        }
        i++;
        lastIdent = '';
        continue;
      }
      if (c == ';' && stack.last.open == '{') {
        i++;
        lastIdent = '';
        continue;
      }
      i++;
      if (c != ' ' && c != '\t' && c != '\r') lastIdent = '';
    }
  }

  /// Scans every presentation file under [roots].
  void scanDirs(List<String> roots) {
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final p = f.path.replaceAll('\\', '/');
        if (!_isUiFile(p)) continue;
        scanFile(p, f.readAsStringSync());
      }
    }
  }

  static bool _isUiFile(String p) {
    if (p.contains('/data/') || p.contains('/domain/')) return false;
    if (p.endsWith('_pdf.dart') || p.contains('/pdf/')) return false;
    return true;
  }
}

void main(List<String> args) {
  final s = HelpCoverageScanner()
    ..scanDirs(args.isEmpty ? ['lib/features', 'lib/shared/widgets'] : args);
  for (final e in s.elements) {
    stdout.writeln('${e.file}:${e.line}\t${e.widget}\t${e.items.join(' ')}');
  }
  stderr.writeln('elements: ${s.elements.length}');
}
