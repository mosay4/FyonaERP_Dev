import '../../../../core/utils/currency_formatter.dart';
import 'sara_currency_names.dart';

String saraCurrencyLabel(String code, {required bool arabic}) =>
    (arabic ? saraCurrencyNamesAr : saraCurrencyNamesEn)[code] ?? currencyName(code, locale: arabic ? 'ar' : 'en');

String saraDisplayText(String text, {required bool arabic}) {
  if (!arabic) return text;
  text = text.replaceAllMapped(RegExp(r'(?<![\w-])(?:YER_OLD|YER_NEW|[A-Z]{3})(?![\w-])'),
      (m) => saraCurrencyNamesAr.containsKey(m[0]) || isKnownCurrency(m[0]!) ? saraCurrencyLabel(m[0]!, arabic: true) : m[0]!);
  for (final e in {'راجعي': 'راجع', 'تأكدي': 'تأكد', 'أكدي': 'أكد', 'قولي': 'قل',
    'اختاري': 'اختر', 'افتحي': 'افتح', 'استخدمي': 'استخدم', 'تقدري': 'تقدر'}.entries) {
    text = text.replaceAll(e.key, e.value);
  }
  return text;
}

const saraFieldLabels = <String, String>{
  'name': 'الاسم', 'amount': 'المبلغ', 'currency': 'العملة', 'type': 'النوع',
  'from_account_id': 'الحساب المرسل', 'to_account_id': 'الحساب المستلم', 'account_id': 'الحساب',
  'from_currency': 'عملة المصدر', 'to_currency': 'عملة الاستلام', 'exchange_rate': 'سعر الصرف',
  'destination_amount': 'المبلغ المستلم', 'balance': 'الرصيد الافتتاحي',
  'to_amount': 'المبلغ المستلم',
  'opening_balance': 'الرصيد الافتتاحي', 'description': 'الوصف', 'notes': 'ملاحظات',
  'target_amount': 'المبلغ المستهدف', 'current_amount': 'المبلغ الحالي', 'due_date': 'الاستحقاق',
  'person_name': 'الطرف', 'bank_account_id': 'الحساب البنكي', 'bank_name': 'البنك',
  'account_name': 'اسم الحساب', 'category': 'التصنيف', 'date': 'التاريخ',
};

List<MapEntry<String, String>> saraDetailRows(Map<String, dynamic> params, {required bool arabic}) {
  final rows = <MapEntry<String, String>>[];
  for (final e in params.entries) {
    if (e.value == null || e.key == 'token' || e.key == 'idempotency_key' || e.key.endsWith('_name') && e.key != 'person_name' && e.key != 'bank_name' && e.key != 'account_name') continue;
    var value = e.value.toString();
    if (e.key.endsWith('_id')) {
      value = '${params[e.key.replaceFirst(RegExp(r'_id$'), '_name')] ?? (arabic ? 'محدد في حسابك' : 'Selected account')}';
    }
    if (e.key.contains('currency')) value = saraCurrencyLabel(value, arabic: arabic);
    if (arabic) value = {'income': 'دخل', 'expense': 'مصروف', 'transfer': 'تحويل' }[value] ?? value;
    rows.add(MapEntry(arabic ? saraFieldLabels[e.key] ?? 'تفصيل العملية' : e.key.replaceAll('_', ' '), value));
  }
  return rows;
}

String saraOutcomeMessage(Map<String, dynamic> outcome, {required bool arabic}) {
  if (outcome['success'] == true) return arabic ? 'تم تنفيذ العملية بواسطة سارة.' : 'Operation completed by Sara.';
  final data = outcome['data'];
  final detail = data is Map ? data['message'] ?? data['detail'] : outcome['message'];
  if ('$detail'.contains('رصيد') || '$detail'.toLowerCase().contains('insufficient')) {
    return arabic ? 'لم تُنفذ العملية: الرصيد غير كافٍ. اختر حسابًا آخر أو عدّل المبلغ.'
        : 'Not executed: insufficient balance. Choose another account or adjust the amount.';
  }
  if (outcome['status'] == 422 || detail is List || detail is Map) {
    return arabic ? 'لم تُنفذ العملية: راجع البيانات المطلوبة، بعض الحقول ناقصة أو غير صحيحة.'
        : 'Not executed: check the required fields. Some values are missing or invalid.';
  }
  return arabic ? 'لم يتم تأكيد التنفيذ. ${detail is String ? saraDisplayText(detail, arabic: true) : 'راجع البيانات وسجل العمليات قبل المحاولة مجددًا.'}'
      : 'Execution was not confirmed. Check the operation details and history before retrying.';
}
