# 📋 خطة إكمال FYONA ERP — 100%

> الإصدار: 1.0 — 2026-08-07
> مبنيّة على أرقام فعلية: 285 مسار Backend، 191 شاشة Flutter، 45 Service فلتر، 17 Service Backend.

---

## 🎯 الوضع الحالي الحقيقي

| المعيار | الحالي | النسبة |
|---------|--------|--------|
| مسارات Backend (`app/api/v1/*.py`) | 285 | ~95% |
| شاشات Flutter (`features/*/presentation/pages`) | 191 | ~95% |
| Services Flutter (`features/*/domain/services`) | 45 | ~80% |
| Services Backend (`app/domain/services`) | 17 ملف | ~65% |
| **التكامل Flutter ↔ Backend API** | جزئي (التمويل الشخصي محلي فقط) | ~55% |
| الاختبارات | 197 pytest + 10 ملف Flutter | ~65% |
| التصدير (XLSX/PDF) | ناقص | ~50% |
| الوثائق (GAP/ROADMAP/API_INTEGRATION) | قديمة | ~40% |

---

## 🔴 المرحلة أ — التكامل (أعلى قيمة) — 5 أيام

**الهدف:** كل شاشة في Flutter تعمل على الـ Backend الحي، لا mock أو بيانات محلية معزولة.

| اليوم | المهمة | الملفات المستهدفة |
|-------|--------|-------------------|
| 1 | ربط التمويل الشخصي بـ `/personal/finance/*` (30 endpoint جاهزة) مع وضع Offline احتياطي | `lib/features/personal/**` ← `backend/app/api/v1/personal_finance.py` |
| 2 | محاذاة `admin_service.dart` مع endpoints الـ admin الجديدة (DB) | `lib/features/admin/domain/services/admin_service.dart` ← `backend/app/api/v1/admin.py` |
| 3 | تدقيق الـ 45 service (API / محلي / وهمي) وربط الناقص | `lib/features/*/domain/services/*.dart` |
| 4 | ربط شاشات HR (attendance/leaves/payroll/contracts/fixed_assets) بالـ API | `lib/features/{attendance,leaves,payroll,contracts,fixed_assets}/**` |
| 5 | اختبار تكاملي شامل: تسجيل → عميل → فاتورة → تقرير عبر API حي | `test/integration/**` |

**معيار الإنجاز:** لا يوجد أي service فلتر يعتمد على بيانات وهمية ميتة.

---

## 🟠 المرحلة ب — إكمال طبقة Business Services (Backend) — 6 أيام

**الهدف:** تقليل منطق الـ routers ونقله إلى services بنمط موحد `Service → Repository → Router`.

ناقص (~20 ملف) في `backend/app/domain/services/`:

| # | الـ Service | الوظيفة |
|---|-------------|---------|
| 1 | `contract_service.py` | العقود والتجديد |
| 2 | `cheque_service.py` | الشيكات |
| 3 | `backup_service.py` | النسخ الاحتياطي |
| 4 | `trash_service.py` | سلة المهملات |
| 5 | `api_key_service.py` | مفاتيح API |
| 6 | `quota_manager.py` | الحصص والحدود |
| 7 | `circuit_breaker.py` | قاطع الدائرة |
| 8 | `cache_service.py` | Redis cache |
| 9 | `file_service.py` | إدارة الملفات |
| 10 | `custom_field_service.py` | الحقول المخصصة |
| 11 | `export_service.py` | تصدير البيانات (XLSX) |
| 12 | `report_export_service.py` | تصدير التقارير (PDF) |
| 13 | `smart_import_service.py` | الاستيراد الذكي |
| 14 | `recurring_invoice_service.py` | الفواتير المتكررة |
| 15 | `invitation_service.py` | دعوات المستخدمين |
| 16 | `user_preferences_service.py` | تفضيلات المستخدم |
| 17 | `cash_service.py` | الخزينة النقدية |
| 18 | `settings_service.py` | إعدادات المؤسسة |
| 19 | `organization_service.py` | إدارة المؤسسات |
| 20 | `permission_service.py` | الصلاحيات |

**معيار الإنجاز:** كل service باختبار unit أخضر + مسجّل في `app/main.py` إن لزم.

---

## 🟡 المرحلة ج — الاختبارات والجودة — 5 أيام

| # | المهمة |
|---|--------|
| 1 | إصلاح الـ 20 فشلاً في acceptance (حزم M5: security/stability/tool_conflict/quality benchmark) |
| 2 | اختبارات API للـ routes الجديدة (personal_finance + admin DB) |
| 3 | Widget tests لشاشات Flutter الجديدة (هدف +40 اختباراً) |
| 4 | `flutter analyze` بدون errors + إصلاح deprecations |
| 5 | `pytest` كامل أخضر (0 فشل) — معاملة مشكلة Python 3.14 capture |

**معيار الإنجاز:** `flutter analyze` نظيف، `flutter test` ناجح، `pytest` بلا أخطاء حمراء.

---

## 🟢 المرحلة د — التصدير والتقارير — 3 أيام

| # | المهمة |
|---|--------|
| 1 | تصدير **XLSX** (Excel) للتقارير: عملاء، مبيعات، مشتريات، مخزون، رواتب |
| 2 | تصدير **PDF** للفواتير والإيصالات والتقارير المالية |
| 3 | شاشة «معاينة الإيصال» بعد إنشاء الفاتورة |

---

## 🔵 المرحلة هـ — الميزات المتبقية — 4 أيام

| # | المهمة |
|---|--------|
| 1 | **POS** نقطة البيع (سلة، خصم، إيصال) |
| 2 | **AI Assistant + AI Suggestions** (ربط `OPENAI_API_KEY` الموجود في `.env`) |
| 3 | **Subscription Payments** (دفع/تجديد/ترقية) |
| 4 | **Notification Settings** + إكمال Custom Report Builder |

---

## ⚫ المرحلة و — الاستقرار والإطلاق — 3 أيام

| # | المهمة |
|---|--------|
| 1 | توثيق واختبار إجراء استعادة Docker (تجمّد CLI) |
| 2 | تحديث `GAP_ANALYSIS.md` / `ROADMAP_100.md` / `API_INTEGRATION.md` بالأرقام الفعلية |
| 3 | Build APK release نهائي + smoke test كامل |

---

## 📅 الجدول الزمني

| المرحلة | المدة | نسبة الإكمال بعدها |
|---------|-------|--------------------|
| أ — التكامل | 5 أيام | ~90% |
| ج — الاختبارات | 5 أيام | ~93% |
| ب — Services | 6 أيام | ~96% |
| د — التصدير | 3 أيام | ~98% |
| هـ — الميزات | 4 أيام | ~99% |
| و — الإطلاق | 3 أيام | ~100% |
| **المجموع** | **~26 يوم عمل** | **100%** |

> ملاحظة: تنفيذ المراحل أ ثم ج أولاً يرفع الجاهزية التشغيلية لـ ~95% بسرعة، لأن ~70% من الشاشات منجزة فعلياً.

---

## ✅ معايير الإنجاز النهائي (Definition of Done)

1. كل شاشة تنجز عبر API حي — لا mock ميت.
2. `pytest` كامل أخضر (0 فشل) + `flutter analyze` نظيف + `flutter test` ناجح.
3. تصدير XLSX وPDF يعملان فعلياً.
4. الوثائق الثلاث محدّثة بنسب حقيقية.
5. APK release مبني ويجتاز smoke test على جهاز/مُحاكي.

---

## 🗂 الملفات المرجعية

- الحالة: `GAP_ANALYSIS.md` (يحتاج تحديثاً بالأرقام الفعلية)
- الخطة السابقة: `ROADMAP_100.md`
- الـ API الموثّق: `API_INTEGRATION.md`
- الجداول الحية: `backend/docker-compose.yml`، `backend/app/core/database.py`
