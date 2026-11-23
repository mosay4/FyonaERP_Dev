"""
Knowledge Base for FYONA App Assistant "Sara".
Contains structured documentation for all app screens and features.

Each entry may have:
- keywords: list of Arabic search terms (with/without ال, conjugated forms)
- business_only: True for features that belong to the business account only
"""

APP_KNOWLEDGE: dict = {
    # ═══════════════ PERSONAL FINANCE ═══════════════
    "الرئيسية": {
        "description": "الصفحة الرئيسية للقسم الشخصي، تعرض ملخص حساباتك والرصيد الكلي وآخر المعاملات",
        "usage": """
1. تظهر بعد تسجيل الدخول مباشرة في وضع الحساب الشخصي
2. تعرض بطاقات الملخص المالي (الرصيد، الإيرادات، المصروفات)
3. تعرض آخر المعاملات والحسابات البنكية
4. يوجد شريط سفلي للتنقل بين أقسام القسم الشخصي
""",
        "actions": ["عرض الرصيد", "عرض آخر المعاملات", "إضافة معاملة جديدة"],
        "deep_link": "/personal",
        "keywords": ["الرئيسية", "الصفحة الرئيسية", "الصفحة الاولى", "البداية", "داشبورد", "اللوحة"],
        "common_errors": []
    },
    "المحفظة": {
        "description": "إدارة المحفظة المالية الشخصية، عرض الرصيد والإيرادات والمصروفات",
        "usage": """
1. افتح المحفظة من الشريط السفلي في القسم الشخصي
2. يعرض الرصيد الكلي لكل العملات
3. يمكنك تصفية المعاملات حسب الشهر
4. زر (+) لإضافة معاملة جديدة (إيراد أو مصروف)
5. الضغط على معاملة لعرض التفاصيل
""",
        "actions": ["عرض الرصيد", "إضافة معاملة", "تصفية المعاملات", "عرض التقارير"],
        "deep_link": "/personal",
        "keywords": ["محفظة", "رصيد", "فلوس", "مال", "كم معي", "كم عندي", "كم رصيدي"],
        "common_errors": ["عدم ظهور الرصيد الصحيح: تأكد من تحديث الصفحة"]
    },
    "البنوك": {
        "description": "إدارة الحسابات البنكية والمحافظ الرقمية، عرض الأرصدة، إيداع، سحب، وتحويلات بين الحسابات",
        "usage": """
1. افتح البنوك من الشريط السفلي أو من القائمة في القسم الشخصي
2. يعرض قائمة بجميع الحسابات البنكية والمحافظ النقدية
3. كل حساب يعرض اسمه ورصيده وعملته
4. زر (+) لإضافة حساب بنكي جديد — اضغط على إضافة واكتب اسم البنك والعملة
5. اضغط على أي حساب لعرض تفاصيله وكشف حسابه ومعاملاته
6. يمكن عمل إيداع وسحب وتحويل بين الحسابات من داخل أي حساب
""",
        "actions": ["عرض الحسابات", "إضافة حساب بنكي", "إيداع", "سحب", "تحويل", "كشف الحساب"],
        "deep_link": "/personal/banks",
        "keywords": ["بنك", "بنكي", "بنكية", "بنوك", "حساب", "حسابات", "حساب بنكي", "إيداع", "سحب", "تحويل", "كشف حساب", "افتح حساب"],
        "common_errors": ["عدم ظهور الحسابات: تأكد من إضافة بنك أولاً"]
    },
    "الأهداف": {
        "description": "إدارة أهداف الادخار، إنشاء وتتبع التقدم نحو الأهداف المالية",
        "usage": """
1. افتح الأهداف من القائمة أو الشريط السفلي في القسم الشخصي
2. يعرض جميع أهداف الادخار الحالية
3. كل هدف يعرض اسمه والمبلغ المستهدف ونسبة التقدم
4. زر (+) لإنشاء هدف ادخار جديد (الاسم والمبلغ المستهدف)
5. اضغط على أي هدف لعرض التفاصيل وإضافة مبلغ للهدف
""",
        "actions": ["عرض الأهداف", "إنشاء هدف جديد", "إضافة مبلغ لهدف"],
        "deep_link": "/personal/savings",
        "keywords": ["هدف", "أهداف", "ادخار", "توفير", "توفير", "حفظ", "أوفر"],
        "common_errors": []
    },
    "التقارير": {
        "description": "التقارير المالية الشاملة: تقارير الإيرادات والمصروفات والأرباح مع تصدير PDF",
        "usage": """
1. افتح التقارير من القائمة في القسم الشخصي (مركز التقارير)
2. اختر نوع التقرير (إيرادات، مصروفات، أرباح، صافي)
3. حدد الفترة الزمنية
4. يمكن تصدير التقرير بصيغة PDF
5. توجد تقارير إضافية: كشف الحساب، تقرير جميع البنوك، نظرة عامة مالية، لوحة تنفيذية
""",
        "actions": ["عرض التقارير", "تصدير PDF", "تصفية حسب التاريخ", "كشف الحساب", "نظرة عامة مالية"],
        "deep_link": "/personal/reports",
        "keywords": ["تقرير", "تقارير", "تصدير", "PDF", "كشف حساب", "نظرة عامة", "ملخص", "تقرير مالي"],
        "common_errors": []
    },
    "الديون": {
        "description": "إدارة الديون الشخصية، إضافة ديون (لي وعلي) وتتبع المبالغ المستحقة",
        "usage": """
1. افتح الديون من القائمة في القسم الشخصي
2. يعرض قائمة بجميع الديون (لك وعليك)
3. كل دين يعرض المبلغ والحالة والتاريخ
4. زر (+) لإضافة دين جديد (إلى من، المبلغ، هل هو لي أم عليّ)
5. يمكن سداد الدين أو تعديله
""",
        "actions": ["عرض الديون", "إضافة دين جديد", "تسجيل سداد"],
        "deep_link": "/personal/debts",
        "keywords": ["دين", "ديون", "مستحق", "اقتراض", "سلف", "لي وعلي"],
        "common_errors": []
    },
    "المعاملات": {
        "description": "جميع المعاملات المالية مرتبة زمنياً مع إمكانية البحث والتصفية",
        "usage": """
1. افتح المعاملات من القائمة في القسم الشخصي
2. يعرض جميع المعاملات مرتبة من الأحدث للأقدم
3. يمكن البحث والتصفية حسب النوع والتاريخ والفئة
4. اضغط على معاملة لعرض التفاصيل
5. زر (+) لإضافة معاملة جديدة
""",
        "actions": ["عرض المعاملات", "بحث", "تصفية", "إضافة معاملة"],
        "deep_link": "/personal/transactions",
        "keywords": ["معاملة", "معاملات", "حركة", "حركات", "عمليات", "سجل", "بحث في المعاملات"],
        "common_errors": []
    },
    "الميزانية": {
        "description": "إنشاء ميزانية شهرية وتتبع الالتزام بها، وضع حد لكل فئة",
        "usage": """
1. افتح الميزانية من القائمة في القسم الشخصي
2. اضغط على زر (+) لإنشاء ميزانية شهرية جديدة
3. حدد الفئة والمبلغ المخصص لها
4. يعرض التقدم والالتزام بالميزانية ومتى تتجاوز الحد
5. تنبيهات عند تجاوز الميزانية المحددة
""",
        "actions": ["عرض الميزانية", "إنشاء ميزانية جديدة", "تحديد حد لفئة", "تتبع الالتزام"],
        "deep_link": "/personal/budget",
        "keywords": ["ميزانية", "موازنة", "حد", "حد شهري", "التزام", "تخطيط", "خطة"],
        "common_errors": []
    },
    "المعاملات المتكررة": {
        "description": "إدارة المعاملات المتكررة (رواتب، إيجار، اشتراكات) التي تتكرر كل شهر",
        "usage": """
1. افتح المعاملات المتكررة من القائمة في القسم الشخصي
2. يعرض جميع المعاملات المتكررة (مثال: إيجار، اشتراكات، فواتير شهرية)
3. زر (+) لإضافة معاملة متكررة جديدة (المبلغ، التكرار)
4. يمكن تفعيل أو إيقاف أي معاملة متكررة
5. تُضاف تلقائياً في كل فترة
""",
        "actions": ["عرض المعاملات المتكررة", "إضافة معاملة متكررة", "إيقاف معاملة"],
        "deep_link": "/personal/recurring",
        "keywords": ["متكرر", "متكررة", "دوري", "دورية", "شهري", "اشتراك", "إيجار", "أقساط"],
        "common_errors": []
    },
    "التصنيفات": {
        "description": "إدارة تصنيفات المعاملات (طعام، مواصلات، تسوق...) لتنظيم المعاملات",
        "usage": """
1. افتح التصنيفات من القائمة في القسم الشخصي
2. يعرض جميع التصنيفات (طعام، مواصلات، تسوق، إيجار...)
3. زر (+) لإضافة تصنيف جديد
4. يمكن تعديل أو حذف تصنيف
5. تُستخدم التصنيفات في التحليلات والتقارير
""",
        "actions": ["عرض التصنيفات", "إضافة تصنيف", "تعديل تصنيف"],
        "deep_link": "/personal/categories",
        "keywords": ["تصنيف", "تصنيفات", "فئة", "فئات", "أقسام", "صنف"],
        "common_errors": []
    },
    "التحويلات": {
        "description": "تحويل الأموال بين الحسابات البنكية والمحافظ الخاصة بك",
        "usage": """
1. افتح التحويلات من القائمة في القسم الشخصي
2. اختر الحساب المحول منه والحساب المحول إليه
3. أدخل المبلغ واضغط تحويل
4. تظهر المعاملة في الحسابين مباشرة
""",
        "actions": ["تحويل بين حسابات", "عرض التحويلات"],
        "deep_link": "/personal/transfer",
        "keywords": ["تحويل", "تحويلات", "نقل", "حوالة", "بين الحسابات", "حوّل"],
        "common_errors": []
    },
    "سارة": {
        "description": "سارة هي المساعد الذكي في التطبيق، تقدر تسألها عن أي شيء في القسم الشخصي",
        "usage": """
1. افتح سارة من القائمة في القسم الشخصي أو من أي شاشة
2. اكتب سؤالك أو أرسل رسالة صوتية
3. سارة تحلل بياناتك وتجيبك مباشرة
4. تقدر تطلب منها فتح شاشة أو إنشاء شيء أو شرح ميزة
5. كل رد منها فيه اقتراحات للمتابعة
""",
        "actions": ["سؤال نصي", "رسالة صوتية", "فتح شاشة", "شرح ميزة"],
        "deep_link": "/personal/ai",
        "keywords": ["سارة", "مساعد", "مساعد ذكي", "ذكاء اصطناعي", "ai", "مساعدة", "ساعدني", "روبوت", "شات"],
        "common_errors": []
    },
    "الإعدادات": {
        "description": "إعدادات التطبيق، تغيير اللغة، السمة، وإدارة الملف الشخصي",
        "usage": """
1. افتح الإعدادات من القائمة الجانبية
2. يمكن تغيير اللغة والسمة (فاتحة/داكنة)
3. إدارة الملف الشخصي والبيانات
4. ضبط العملة والضرائب وإدارة الملفات
""",
        "actions": ["فتح الإعدادات", "تغيير اللغة", "إدارة الملف الشخصي", "السمة"],
        "deep_link": "/settings",
        "keywords": ["إعدادات", "ضبط", "خيارات", "لغة", "سمة", "مظهر"],
        "common_errors": []
    },
    "الملف الشخصي": {
        "description": "عرض وتعديل المعلومات الشخصية والصورة والبيانات",
        "usage": """
1. افتح الملف الشخصي من الإعدادات أو من القائمة
2. يمكن تغيير الصورة الشخصية
3. تعديل الاسم والبريد الإلكتروني ورقم الجوال
4. تغيير كلمة المرور وإدارة الجلسات
""",
        "actions": ["عرض الملف الشخصي", "تعديل البيانات", "تغيير الصورة"],
        "deep_link": "/profile",
        "keywords": ["ملف", "ملفي", "حسابي", "الملف الشخصي", "بروفايل", "اسمي", "بريدي"],
        "common_errors": []
    },
    "الاشتراك": {
        "description": "إدارة الاشتراك والباقات المتاحة",
        "usage": """
1. افتح الاشتراك من الإعدادات أو القائمة
2. يعرض الباقات المتاحة (شخصي، أعمال، أعمال + شخصي)
3. يمكن الترقية أو الاشتراك في الفترة التجريبية
4. اختيار العملة قبل الدفع
""",
        "actions": ["عرض الباقات", "ترقية الاشتراك", "تفعيل تجريبي"],
        "deep_link": "/subscription",
        "keywords": ["اشتراك", "باقة", "باقات", "خطة", "دفع", "ترقية", "تجريبي", "اشتراكي"],
        "common_errors": []
    },

    # ═══════════════ BUSINESS ONLY ═══════════════
    "العملاء": {
        "description": "إدارة العملاء (لحساب الأعمال)، إضافة وتعديل وحذف العملاء",
        "usage": """
1. افتح العملاء من القائمة (متاح فقط في حساب الأعمال)
2. يعرض قائمة بجميع العملاء
3. زر (+) لإضافة عميل جديد
4. اضغط على عميل لعرض التفاصيل
5. يمكن تعديل وحذف العملاء
""",
        "actions": ["عرض العملاء", "إضافة عميل", "تعديل عميل"],
        "deep_link": "/customers",
        "keywords": ["عميل", "زبون", "عملاء", "زبائن"],
        "common_errors": [],
        "business_only": True
    },
    "المبيعات": {
        "description": "إدارة المبيعات وأوامر البيع (لحساب الأعمال)",
        "usage": """
1. افتح المبيعات من القائمة (متاح فقط في حساب الأعمال)
2. يعرض قائمة أوامر البيع
3. زر (+) لإنشاء أمر بيع جديد
4. يمكن عرض تفاصيل كل أمر
""",
        "actions": ["عرض المبيعات", "إنشاء أمر بيع"],
        "deep_link": "/sales",
        "keywords": ["مبيعات", "بيع", "أمر بيع", "فواتير", "فاتورة", "إيراد المبيعات"],
        "common_errors": [],
        "business_only": True
    },
    "المشتريات": {
        "description": "إدارة المشتريات وأوامر الشراء (لحساب الأعمال)",
        "usage": """
1. افتح المشتريات من القائمة (متاح فقط في حساب الأعمال)
2. يعرض قائمة أوامر الشراء
3. زر (+) لإنشاء أمر شراء جديد
""",
        "actions": ["عرض المشتريات", "إنشاء أمر شراء"],
        "deep_link": "/purchases",
        "keywords": ["مشتريات", "شراء", "أمر شراء", "مورد", "موردين"],
        "common_errors": [],
        "business_only": True
    },
    "الموظفين": {
        "description": "إدارة الموظفين والحضور والرواتب والإجازات (لحساب الأعمال)",
        "usage": """
1. افتح الموظفين من القائمة (متاح فقط في حساب الأعمال)
2. إضافة وتعديل الموظفين
3. تسجيل الحضور والانصراف
4. إدارة الإجازات والرواتب
""",
        "actions": ["عرض الموظفين", "إضافة موظف", "تسجيل حضور", "الرواتب"],
        "deep_link": "/employees",
        "keywords": ["موظف", "موظفين", "حضور", "انصراف", "رواتب", "راتب", "إجازة", "إجازات"],
        "common_errors": [],
        "business_only": True
    },
    "المخزون": {
        "description": "إدارة المخزون والمنتجات (لحساب الأعمال)",
        "usage": """
1. افتح المخزون من القائمة (متاح فقط في حساب الأعمال)
2. يعرض قائمة المنتجات والمخزون
3. يمكن تتبع حركة المخزون
4. تنبيه عند انخفاض المخزون
""",
        "actions": ["عرض المخزون", "إضافة منتج", "تتبع الحركة"],
        "deep_link": "/inventory",
        "keywords": ["مخزون", "منتج", "منتجات", "بضاعة", "stock", "جرد"],
        "common_errors": [],
        "business_only": True
    },
    "المحاسبة": {
        "description": "المحاسبة المالية للشركة: القيود، ميزان المراجعة، الميزانية العمومية، قائمة الدخل (لحساب الأعمال)",
        "usage": """
1. متاح فقط في حساب الأعمال
2. يشمل: دليل الحسابات، القيود اليومية، ميزان المراجعة
3. الميزانية العمومية وقائمة الأرباح والخسائر
4. التقارير المحاسبية والتدفقات النقدية
""",
        "actions": ["القيود اليومية", "ميزان المراجعة", "قائمة الدخل", "الميزانية العمومية"],
        "deep_link": "/accounts",
        "keywords": ["محاسبة", "قيود", "ميزان", "مراجعة", "عمومية", "أرباح", "خسائر", "دخل", "تدفق نقدي"],
        "common_errors": [],
        "business_only": True
    },
}


def get_knowledge(feature: str) -> dict:
    """Get knowledge about a specific feature by name."""
    for name, info in APP_KNOWLEDGE.items():
        if feature.lower() in name.lower():
            return {"name": name, **info}
    for e in EXTRA_SCREENS:
        name_ar, name_en, route, desc_ar, desc_en, kws, biz = e
        if feature.lower() in name_ar.lower() or feature.lower() in name_en.lower():
            return {
                "name": name_ar,
                "description": desc_ar,
                "description_en": desc_en,
                "usage": "",
                "actions": [],
                "deep_link": route,
                "keywords": kws,
                "common_errors": [],
                "business_only": biz,
            }
    return {}


# Business-only markers: if present in a query while in personal mode, skip results
BUSINESS_MARKERS = [
    "موظف", "موظفين", "عميل", "زبون", "عملاء", "زبائن",
    "مبيعات", "بيع", "مشتريات", "شراء", "أمر بيع", "أمر شراء",
    "مخزون", "منتج", "بضاعة", "راتب", "رواتب", "حضور", "انصراف",
    "مورد", "محاسبة", "قيود", "ميزان", "موظفين",
]


def _matches(query: str, info: dict) -> int:
    """Return a score for how well the query matches an entry."""
    q = query.lower()
    score = 0
    name = info.get("name", "")
    if name.lower() in q:
        score += 5
    for kw in info.get("keywords", []):
        kw_l = kw.lower()
        if kw_l in q:
            score += 3
            break
    desc = info.get("description", "")
    if q in desc.lower():
        score += 4
    return score


def search_knowledge(query: str, account_type: str = "personal") -> list:
    """Search knowledge base for relevant features using keyword matching."""
    results = []
    q = query.lower()
    # In personal mode, if the query mentions a business-only feature, return nothing
    # so Sara can tell the user it belongs to the business plan.
    if account_type == "personal" and any(m in q for m in BUSINESS_MARKERS):
        return []
    for name, info in APP_KNOWLEDGE.items():
        # In personal mode, skip business-only features entirely
        if account_type == "personal" and info.get("business_only"):
            continue
        # In business mode, everything is allowed
        entry = {"name": name, **info}
        score = _matches(query, entry)
        # Fallback: check if any word of the query matches the entry text
        if score == 0:
            words = [w for w in q.split() if len(w) > 2]
            text = f"{name} {info.get('description', '')}".lower()
            if any(w in text for w in words):
                score = 1
        if score > 0:
            results.append({"name": name, "score": score, **info})
    results.extend(search_extra_screens(query, account_type=account_type))
    results.sort(key=lambda r: r.get("score", 0), reverse=True)
    return results


def format_knowledge_for_prompt(features: list[str]) -> str:
    """Format selected knowledge entries for the AI prompt."""
    parts = []
    for f in features:
        info = get_knowledge(f)
        if info:
            parts.append(
                f"## {info['name']}\n"
                f"الوصف: {info['description']}\n"
                f"طريقة الاستخدام: {info['usage']}\n"
                f"الإجراءات: {', '.join(info['actions'])}\n"
            )
    return "\n".join(parts) if parts else ""


# ── Intent alias lists (shared with sara_agent_service) ──────────────
INTENT_ALIASES: dict = {
    "المعاملات": ["معاملة", "معاملات", "حركة", "حركات", "عمليات", "إيداع", "سحب", "تحويل", "عملية"],
    "المحفظة": ["محفظة", "رصيد", "فلوس", "مال", "كم معي", "كم عندي", "كم رصيدي", "أموالي", "أرصدة"],
    "البنوك": ["بنك", "بنكي", "بنكية", "بنوك", "حساب بنكي", "كشف حساب", "فتح حساب"],
    "الأهداف": ["هدف", "أهداف", "ادخار", "توفير", "حفظ"],
    "التقارير": ["تقرير", "تقارير", "تصدير", "كشف حساب", "نظرة عامة", "ملخص"],
    "الديون": ["دين", "ديون", "مستحق", "اقتراض", "سلف", "مدين", "دائن"],
    "الميزانية": ["ميزانية", "موازنة", "حد", "حد شهري", "التزام", "تخطيط", "خطة"],
    "المعاملات المتكررة": ["متكرر", "متكررة", "دوري", "دورية", "اشتراك", "إيجار", "أقساط"],
    "التصنيفات": ["تصنيف", "تصنيفات", "فئة", "فئات", "أقسام", "صنف"],
    "التحويلات": ["تحويل", "تحويلات", "نقل", "حوالة"],
    "سارة": ["سارة", "مساعد", "ذكاء اصطناعي", "مساعدة"],
    "الإعدادات": ["إعدادات", "ضبط", "خيارات", "لغة", "سمة"],
    "الملف الشخصي": ["ملف", "ملفي", "حسابي", "الملف الشخصي", "بروفايل", "اسمي", "بريدي"],
    "الاشتراك": ["اشتراك", "باقة", "باقات", "خطة", "دفع", "ترقية", "تجريبي"],
    "العملاء": ["عميل", "زبون", "عملاء", "زبائن"],
    "المبيعات": ["مبيعات", "بيع", "أمر بيع", "فاتورة", "فواتير"],
    "المشتريات": ["مشتريات", "شراء", "أمر شراء", "مورد", "موردين"],
    "الموظفين": ["موظف", "موظفين", "حضور", "انصراف", "رواتب", "راتب", "إجازة", "إجازات"],
    "المخزون": ["مخزون", "منتج", "منتجات", "بضاعة", "جرد"],
    "المحاسبة": ["محاسبة", "قيود", "ميزان", "عمومية", "أرباح", "خسائر", "دخل", "تدفق نقدي"],
}


def find_intent_feature(query: str) -> str | None:
    """Return the best-matching knowledge feature for a navigation/help query."""
    q = query.lower().strip()
    best_name = None
    best_score = 0
    for name, aliases in INTENT_ALIASES.items():
        score = 0
        if name.lower() in q:
            score += 5
        for a in aliases:
            if a.lower() in q:
                score += 3
                break
        if score > best_score:
            best_score = score
            best_name = name
    return best_name if best_score > 0 else None


# ── Knowledge Graph ─────────────────────────────────────────────
# Maps each feature to the entities it touches and its neighbours,
# so Sara can answer cross-feature questions (customer ↔ invoices ↔
# products ↔ inventory ↔ profit ↔ reports).
KNOWLEDGE_GRAPH: dict = {
    "الرئيسية": {
        "entities": ["الحسابات", "المعاملات", "الرصيد"],
        "links": ["المحفظة", "البنوك", "المعاملات"],
    },
    "المحفظة": {
        "entities": ["الحسابات", "المعاملات", "الرصيد", "العملات"],
        "links": ["المعاملات", "البنوك", "التصنيفات", "التحليلات", "الميزانية", "التقارير"],
    },
    "البنوك": {
        "entities": ["الحسابات البنكية", "المحافظ", "الأرصدة", "المعاملات", "التحويلات"],
        "links": ["المعاملات", "التحويلات", "التحليلات", "كشف الحساب", "التقارير"],
    },
    "المعاملات": {
        "entities": ["الإيداعات", "السحوبات", "التحويلات", "الفئات", "المبالغ"],
        "links": ["البنوك", "المحفظة", "التصنيفات", "التحليلات", "الميزانية", "الديون"],
    },
    "التصنيفات": {
        "entities": ["الفئات", "الأقسام", "التصنيفات"],
        "links": ["المعاملات", "التحليلات", "الميزانية"],
    },
    "التحليلات": {
        "entities": ["الإنفاق", "المصروفات", "الإيرادات", "النسب", "الاتجاهات"],
        "links": ["المعاملات", "التصنيفات", "المحفظة", "التقارير", "الميزانية"],
    },
    "الميزانية": {
        "entities": ["الحدود الشهرية", "الالتزام", "الفئات"],
        "links": ["المعاملات", "التصنيفات", "التحليلات", "التقارير"],
    },
    "الأهداف": {
        "entities": ["أهداف الادخار", "التقدم", "المبالغ المستهدفة"],
        "links": ["المحفظة", "المعاملات", "التحليلات", "التقارير"],
    },
    "الديون": {
        "entities": ["الديون", "المستحقات", "المبالغ", "الحالة"],
        "links": ["المعاملات", "المحفظة", "التحليلات", "التقارير"],
    },
    "المعاملات المتكررة": {
        "entities": ["الاشتراكات", "الإيجار", "الرواتب", "التكرار"],
        "links": ["المعاملات", "المحفظة", "الميزانية"],
    },
    "التحويلات": {
        "entities": ["الحساب المحول منه", "الحساب المحول إليه", "المبالغ"],
        "links": ["البنوك", "المعاملات", "المحفظة"],
    },
    "التقارير": {
        "entities": ["الإيرادات", "المصروفات", "الأرباح", "كشف الحساب", "ملخص"],
        "links": ["المعاملات", "البنوك", "التحليلات", "الميزانية", "الأهداف", "الديون"],
    },
    "سارة": {
        "entities": ["المحادثة", "الأسئلة", "الأوامر"],
        "links": ["كل الميزات"],
    },
    "الإعدادات": {
        "entities": ["اللغة", "السمة", "الملف الشخصي"],
        "links": ["الملف الشخصي", "الاشتراك"],
    },
    "الملف الشخصي": {
        "entities": ["الاسم", "البريد", "الجوال", "الصورة"],
        "links": ["الإعدادات", "الاشتراك"],
    },
    "الاشتراك": {
        "entities": ["الباقات", "الخطط", "الدفع"],
        "links": ["الإعدادات", "الملف الشخصي"],
    },
    "العملاء": {
        "entities": ["العملاء", "المبيعات", "الفواتير", "التحصيل"],
        "links": ["المبيعات", "الديون", "التقارير", "المحاسبة"],
    },
    "المبيعات": {
        "entities": ["أوامر البيع", "الفواتير", "العملاء", "الإيرادات"],
        "links": ["العملاء", "المخزون", "المنتجات", "التقارير", "المحاسبة"],
    },
    "المشتريات": {
        "entities": ["أوامر الشراء", "الموردون", "الفواتير", "المصروفات"],
        "links": ["الموردون", "المخزون", "المحاسبة", "التقارير"],
    },
    "المخزون": {
        "entities": ["المنتجات", "الكميات", "الأصناف", "حركة المخزون"],
        "links": ["المبيعات", "المشتريات", "التقارير", "المحاسبة"],
    },
    "الموظفين": {
        "entities": ["الموظفون", "الرواتب", "الحضور", "الإجازات"],
        "links": ["التقارير", "المحاسبة"],
    },
    "المحاسبة": {
        "entities": ["القيود", "ميزان المراجعة", "العمومية", "الدخل"],
        "links": ["العملاء", "المبيعات", "المشتريات", "المخزون", "التقارير"],
    },
}


def format_relationships_for_prompt(feature: str) -> str:
    """Format knowledge-graph relationships for a feature."""
    node = KNOWLEDGE_GRAPH.get(feature)
    if not node:
        return ""
    links = ", ".join(node.get("links", []))
    entities = ", ".join(node.get("entities", []))
    return (
        f"[العلاقات] {feature} ترتبط بـ: {links}. "
        f"تتعلق بـ: {entities}."
    )


# ═══════════════════════════════════════════════════════════════════
#  FULL APP SCREEN CATALOG — every navigable section/feature.
#  Format: (name_ar, name_en, route, desc_ar, desc_en, keywords, business_only)
#  Sara uses this to explain any section/button and to open it by name or
#  route (open_app_screen). The app also streams its own live catalog with
#  each query, so newly-added screens are discoverable without a backend
#  update.
# ═══════════════════════════════════════════════════════════════════
EXTRA_SCREENS: list = [
    ("الرئيسية الشخصية", "Personal Home", "/personal", "ملخص أموالك: الرصيد والدخل والمصروف والأهداف", "Money summary: balance, income, expenses and goals", ["الرئيسية", "الشخصية", "البداية"], False),
    ("لوحة التحكم", "Dashboard", "/dashboard", "ملخص مبيعاتك ومصروفاتك وأهم مؤشرات عملك", "Overview of sales, expenses and key business indicators", ["لوحة", "داشبورد", "الرئيسية"], True),
    ("لوحة العملاء", "Customers Board", "/crm-dashboard", "نظرة على العملاء والفرص والمهام", "A view of customers, opportunities and tasks", ["لوحة العملاء", "العملاء"], True),
    ("لوحة المشاريع", "Projects Board", "/projects-dashboard", "نظرة على المشاريع وتقدمها ومواعيدها", "A view of projects, progress and deadlines", ["لوحة المشاريع", "المشاريع"], True),
    ("التحويل", "Transfer", "/personal/transfer", "حوّل بين حساباتك مع احتساب سعر الصرف تلقائياً", "Move money between accounts with automatic FX conversion", ["تحويل", "حوالة", "نقل"], False),
    ("التحليلات", "Analytics", "/personal/analytics", "رسوم بيانية تلخّص دخلك ومصروفك وتطور رصيدك", "Charts summarising income, expenses and balance trends", ["تحليلات", "رسوم", "إحصاء"], False),
    ("مركز التقارير", "Reports Center", "/personal/reports-center", "كل تقاريرك المالية في مكان واحد", "All your financial reports in one place", ["مركز التقارير", "التقارير"], False),
    ("شجرة الحسابات", "Account Tree", "/personal/account-tree", "عرض هرمي لحساباتك وأرصدتها", "A hierarchical view of your accounts and balances", ["شجرة", "شجرة الحسابات"], False),
    ("الشجرة المالية", "Financial Tree", "/personal/financial-tree", "خريطة شاملة لأصولك وخصومك", "A full map of your assets and liabilities", ["الشجرة المالية", "أصول", "خصوم"], False),
    ("الملخص التنفيذي", "Executive Summary", "/personal/executive", "أهم مؤشراتك المالية في صفحة واحدة", "Your key financial indicators on one page", ["تنفيذي", "ملخص"], False),
    ("كشف الحساب", "Bank Statement", "/personal/bank-statement", "كشف بكل حركات الحساب خلال فترة", "All account movements for a chosen period", ["كشف", "كشف حساب", "بيان"], False),
    ("تقرير جميع البنوك", "All Banks Report", "/personal/all-banks-report", "مقارنة أرصدة وحركات جميع حساباتك", "Compare balances and movements across all accounts", ["جميع البنوك", "تقرير البنوك"], False),
    ("النظرة المالية", "Finance Overview", "/personal/finance-overview", "ملخص شامل لوضعك المالي", "A complete summary of your financial position", ["نظرة", "نظرة مالية"], False),
    ("النسخ الاحتياطي", "Backup", "/personal/backup", "أنشئ نسخة من بياناتك أو استعد نسخة سابقة", "Create a backup of your data or restore a previous one", ["نسخة", "احتياطي", "استعادة", "باك اب"], False),
    ("تصميم الإيصال", "Receipt Design", "/personal/receipt-design", "خصّص شكل الفواتير والإيصالات", "Customise the look of invoices and receipts", ["تصميم", "إيصال", "فاتورة"], False),
    ("الموردون", "Suppliers", "/suppliers", "بيانات الموردين ومشترياتك ومستحقاتهم", "Supplier records, your purchases and their dues", ["مورد", "موردين", "موردون"], True),
    ("المنتجات", "Products", "/products", "كتالوج المنتجات بالأسعار والكميات والباركود", "Product catalogue with prices, quantities and barcodes", ["منتج", "منتجات", "صنف", "أسعار"], True),
    ("المدفوعات", "Payments", "/payments", "دفعات مسجلة على الفواتير والمستندات", "Payments recorded against invoices and documents", ["دفع", "مدفوعات", "سداد"], True),
    ("المصروفات", "Expenses", "/expenses", "تسجيل ومتابعة مصروفات النشاط", "Record and track business expenses", ["مصروف", "مصروفات", "نفقات"], True),
    ("دليل الحسابات", "Chart of Accounts", "/accounts", "دليل الحسابات المحاسبية المستخدم في القيود", "The chart of accounts used in journal entries", ["دليل الحسابات", "حسابات"], True),
    ("اليومية", "Journal", "/journal", "قيود اليومية (مدين ودائن) لكل العمليات", "Daily journal entries (debit and credit)", ["يومية", "قيود", "قيد"], True),
    ("دفتر الأستاذ", "Ledger", "/ledger", "حركات كل حساب مرتبة زمنياً مع رصيده", "All movements of each account in order with its balance", ["أستاذ", "دفتر"], True),
    ("ميزان المراجعة", "Trial Balance", "/trial-balance", "أرصدة الحسابات المدينة والدائنة", "Debit and credit balances to verify they balance", ["ميزان", "مراجعة"], True),
    ("الأرباح والخسائر", "Profit & Loss", "/profit-loss", "الإيرادات مقابل المصروفات وصافي الربح", "Revenues versus expenses and net profit", ["أرباح", "خسائر", "دخل"], True),
    ("الميزانية العمومية", "Balance Sheet", "/balance-sheet", "الأصول والخصوم وحق الملكية", "Assets, liabilities and equity", ["عمومية", "ميزانية عمومية"], True),
    ("التدفقات النقدية", "Cash Flow", "/cashflow", "حركة النقد الداخل والخارج خلال فترة", "Cash in and out during a period", ["تدفق", "نقدية", "كاش"], True),
    ("السنوات المالية", "Fiscal Years", "/fiscal-years", "إدارة الفترات المحاسبية وإغلاقها", "Manage and close accounting periods", ["سنة مالية", "فترات"], True),
    ("التحويل البنكي", "Bank Transfer", "/banks/transfer", "نقل مبلغ بين حسابين بنكيين", "Move an amount between two bank accounts", ["تحويل بنكي", "حوالة"], True),
    ("الكشف البنكي", "Bank Statement", "/banks/statement", "كشف حركات الحساب البنكي", "Bank account movements for a period", ["كشف بنكي", "كشف"], True),
    ("الشيكات", "Cheques", "/cheques", "تسجيل الشيكات الواردة والصادرة وتحصيلها", "Register incoming and outgoing cheques and track collection", ["شيك", "شيكات"], True),
    ("الحضور", "Attendance", "/attendance", "تسجيل حضور وغياب الموظفين", "Daily employee attendance and absence", ["حضور", "غياب", "انصراف"], True),
    ("الإجازات", "Leaves", "/leaves", "طلبات الإجازات وأرصدتها", "Leave requests and balances", ["إجازة", "إجازات"], True),
    ("الرواتب", "Payroll", "/payroll", "مسيّرات الرواتب والبدلات والخصومات", "Payroll runs with allowances and deductions", ["راتب", "رواتب", "مرتب"], True),
    ("العقود", "Contracts", "/contracts", "عقود الموظفين ومددها وتواريخ انتهائها", "Contracts with durations and end dates", ["عقد", "عقود"], True),
    ("الأصول الثابتة", "Fixed Assets", "/fixed-assets", "الأصول طويلة الأجل واستهلاكها", "Long-term assets and their depreciation", ["أصول ثابتة", "استهلاك"], True),
    ("تقرير المبيعات", "Sales Report", "/sales-report", "فواتير البيع والتحصيل حسب الفترة والعميل", "Sales invoices and collection by period and customer", ["تقرير المبيعات"], True),
    ("تقارير الأعمال", "Reports", "/reports", "مركز التقارير المالية والتشغيلية للأعمال", "Business financial and operational reports center", ["تقارير", "تقارير الأعمال"], True),
    ("تقرير المشتريات", "Purchase Report", "/purchase-report", "فواتير الشراء والمدفوعات للموردين", "Purchase invoices and supplier payments", ["تقرير المشتريات"], True),
    ("تقرير التدفقات", "Cash Flow Report", "/cashflow-report", "حركة النقد الداخل والخارج", "Cash in and out during a period", ["تقرير التدفق"], True),
    ("أعمار الديون", "Debt Aging", "/debt-aging", "تصنيف الديون حسب مدة التأخر", "Debts classified by how long they are overdue", ["أعمار", "متأخرة"], True),
    ("التقرير المقارن", "Comparative Report", "/comparative-report", "مقارنة الأداء بين فترتين", "Compare performance between two periods", ["مقارن", "مقارنة"], True),
    ("تقرير مخصص", "Custom Report", "/custom-report", "أنشئ تقريراً بحقول وشروط تختارها", "Build a report with fields and conditions you choose", ["تقرير مخصص"], True),
    ("كشف حساب طرف", "Statement", "/statement", "كشف حركات طرف أو حساب خلال فترة", "Movements of a party or account for a period", ["كشف حساب", "كشف"], True),
    ("تقارير الموارد البشرية", "HR Reports", "/hr-reports", "تقارير الرواتب والحضور والعقود", "Payroll, attendance and contract reports", ["تقارير الموظفين", "موارد بشرية"], True),
    ("بيانات الشركة", "Company Profile", "/settings/company", "اسم الشركة وشعارها وبيانات التواصل", "Company name, logo and contact details", ["بيانات الشركة", "شعار"], True),
    ("الضرائب", "Taxes", "/settings/taxes", "إعدادات الضريبة المطبقة على مستنداتك", "Tax settings applied to your documents", ["ضريبة", "ضرائب"], True),
    ("العملات", "Currencies", "/settings/currencies", "إدارة العملات وأسعار الصرف", "Manage currencies and exchange rates", ["عملة", "عملات", "صرف"], True),
    ("المستخدمون", "Users", "/users", "إدارة مستخدمي النظام وأدوارهم وصلاحياتهم", "Manage system users, roles and permissions", ["مستخدم", "مستخدمين", "صلاحيات"], True),
    ("الدعوات", "Invitations", "/invitations", "دعوة أعضاء جدد لفريقك", "Invite new members to join your team", ["دعوة", "دعوات", "فريق"], True),
    ("الجلسات", "Sessions", "/sessions", "الأجهزة المسجّلة في حسابك وإدارتها", "Devices signed into your account and their management", ["جلسات", "أجهزة"], False),
    ("التخصيص", "Customisation", "/settings/customization", "تخصيص ألوان وشكل التطبيق", "Customise app colours and look", ["تخصيص", "ألوان"], False),
    ("الاستيراد", "Import", "/import", "استيراد بياناتك من ملفات Excel أو CSV", "Import your data from Excel or CSV files", ["استيراد", "ملف"], True),
    ("الاستيراد الذكي", "Smart Import", "/data-import/smart-import", "استيراد ذكي يتعرّف على الأعمدة تلقائياً", "Smart import that detects columns automatically", ["استيراد ذكي"], True),
    ("سارة", "Sara", "/ai", "مساعدك الذكي للمحادثة والتحليل والتسجيل السريع", "Your AI assistant for chat, analysis and quick recording", ["سارة", "المساعد", "ذكاء"], False),
    ("اقتراحات سارة", "Sara Suggestions", "/ai-suggestions", "اقتراحات ذكية مبنية على بياناتك", "Smart suggestions based on your data", ["اقتراحات", "توصيات"], False),
    ("الاقتراحات", "Suggestions", "/suggestions", "أفكار وتوصيات لتحسين وضعك المالي", "Ideas and recommendations to improve your finances", ["اقتراح", "توصية"], False),
    ("نقطة البيع", "Point of Sale", "/pos", "شاشة البيع السريع مع الطباعة والدفع", "Quick-sale screen with printing and payment", ["نقطة بيع", "كاشير", "POS"], True),
    ("الفواتير المتكررة", "Recurring Invoices", "/recurring-invoices", "فواتير تُنشأ وتُرسل تلقائياً حسب جدول", "Invoices created and sent automatically on schedule", ["فواتير متكررة", "متكررة"], True),
    ("المشاريع", "Projects", "/projects", "إدارة المشاريع والمهام والتقدم", "Manage projects, tasks and progress", ["مشروع", "مشاريع", "مهام"], True),
    ("إعدادات البريد", "Email Settings", "/email/settings", "ضبط بريد الإرسال الخاص بالنظام", "Configure the system outgoing email", ["بريد", "إيميل"], True),
    ("سجل البريد", "Email Logs", "/settings/email-logs", "سجل الرسائل المرسلة من النظام", "Log of messages sent by the system", ["سجل البريد"], True),
    ("إنشاء رسالة", "Compose Email", "/email/compose", "كتابة وإرسال رسالة بريدية", "Write and send an email message", ["رسالة", "بريد"], True),
    ("استوديو التصميم", "Design Studio", "/design-studio", "تصميم الفواتير والتقارير بهويتك", "Design invoices and reports with your branding", ["استوديو", "تصميم"], True),
    ("الباقات والاشتراك", "Plans & Subscription", "/subscription", "باقتك الحالية والباقات المتاحة وتجديدها", "Your current plan, available plans and renewal", ["اشتراك", "باقة", "تجديد", "ترقية"], False),
    ("فاتورة الاشتراك", "Subscription Invoice", "/subscription/invoice", "فاتورة اشتراكك مع التنزيل والمشاركة", "Your subscription invoice with download and share", ["فاتورة الاشتراك"], False),
    ("تحديث بطاقة التجديد", "Update Renewal Card", "/subscription/update-card", "تحديث بطاقة التجديد التلقائي", "Update the auto-renewal card", ["بطاقة", "تجديد"], False),
    ("تسجيل الدخول", "Sign In", "/login", "الدخول إلى حسابك", "Sign into your account", ["دخول", "تسجيل"], False),
    ("إنشاء حساب", "Register", "/register", "إنشاء حساب جديد", "Create a new account", ["تسجيل", "حساب جديد"], False),
    ("تأكيد البريد", "Verify Email", "/verify-email", "تأكيد بريدك الإلكتروني", "Verify your email", ["تأكيد", "بريد"], False),
    ("نسيت كلمة المرور", "Forgot Password", "/forgot-password", "استعادة كلمة المرور", "Recover your password", ["نسيت", "كلمة المرور"], False),
    ("تغيير كلمة المرور", "Change Password", "/change-password", "تعيين كلمة مرور جديدة", "Set a new password", ["تغيير كلمة المرور"], False),
]


def all_screens() -> list:
    """Complete screen catalog: knowledge entries + supplemental screens."""
    out: dict = {}
    for name, info in APP_KNOWLEDGE.items():
        route = (info.get("deep_link") or "").strip()
        key = route or name
        if key in out:
            continue
        out[key] = {
            "name_ar": name,
            "name_en": info.get("name_en") or name,
            "route": route,
            "desc_ar": info.get("description", ""),
            "desc_en": info.get("description_en") or info.get("description", ""),
            "business_only": bool(info.get("business_only")),
        }
    for (name_ar, name_en, route, desc_ar, desc_en, _kws, biz) in EXTRA_SCREENS:
        key = route or name_ar
        if key in out:
            continue
        out[key] = {
            "name_ar": name_ar,
            "name_en": name_en,
            "route": route,
            "desc_ar": desc_ar,
            "desc_en": desc_en,
            "business_only": biz,
        }
    return list(out.values())


def all_routes() -> set:
    """Every route Sara is allowed to open (no hallucinated screens)."""
    return {s["route"] for s in all_screens() if s.get("route")}


def search_extra_screens(query: str, account_type: str = "personal") -> list:
    """Keyword search over the supplemental screen catalog."""
    q = query.lower()
    results = []
    for (name_ar, name_en, route, desc_ar, desc_en, kws, biz) in EXTRA_SCREENS:
        if account_type == "personal" and biz:
            continue
        score = 0
        if name_ar.lower() in q or name_en.lower() in q:
            score += 5
        for kw in kws:
            if kw.lower() in q:
                score += 3
                break
        if score > 0:
            results.append({
                "name": name_ar,
                "name_en": name_en,
                "score": score,
                "description": desc_ar,
                "description_en": desc_en,
                "usage": "",
                "actions": [],
                "deep_link": route,
                "keywords": kws,
                "common_errors": [],
                "business_only": biz,
            })
    return results


def format_app_catalog_for_prompt(extra_screens: list | None = None) -> str:
    """Compact full-app map for the prompt: every section + its route.

    `extra_screens` is the live catalog streamed by the installed app
    (route/title/summary), so screens added in newer app builds are known
    to Sara without any backend change.
    """
    lines = []
    seen: set = set()
    for s in all_screens():
        route = (s.get("route") or "").strip()
        if not route or route in seen:
            continue
        seen.add(route)
        lines.append(f"- {s['name_ar']} ({route}): {s['desc_ar']}")
    for e in (extra_screens or []):
        try:
            route = str(e.get("route") or "").strip()
            name = str(e.get("title") or e.get("name") or "").strip()
            desc = str(e.get("summary") or e.get("description") or "").strip()
        except Exception:
            continue
        if not route or route in seen or not name:
            continue
        seen.add(route)
        lines.append(f"- {name} ({route}): {desc}")
    return "\n".join(lines)
