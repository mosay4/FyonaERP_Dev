// Guards the "plain everyday wording" rule: the Arabic and English text
// tables must not use accountant-only jargon (debit/credit, ledger,
// reconciliation, receivables, assets/liabilities, net, opening balance...).
// Use everyday words instead: «لك عند الناس / عليك للناس», "Owed to you /
// You owe", «فحص / جرد», "Check / Count", «رصيد البداية», "Starting balance".
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _ar = r'[؀-ۿ]';
const _notAr = '(?<!$_ar)';
const _endAr = '(?!$_ar)';

final _arabicJargon = <RegExp>[
  RegExp('$_notAr(ال)?(مدين|دائن)(ون|ين)?$_endAr'),
  RegExp('ذمم'),
  RegExp('$_notAr(ال|و)?قيود$_endAr'),
  // «قيد» as a journal entry; «قيد التنفيذ / الانتظار ...» (= pending) is fine.
  RegExp('$_notAr(ال)?قيد$_endAr'
      '(?! (التنفيذ|المعالجة|الانتظار|المراجعة|الإرسال|التحقق|الصيانة|التطوير))'),
  RegExp('ترحيل'),
  RegExp('افتتاحي'),
  RegExp('تسوية|تسويات'),
  RegExp('$_notAr(ال)?صافي$_endAr'),
  RegExp('مستحقات'),
  RegExp('التزام'),
  RegExp('$_notAr(ال|و)?أصول$_endAr'),
  RegExp('$_notAr(ال)?خصوم$_endAr'),
  RegExp('ميزان المراجعة'),
  RegExp('تكلفة البضاعة'),
  RegExp('دفتر الأستاذ|دفتر اليومية'),
  RegExp('${_notAr}شطب'),
  RegExp('حقوق الملكية'),
  RegExp('قائمة الدخل'),
  RegExp('التدفق النقدي'),
  // «مطابقة» as "reconciliation"; the adjective after a noun
  // («نتائج مطابقة» = matching results) is everyday Arabic.
  RegExp('$_notAr(ال)?مطابقة$_endAr(?<!نتائج مطابقة)(?<!منتجات مطابقة)'),
  RegExp('القيمة الدفترية'),
  RegExp('التحكيم'),
  RegExp('مديونية'),
  RegExp('مساواة'),
];

final _englishJargon = <RegExp>[
  RegExp(r'\bdebit', caseSensitive: false),
  RegExp(r'\bcredit\b(?! card)', caseSensitive: false),
  RegExp(r'receivable|payable', caseSensitive: false),
  RegExp(r'ledger|journal', caseSensitive: false),
  RegExp(r'liabilit', caseSensitive: false),
  RegExp(r'\bassets?\b', caseSensitive: false),
  RegExp(r'write-?off|accrual|depreciat|book value', caseSensitive: false),
  RegExp(r'reconcil', caseSensitive: false),
  RegExp(r'\bCOGS\b|cost of goods', caseSensitive: false),
  RegExp(r'\bequity\b|trial balance', caseSensitive: false),
  RegExp(r'opening balance|net worth|cash ?flow', caseSensitive: false),
  RegExp(r'arbitration|settlement|equaliz', caseSensitive: false),
  RegExp(r'\boutstanding\b|\bnet\b', caseSensitive: false),
];

Map<String, dynamic> _table(String lang) =>
    jsonDecode(File('assets/l10n/app_$lang.arb').readAsStringSync())
        as Map<String, dynamic>;

// The owner asked to keep the reconciliation section's original wording
// («المطابقة», «مساواة النظام», «التسوية» / "Reconciliation", "Equalize",
// "Settlement"), so its keys are exempt from the jargon rules.
const _reconciliationKeys = {
  'bizReconcile',
  'inventoryAdjust',
  'repLocalLegacySettlements',
  'repReconciled',
  'repSettleAdjust',
  'repShowAllSettlements',
  'repShowLessSettlements',
};

bool _isReconciliationKey(String key) =>
    key.startsWith('recon') ||
    _reconciliationKeys.contains(key);

List<String> _offenders(String lang, List<RegExp> rules) {
  final out = <String>[];
  _table(lang).forEach((key, value) {
    if (key.startsWith('@')) return;
    if (_isReconciliationKey(key)) return;
    final raw = value is String ? value : jsonEncode(value);
    // Placeholder names such as {debit} are code, not wording.
    final text = raw.replaceAll(RegExp(r'\{\w+\}'), '');
    for (final rule in rules) {
      final m = rule.firstMatch(text);
      if (m != null) {
        out.add('$key: «${m.group(0)}» in "$raw"');
        break;
      }
    }
  });
  return out;
}

void main() {
  test('Arabic texts use everyday words, not accounting jargon', () {
    expect(_offenders('ar', _arabicJargon), isEmpty);
  });

  test('English texts use everyday words, not accounting jargon', () {
    expect(_offenders('en', _englishJargon), isEmpty);
  });

  test('English table has no Arabic-only values left untranslated', () {
    final en = _table('en');
    final ar = RegExp(_ar);
    const allowed = {'switchToArabic'}; // the language switch shows «العربية»
    final bad = [
      for (final e in en.entries)
        if (!e.key.startsWith('@') &&
            !allowed.contains(e.key) &&
            e.value is String &&
            ar.hasMatch(e.value as String) &&
            !RegExp(r'[A-Za-z]').hasMatch(e.value as String))
          e.key,
    ];
    expect(bad, isEmpty);
  });
}
