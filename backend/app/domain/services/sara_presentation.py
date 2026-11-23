"""Presentation policy only: never translate monetary payloads or identifiers."""
import re
from babel.core import get_global
from babel.numbers import get_currency_name


def currency_catalog():
    codes = {item[0] for rows in get_global('territory_currencies').values()
             for item in rows if item[2] is None and item[3] and item[0] != 'YER'}
    return sorted(codes | {'YER_OLD', 'YER_NEW', 'SYP_OLD', 'SYP_NEW', 'HRK'})


def currency_name(code, language='ar'):
    code = str(code).upper()
    if code in ('SYP_OLD', 'SYP_NEW'):
        return ({'SYP_OLD': 'ليرة سورية قديمة', 'SYP_NEW': 'ليرة سورية جديدة'}[code]
                if language != 'en' else {'SYP_OLD': 'Old Syrian pound', 'SYP_NEW': 'New Syrian pound'}[code])
    if code in ('YER_OLD', 'YER_NEW'):
        return ({'YER_OLD': 'ريال يمني قديم', 'YER_NEW': 'ريال يمني جديد'}[code]
                if language != 'en' else {'YER_OLD': 'Old Yemeni rial', 'YER_NEW': 'New Yemeni rial'}[code])
    return get_currency_name(code, locale='en' if language == 'en' else 'ar')


def present(text, language='ar'):
    if language == 'en':
        return text
    text = re.sub(r'(?<![\w-])(?:[A-Z]{3}|YER_OLD|YER_NEW)(?![\w-])',
                  lambda m: currency_name(m[0]) if m[0] in currency_catalog() else m[0], text)
    for old, new in {'راجعي': 'راجع', 'أكدي': 'أكد', 'تأكدي': 'تأكد', 'قولي': 'قل',
                     'اختاري': 'اختر', 'افتحي': 'افتح', 'استخدمي': 'استخدم',
                     'تقدري': 'تقدر', 'أنتِ': 'أنت', 'قل لي': 'قل لي'}.items():
        text = text.replace(old, new)
    return text


def conversation_policy(language='ar'):
    return ("Respond in English only. Address the user as male. Be concise: answer the requested question, "
        "no repeated welcome, no filler or unsolicited tutorials. One account per heading, one amount and "
        "currency per line. Never sum different currencies. Use all currencies in the provided catalog, "
        "not a memorized eight-currency list. Distinguish available currencies from enabled currencies."
        if language == 'en' else
        'أجب بالعربية فقط وخاطب المستخدم بصيغة المذكر دائمًا. استخدم أسماء العملات العربية دون رموزها الإنجليزية، '
        'ولا تعرض أسماء أدوات أو حقول تقنية أو معرّفات داخلية. أجب على المطلوب باختصار دون ترحيب متكرر أو حشو، '
        'عادة ثلاث إلى ست أسطر إلا إذا طلب التفاصيل أو قائمة كاملة. عنوان لكل حساب، وتحت الحساب سطر مستقل لكل مبلغ '
        'مع عملته. لا تجمع العملات المختلفة ولا تعرض عملية جمع مطولة. كل العملات في الكتالوج متاحة للتخصيص، '
        'والعملات المفعّلة فقط هي المسموحة في التنفيذ. لا تحصر العملات في ثمانٍ. لا تدّع فتح شاشة أو تنفيذ عملية '
        'لمجرد إنشاء زر؛ قل اضغط الزر لفتحها. اسأل سؤالًا واحدًا فقط عند نقص معلومة ضرورية.')


LABELS = {
    'name': ('الاسم', 'Name'), 'amount': ('المبلغ', 'Amount'), 'balance': ('الرصيد الافتتاحي', 'Opening balance'),
    'opening_balance': ('الرصيد الافتتاحي', 'Opening balance'), 'currency': ('العملة', 'Currency'),
    'from_currency': ('عملة المصدر', 'Source currency'), 'to_currency': ('عملة الاستلام', 'Destination currency'),
    'exchange_rate': ('سعر الصرف', 'Exchange rate'), 'destination_amount': ('المبلغ المستلم', 'Received amount'),
    'to_amount': ('المبلغ المستلم', 'Received amount'),
    'description': ('الوصف', 'Description'), 'notes': ('ملاحظات', 'Notes'), 'entries': ('تفاصيل المطابقة', 'Count entries'),
    'actual': ('المبلغ الفعلي', 'Actual amount'), 'expected_system': ('رصيد النظام', 'System balance'),
    'bank_name': ('البنك', 'Bank'), 'account_name': ('اسم الحساب', 'Account name'),
    'account_number': ('رقم الحساب', 'Account number'), 'iban': ('رقم الحساب الدولي', 'IBAN'),
    'account_type': ('نوع الحساب', 'Account type'),
    'enabled_currencies': ('العملات المفعّلة', 'Enabled currencies'), 'party_kind': ('نوع الطرف', 'Party type'),
    'account_id': ('الحساب', 'Account'), 'from_account_id': ('الحساب المرسل', 'Source account'),
    'to_account_id': ('الحساب المستلم', 'Destination account'), 'bank_account_id': ('الحساب البنكي', 'Bank account'),
    'customer_id': ('العميل', 'Customer'), 'supplier_id': ('المورد', 'Supplier'), 'party_id': ('الطرف', 'Party'),
    'branch_id': ('الفرع', 'Branch'), 'quantity': ('الكمية', 'Quantity'), 'unit_price': ('السعر', 'Price'),
    'items': ('الأصناف', 'Items'), 'invoice_type': ('نوع الفاتورة', 'Invoice type'), 'action': ('الإجراء', 'Action'),
}


def preview_fields(body, language='ar', names=None):
    names = names or {}
    fields = []
    for key, value in (body or {}).items():
        if value is None or key in ('token', 'idempotency_key'):
            continue
        label = LABELS.get(key, ('تفصيل العملية', key.replace('_', ' ').title()))[language == 'en']
        if isinstance(value, dict):
            fields += preview_fields(value, language, names)
            continue
        if isinstance(value, list):
            if key == 'enabled_currencies':
                value = '، '.join(currency_name(c, language) for c in value)
            else:
                for index, entry in enumerate(value):
                    if isinstance(entry, dict):
                        fields += preview_fields(entry, language, names)
                continue
        if key.endswith('_id'):
            value = names.get(str(value), 'محدد في الفرع الحالي' if language != 'en' else 'Selected in this branch')
        elif 'currency' in key:
            value = currency_name(value, language)
        elif language != 'en':
            value = {'customer': 'عميل', 'supplier': 'مورد', 'sale': 'بيع', 'purchase': 'شراء',
                     'confirm': 'اعتماد', 'cancel': 'إلغاء', 'checking': 'حساب جارٍ', 'cash': 'نقدي',
                     'savings': 'توفير', 'draft': 'مسودة', 'income': 'دخل', 'expense': 'مصروف'}.get(str(value), value)
        fields.append({'label': label, 'value': str(value)})
    return fields
