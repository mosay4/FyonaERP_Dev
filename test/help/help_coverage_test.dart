import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fyona_flutter/core/help/catalog/help_catalog.dart';
import 'package:fyona_flutter/core/help/catalog/help_registry.dart';

import 'help_coverage_scanner.dart';

/// Coverage of the Information Clicker over the Business and Personal
/// sections (plus profile/settings and the shared bars/sheets).
///
/// The scanner enumerates every interactive element in the UI sources —
/// buttons, icon buttons, FABs, menu items, tabs, chips, toggles, list
/// tiles and every custom widget called with onTap/onPressed — and this
/// test fails when an element that shows an identifiable label/icon has no
/// curated help.
///
/// Set `HELP_COVERAGE_OUT=path` to also write the page → elements list.

/// Pre-login screens are outside the two sections.
const _outOfScope = [
  'lib/features/auth/',
  'lib/features/mfa/',
  'lib/features/onboarding/',
  'lib/features/splash/',
];

/// Elements reviewed by hand whose face is record data (names, amounts,
/// dates, server text) or that sit in a quiet zone. They are explained by a
/// section `row:` help, or deliberately silent. Keyed by file + widget (no
/// line numbers, so edits elsewhere in the file don't break the list).
const Map<String, String> _reviewed = {
  'core_business/presentation/pages/customers_page.dart|GestureDetector':
      'customer row → b.debts.partyRow',
  'core_business/presentation/pages/suppliers_page.dart|GestureDetector':
      'supplier row → b.debts.partyRow',
  'core_business/presentation/pages/party_detail_page.dart|InkWell':
      'operations button: label comes from a variable (partyOps*Btn keys are covered)',
  'core_business/presentation/pages/party_operations_page.dart|InkWell':
      'operation row → b.debts.sectionRow',
  'core_business/presentation/widgets/debt_section_picker.dart|_tile':
      'debt group row (user group name) → b.debts.sectionRow',
  'core_business/presentation/widgets/debt_widgets.dart|InkWell':
      'debt group tile (user group name) → b.debts.sectionRow',
  'dashboard/presentation/pages/business_transactions_page.dart|GestureDetector':
      'transaction row → b.tx.row',
  'inventory/presentation/pages/product_movements_page.dart|InkWell':
      'movement row → o.inv.movementRow',
  'invoices/presentation/pages/invoices_list_page.dart|ListTile':
      'invoice row → b.sale.row',
  'personal/presentation/pages/chat_page.dart|ListTile':
      'outbox/upload row (message text); its retry/cancel icons are covered',
  'personal/presentation/pages/chat_page.dart|GestureDetector':
      'chat bubble parts: the bubble owns a native long press → silent',
  'personal/presentation/pages/personal_debts_page.dart|ListTile':
      'debt operation row → personal debts row help',
  'personal/presentation/pages/personal_transactions_page.dart|GestureDetector':
      'transaction row inside ClickerQuiet (native long press) → silent',
  'personal/presentation/pages/widgets/home_services_grid.dart|GestureDetector':
      'service tiles: label key comes from the item (homeService* keys covered)',
  'personal/presentation/pages/widgets/tree/tree_list_page.dart|InkWell':
      'tree row (user names) → p.tree.node',
  'profile/presentation/pages/profile_page.dart|ListTile':
      'session-timeout radio options: label from a list of durations',
  'reports/presentation/widgets/report_widgets.dart|GestureDetector':
      'report tiles: label from the report definition (keys covered)',
  'sales/presentation/pages/sale_invoices_page.dart|ListTile':
      'customer picker row (customer names) → b.sale.productRow / row help',
  'sales/presentation/widgets/sale_items_section.dart|ListTile':
      'product picker row (product names) → b.sale.productRow',
  'sales/presentation/widgets/sale_items_section.dart|GestureDetector':
      'stock badge inside the product row → b.sale.productRow',
  'shared/widgets/sara_chat_page.dart|_SaraPressable':
      'Sara suggestion chips: text comes from the server',
  'shared/widgets/sara_chat_page.dart|GestureDetector':
      'Sara message bubbles inside ClickerQuiet → silent',
  'employees/presentation/pages/employee_payment_page.dart|FilledButton.icon':
      'submit label is a variable (صرف راتب / سداد…) → g.emp.paySubmit',
  'profile/presentation/pages/profile_page.dart|_settingsTile':
      'business-currency tile: title from a helper → g.profile.bizCurrencies',
  'shared/widgets/stat_card.dart|GestureDetector':
      'generic stat card: label passed by the caller',
};

void main() {
  test('every identifiable interactive element has help', () {
    final scanner = HelpCoverageScanner()
      ..scanDirs(['lib/features', 'lib/shared/widgets']);
    final entries = HelpRegistry.all;
    final keys = <String, String>{};
    final texts = <String, String>{};
    for (final e in entries) {
      for (final k in e.keys) {
        keys.putIfAbsent(k, () => e.id);
      }
      for (final t in e.texts) {
        texts.putIfAbsent(helpNormalize(t), () => e.id);
      }
    }
    // Icon matchers are compared by source name (Icons.x / HugeIcons.x /
    // TwoToneIcons.x), read from the catalog sources.
    final iconOwner = <String, String>{};
    for (final f in Directory('lib/core/help/catalog')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r"id:\s*'([^']+)'(.*?)\n\s*\),", dotAll: true)
          .allMatches(src)) {
        final body = m.group(2)!;
        final im = RegExp(r'icons:\s*\[([^\]]*)\]').firstMatch(body);
        if (im == null) continue;
        for (final n in RegExp(
                r'(?:Icons|HugeIcons|TwoToneIcons|CupertinoIcons)\.\w+')
            .allMatches(im.group(1)!)) {
          iconOwner.putIfAbsent(n.group(0)!, () => m.group(1)!);
        }
      }
    }

    final letters = RegExp(r'[A-Za-z؀-ۿ]');
    final uncovered = <String>[];
    final report = <String, List<String>>{};
    var covered = 0;
    var dynamicOnly = 0;
    final perSection = <String, List<int>>{};

    for (final el in scanner.elements) {
      if (_outOfScope.any(el.file.contains)) continue;
      final section = _section(el.file);
      final counts = perSection.putIfAbsent(section, () => [0, 0, 0]);
      String? via;
      String? id;
      for (final k in el.keys) {
        final hit = keys[k];
        if (hit != null) {
          via = 'key:$k';
          id = hit;
          break;
        }
      }
      if (id == null) {
        for (final l in el.literals) {
          final hit = texts[helpNormalize(l)];
          if (hit != null) {
            via = 'text:$l';
            id = hit;
            break;
          }
        }
      }
      if (id == null) {
        for (final ic in el.icons) {
          final hit = iconOwner[ic];
          if (hit != null) {
            via = 'icon:$ic';
            id = hit;
            break;
          }
        }
      }
      final realLiterals = el.literals
          .where((l) => letters.hasMatch(l.replaceAll('{}', '')))
          .where((l) => !l.startsWith(r'$'))
          .toList();
      final identifiable =
          el.keys.isNotEmpty || realLiterals.isNotEmpty || el.icons.isNotEmpty;
      final where = '${el.file}:${el.line} ${el.widget}';
      final page = el.file.replaceFirst('lib/', '');
      if (id != null) {
        covered++;
        counts[0]++;
        (report[page] ??= []).add('  ✔ ${el.widget} (line ${el.line}) → $id  [$via]');
      } else if (!identifiable) {
        dynamicOnly++;
        counts[2]++;
        (report[page] ??= []).add(
            '  • ${el.widget} (line ${el.line}) — label comes from the caller / record data');
      } else if (_reviewed.containsKey(
          '${el.file.replaceFirst(RegExp(r'^lib/(features/)?'), '')}|${el.widget}')) {
        dynamicOnly++;
        counts[2]++;
        (report[page] ??= []).add('  • ${el.widget} (line ${el.line}) — '
            '${_reviewed['${el.file.replaceFirst(RegExp(r'^lib/(features/)?'), '')}|${el.widget}']}');
      } else {
        counts[1]++;
        uncovered.add('$where  ${el.items.join(' ')}');
        (report[page] ??= [])
            .add('  ✘ ${el.widget} (line ${el.line}) ${el.items.join(' ')}');
      }
    }

    final out = Platform.environment['HELP_COVERAGE_OUT'];
    if (out != null && out.isNotEmpty) {
      final b = StringBuffer()
        ..writeln('# Information Clicker coverage (page → elements)')
        ..writeln()
        ..writeln('✔ covered · • dynamic label (covered at its call site or by a '
            'section row help) · ✘ missing')
        ..writeln()
        ..writeln('| Section | covered | missing | dynamic |')
        ..writeln('|---|---|---|---|');
      for (final s in perSection.entries) {
        b.writeln('| ${s.key} | ${s.value[0]} | ${s.value[1]} | ${s.value[2]} |');
      }
      b.writeln();
      for (final p in report.keys.toList()..sort()) {
        b
          ..writeln('## $p')
          ..writeln('```')
          ..writeln(report[p]!.join('\n'))
          ..writeln('```');
      }
      File(out).writeAsStringSync(b.toString());
    }

    // ignore: avoid_print
    print('help coverage: $covered covered, ${uncovered.length} missing, '
        '$dynamicOnly dynamic; per section: '
        '${perSection.map((k, v) => MapEntry(k, '${v[0]}/${v[1]}/${v[2]}'))}');
    expect(uncovered, isEmpty,
        reason: 'interactive elements without help:\n${uncovered.join('\n')}');
  });
}

String _section(String file) {
  if (file.contains('lib/features/personal/')) return 'Personal';
  if (file.contains('lib/shared/')) return 'Shared (both sections)';
  for (final s in const [
    'profile', 'settings', 'subscription', 'notifications', 'suggestions',
    'email', 'ai',
  ]) {
    if (file.contains('lib/features/$s/')) return 'Profile & settings';
  }
  return 'Business';
}
