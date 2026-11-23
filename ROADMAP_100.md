# 📋 الخطة الشاملة لإكمال FYONA ERP — 100%

## 8 مراحل × ~5 أيام = ~40 يوم عمل

---

## 🏁 المرحلة 1: Settings + Profile + MFA (5 أيام)
**الهدف:** إكمال شاشات النظام الأساسية

| اليوم | المهمة | المخرجات |
|------|--------|---------|
| 1 | **User Profile Page** — عرض/تعديل الاسم، البريد، الجوال، الصورة الشخصية، تغيير كلمة المرور | `profile_page.dart` |
| 2 | **Settings Page** — إعدادات الشركة (الاسم، الشعار، الضريبة، العملة) | `settings_page.dart` |
| 3 | **Settings Customization** — تخصيص الفواتير (الألوان، التذييل، القوالب) | `design_studio_pages.dart` |
| 4 | **Onboarding Screen** — دليل البدء السريع (Swipe pages) | `onboarding_page.dart` |
| 5 | **MFA Setup + Verify** — تمكين/تعطيل MFA، Backup Codes | `mfa_setup_page.dart`, `mfa_verify_page.dart` |

---

## 🏁 المرحلة 2: Accounting Forms + Reports (5 أيام)
**الهدف:** إكمال المحاسبة بالكامل

| اليوم | المهمة | المخرجات |
|------|--------|---------|
| 1 | **Account Form** — إضافة/تعديل حساب في دليل الحسابات (Tree Picker للـ Parent) | `account_form_page.dart` |
| 2 | **Journal Form** — إضافة قيد يومية مع Dynamic Lines (Debit/Credit validation) | `journal_form_page.dart` |
| 3 | **General Ledger** — عرض حركة كل حساب مع Running Balance | `ledger_page.dart` |
| 4 | **Cash Flow Report** — تدفق نقدي (In/Out/Net) مع Charts | `cashflow_report_page.dart` |
| 5 | **Fiscal Years** — إدارة السنوات المالية (فتح/غلق) | `fiscal_year_page.dart` |

---

## 🏁 المرحلة 3: Banking + Expenses + Payments Forms (4 أيام)
**الهدف:** إكمال Forms المصرفية والمالية

| اليوم | المهمة | المخرجات |
|------|--------|---------|
| 1 | **Bank Account Form** — إضافة/تعديل حساب بنكي مع IBAN | `bank_account_form_page.dart` |
| 2 | **Wire Transfer + Bank Statement** — تحويل بنكي + كشف حساب | `wire_transfer_page.dart`, `bank_statement_page.dart` |
| 3 | **Expense Form** — إضافة مصروف مع category + صورة الإيصال | `expense_form_page.dart` |
| 4 | **Payment Form** — إضافة دفعة (وارد/صادر) مع اختيار العميل/المورد | `payment_form_page.dart` |

---

## 🏁 المرحلة 4: HR Full Module (6 أيام)
**الهدف:** نظام الموارد البشرية الكامل

| اليوم | المهمة | المخرجات |
|------|--------|---------|
| 1 | **Employee Form + Detail** — إضافة/تعديل موظف مع كل الحقول | `employee_form_page.dart`, `employee_detail_page.dart` |
| 2 | **Attendance** — تسجيل حضور/انصراف + تقرير شهري | `attendance_page.dart` |
| 3 | **Leaves** — أنواع الإجازات + طلب/موافقة/رصيد | `leave_page.dart` |
| 4 | **Payroll** — هيكل الرواتب + Allowances + Deductions | `payroll_form_page.dart` |
| 5 | **Contracts** — عقود الموظفين + التجديد + التنبيهات | `contracts_page.dart` |
| 6 | **Fixed Assets** — الأصول الثابتة + الإهلاك + الصيانة | `fixed_asset_page.dart` |

---

## 🏁 المرحلة 5: Personal Finance (4 أيام)
**الهدف:** المالية الشخصية

| اليوم | المهمة | المخرجات |
|------|--------|---------|
| 1 | Personal Dashboard + Wallet + Transactions | 3 شاشات |
| 2 | Savings Goals + Spending Analytics | 2 شاشات |
| 3 | Personal Banks + Statement + Debts | 4 شاشات |
| 4 | Finance Overview + AI Chat + Reports | 4 شاشات |

---

## 🏁 المرحلة 6: Admin Panel (5 أيام)
**الهدف:** لوحة المشرف كاملة

| اليوم | المهمة | المخرجات |
|------|--------|---------|
| 1 | Admin Dashboard + Orgs + Plans | 3 شاشات |
| 2 | Subscription Requests + Users + Settings | 3 شاشات |
| 3 | Audit + Permissions + Notifications | 3 شاشات |
| 4 | Backup + Files + Export + Trash | 4 شاشات |
| 5 | API Keys + Analytics + Health | 3 شاشات |

---

## 🏁 المرحلة 7: Business Services Layer (6 أيام)
**الهدف:** إنشاء Abstract Services لجميع Modules

| اليوم | المهمة |
|------|--------|
| 1 | Accounting + Customer + Supplier Services |
| 2 | Product + Inventory + Sales + Purchase Services |
| 3 | Banking + Payment + Expense + Cheque Services |
| 4 | HR + Payroll + Contract + Asset Services |
| 5 | Subscription + Email + Notification Services |
| 6 | AI + Report + Cache + Quota Services |

---

## 🏁 المرحلة 8: Testing + QA + Release (5 أيام)
**الهدف:** الجودة والاختبارات والإطلاق

| اليوم | المهمة |
|------|--------|
| 1 | Widget Tests لجميع الـ Forms الجديدة |
| 2 | Repository Tests (Mock) |
| 3 | Integration Tests للـ Auth Flow |
| 4 | Performance Testing + APK Optimization |
| 5 | Release Build + Final Documentation |

---

## 📊 الجدول الزمني

| المرحلة | المدة | الوحدات |
|---------|-------|---------|
| 1 | 5 أيام | Settings, Profile, MFA, Onboarding |
| 2 | 5 أيام | Accounting Forms, Ledger, Reports |
| 3 | 4 أيام | Banking, Expenses, Payments, Cheques Forms |
| 4 | 6 أيام | HR كامل (Employees, Attendance, Leaves, Payroll, Contracts, Assets) |
| 5 | 4 أيام | Personal Finance |
| 6 | 5 أيام | Admin Panel |
| 7 | 6 أيام | Services Layer |
| 8 | 5 أيام | Testing + QA + Release |
| **الإجمالي** | **~40 يوم** | **كل Modules 100%** |

---

## 🔴 نبدأ الآن — المرحلة 1

### اليوم 1: إعداد Settings Module
```dart
lib/features/settings/presentation/pages/settings_page.dart
lib/features/settings/data/models/settings_model.dart
lib/features/settings/domain/repositories/settings_repository.dart
lib/features/settings/data/repositories/settings_repository_impl.dart
```
