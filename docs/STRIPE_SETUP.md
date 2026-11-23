# دليل إعداد الدفع الإلكتروني (Stripe)

دليل إعداد وتفعيل الدفع بالبطاقة عبر **Stripe** في نظام FYONA (Backend FastAPI + Flutter).

## نظرة عامة

- **Backend** هو مصدر الحقيقة الوحيد: إنشاء Checkout Sessions، التحقق من Webhooks،
  تفعيل الاشتراكات. `app/domain/services/payment_service.py`.
- **المفاتيح السرية لا توجد أبداً داخل تطبيق Flutter** — تُخزَّن مشفّرة (Fernet) في جدول
  `app_config` أو عبر متغيرات البيئة.
- **Flutter** يفتح رابط الدفع الآمن فقط عبر `url_launcher` ويعرض الباقات والحالة.

## الخطوات

### 1. أنشئ حساب Stripe واحصل على المفاتيح

1. سجّل في [Stripe Dashboard](https://dashboard.stripe.com).
2. فعّل **Test mode** من المفاتيح.
3. من *Developers → API keys* احصل على:
   - `Publishable key` (يبدأ بـ `pk_test_`)
   - `Secret key` (يبدأ بـ `sk_test_`)
4. من *Developers → Webhooks* أنشئ endpoint جديداً (أضف المفتاح `whsec_` لاحقاً).

### 2. هيّئ متغيرات البيئة (اختياري — أو استخدم لوحة التحكم)

في بيئة الخادم:

```env
STRIPE_ENABLED=true
STRIPE_MODE=test
STRIPE_CURRENCY=SAR
STRIPE_PUBLISHABLE_KEY=pk_test_xxxx
STRIPE_SECRET_KEY=sk_test_xxxx
STRIPE_WEBHOOK_SECRET=whsec_xxxx
```

> يمكنك بدلاً من ذلك تكوين كل شيء من لوحة التحكم في التطبيق
> (الإعدادات ← الدفع الإلكتروني) — تُحفظ القيم مشفّرة في قاعدة البيانات.

### 3. أنشئ المنتجات والأسعار في Stripe

لكل باقة (شخصية / أعمال / بريميوم) أنشئ **Product** واحداً و**Price** سنوي + **Price** شهري:

1. *Products → Add product* → اسم الباقة، العملة (مثلاً SAR).
2. أضف سعرين للباقة: **سنوي** و**شهري**.
3. انسخ المعرّفات:
   - `prod_...` (معرف المنتج)
   - `price_...` (معرف السعر السنوي)
   - `price_...` (معرف السعر الشهري)

### 4. اربط الباقات بالأسعار

من **لوحة تحكم FYONA ← الإعدادات ← الدفع الإلكتروني ← ربط الباقات بأسعار Stripe**:

| الحقل | مثال |
|---|---|
| معرف المنتج | `prod_xxxxxxxx` |
| معرف سعر شهري | `price_1xxxxxxx` |
| معرف سعر سنوي | `price_1xxxxxxx` |

اضغط "حفظ الباقة" لكل باقة.

### 5. هيّئ Webhook في Stripe

من **Stripe Dashboard → Developers → Webhooks → Add endpoint**:

- **URL**: `{API_BASE_URL}/api/v1/payments/stripe/webhook`
  (مثال محلي: `http://127.0.0.1:8001/api/v1/payments/stripe/webhook`)
- **الأحداث (events)**:
  - `checkout.session.completed`
  - `invoice.payment_failed`
  - `charge.refunded`
  - `customer.subscription.updated`
  - `customer.subscription.deleted`

بعد الحفظ، انسخ **Signing secret** (يبدأ بـ `whsec_`) وضعه في إعدادات FYONA
(أو في متغير البيئة `STRIPE_WEBHOOK_SECRET`).

### 6. فعّل الدفع واختبره

1. في **الدليل**: الإعدادات ← الدفع الإلكتروني:
   - فعّل "الدفع عبر Stripe".
   - ضع المفاتيح (إذا لم تكن عبر البيئة).
   - اضغط **اختبار الاتصال** → يجب أن يظهر "الاتصال بـ Stripe ناجح".
2. اضغط **حفظ الإعدادات**.

### 7. اختبر دورة الدفع في التطبيق

1. سجّل دخول مستخدم عادي.
2. من صفحة الباقات اضغط **"الدفع بالبطاقة"**.
3. اختر باقة وفترة (شهري/سنوي) ثم **ادفع الآن**.
4. في صفحة Stripe استخدم بطاقة اختبار: `4242 4242 4242 4242`
   - أي تاريخ مستقبلي، أي CVC، أي ZIP.
5. بعد العودة اضغط **"تحديث حالة الاشتراك"** — يجب أن تصبح الحالة نشطة
   (بعد وصول الـ webhook، خلال ثوانٍ).

## تدفق العمل

```
Flutter ── POST /payments/stripe/create-checkout-session ──> Backend
      <── { checkout_url, session_id, payment_id } ──
Flutter ── opens checkout_url (url_launcher, متصفح خارجي)
Stripe  ── Checkout (بطاقة) ──> success/cancel URL
Stripe  ── POST /payments/stripe/webhook (موقّع) ──> Backend
Backend ── يتحقق من التوقيع → يحدّث StripePayment → يفعل الاشتراك
```

> **ملاحظة أمان**: التفعيل يعتمد على الـ **webhook** فقط وليس على إعادة التوجيه
> من المتصفح، فلا يمكن لأي مستخدم تزوير حالة الدفع.

## نقاط API

| المسار | الصلاحية | الوصف |
|---|---|---|
| `GET /payments/stripe/plans` | أي مستخدم مسجّل | كتالوج الباقات مع أسعار Stripe |
| `POST /payments/stripe/create-checkout-session` | مستخدم مسجّل | إنشاء جلسة دفع، يعيد `checkout_url` |
| `POST /payments/stripe/webhook` | موقّع | استقبال أحداث Stripe |
| `GET /payments/stripe/settings` | مسؤول منصة | إعدادات Stripe (ملخّص آمن، بدون أسرار) |
| `POST /payments/stripe/settings` | مسؤول منصة | حفظ الإعدادات (تُشفَّر) |
| `POST /payments/stripe/test-connection` | مسؤول منصة | اختبار الاتصال بالمفتاح السري |
| `PATCH /payments/stripe/plans/{id}` | مسؤول منصة | ربط الباقة بمعرفات Stripe |
| `GET /payments/stripe/payments` | مسؤول منصة | سجل المدفوعات |
| `GET /payments/stripe/subscriptions` | مسؤول منصة | سجل الاشتراكات |

## الانتقال إلى الوضع الفعلي (Live)

1. في Stripe Dashboard ارفع الوضع إلى **Live mode** واحصل على مفاتيح `pk_live_` / `sk_live_`.
2. أنشئ منتجات وأسعار Live جديدة وحدّث معرّفاتها في صفحة الدفع الإلكتروني.
3. عيّن `STRIPE_MODE=live` وقدّم الـ webhook إلى عنوان Live.
4. أعد **اختبار الاتصال** وتأكد من نجاحه قبل التفعيل.
5. أعد **حفظ الإعدادات** — المفاتيح تُتحقق تلقائياً من البادئة حسب الوضع
   (`pk_test_` في الوضع Test، `pk_live_` في الوضع Live).

## ملاحظات أمنية

- مفتاح **Secret** و**Webhook secret** لا يظهران أبداً في أي استجابة للعميل؛
  صفحة الإعدادات تعرض فقط "تم تكوينه".
- القيم تُشفَّر في قاعدة البيانات باستخدام مفتاح Fernet (`encrypt_secret`).
- Webhooks تُتحقق بالكامل (توقيع + نطاق زمني) وتُحذف التكرارات حسب `event.id`.

## التجديد التلقائي — قائمة الجاهزية للنشر

نموذج التجديد: حفظ البطاقة عند زر "ابدأ" ← اشتراك Stripe بتجربة حتى
نهاية الفترة ← أول خصم تلقائي عند الانتهاء ← محاولات مجدولة عند الفشل
← تنبيهات (منتهية/رصيد). قبل النشر العام تحقق من:

1. **Migrations**: قاعدة الإنتاج على `057` على الأقل
   (`alembic upgrade head`). لا متغيرات بيئة جديدة مطلوبة.
2. **Webhook**: عنوان `POST /payments/stripe/webhook` مسجل في Stripe
   Dashboard مع الـ signing secret الصحيح — بدونه لا يتمدد أي تجديد
   في قاعدة البيانات (راقب جدول `stripe_webhook_events`).
3. **Celery Beat + Worker يعملان**: مهمة `retry_renewal_charges`
   مجدولة يوميًا (`beat_schedule`). بدونها لا توجد محاولات مجدولة
   ولا تنبيهات متكررة — تحقق من سجلات Beat.
4. **أسعار التجديد**: تُقفل تلقائيًا من إيصال الدفع لكل مشترك
   (لا حاجة لضبط يدوي). تعديل أسعار الخطط لاحقًا لا يمس المشتركين.
5. **مراقبة مستمرة**: اشتراك `trialing` بتاريخ انتهاء = تاريخ التجديد،
   و`off_session_ready=true` في حالة التجديد يعني الجاهزية الكاملة.
