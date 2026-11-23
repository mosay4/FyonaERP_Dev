# 📘 FYONA ERP — Engineering Standards (Official Reference)

---

## 1. Project Rules (قوانين صارمة غير قابلة للتفاوض)

### 1.1 Core Architecture Rules

| # | القاعدة | المخالفة |
|---|---------|----------|
| 1 | **Clean Architecture إلزامي** في Flutter (presentation/domain/data) | ❌ كتابة Business Logic داخل Widget |
| 2 | **State Management عبر Riverpod فقط** | ❌ استخدام setState لحالة API |
| 3 | **Navigation عبر GoRouter فقط** | ❌ استخدام Navigator.push مباشر |
| 4 | **HTTP Client عبر Dio فقط** | ❌ استخدام http package مباشر |
| 5 | **SQLite عبر DatabaseHelper فقط** | ❌ إنشاء اتصال DB داخل Widget |
| 6 | **كل Module له Folder مستقل** تحت `lib/features/` | ❌ وضع كل شيء في ملف واحد |
| 7 | **API Models لها `fromJson`/`toJson`** | ❌ تمرير Map مباشر بين الطبقات |
| 8 | **لا يصل الـ UI إلى قاعدة البيانات مباشرة** | ❌ استدعاء DatabaseHelper من Widget |
| 9 | **لا يصل الـ UI إلى API مباشرة** | ❌ استدعاء Dio من Widget |
| 10 | **كل Business Logic في Service** | ❌ كتابة عمليات حسابية داخل Provider |

### 1.2 Dependency Rules

| # | القاعدة | المخالفة |
|---|---------|----------|
| 11 | **الاتجاه: Screen → Provider → Service → Repository** | ❌ Provider يصل لـ Repository مباشر |
| 12 | **Service لا يستدعي Service آخر مباشراً** | ❌ InvoiceService.new() داخل CustomerService |
| 13 | **كل External Package بعيداً عن الـ UI Layer** | ❌ استيراد sqflite داخل Widget |
| 14 | **لا تكرار كود (DRY)** | ❌ نسخ نفس منطق التصفية في 3 صفحات |

### 1.3 Data Flow Rules

```
UI (Screen) → Provider (Riverpod State) → Service (Business Logic) → Repository (Data Source)
```

| # | القاعدة | المخالفة |
|---|---------|----------|
| 15 | **Offline First: SQLite أولاً ثم API** | ❌ انتظار API بدون Local Cache |
| 16 | **API أولاً إن أمكن، SQLite Fallback** | ❌ تجاهل API والإكتفاء بالمحلي |
| 17 | **كل عملية كتابة تذهب لـ Sync Queue** | ❌ الكتابة للـ API فقط بدون Queue |

### 1.4 Route Guard Rules

| # | القاعدة | المخالفة |
|---|---------|----------|
| 18 | **كل مسار له Role محدد في `allowedRoutes`** | ❌ إضافة مسار جديد بدون إضافته للـ Allowed Routes |
| 19 | **لا يمكن لأي مستخدم الوصول لمسارات لا تخصه** | ❌ مستخدم Personal يفتح `/sales` |
| 20 | **الـ Route Guard يمر على كل Navigation** | ❌ تعطيل الـ redirect |

---

## 2. Folder Structure

### 2.1 Flutter — Final Structure

```
lib/
├── main.dart
├── app.dart
│
├── core/                              # Infrastructure Layer
│   ├── config/
│   │   └── app_config.dart
│   ├── database/
│   │   ├── database_helper.dart       # Singleton SQLite Manager
│   │   ├── tables.dart                # ALL CREATE TABLE statements
│   │   ├── repositories/              # 6 SQLite Repositories
│   │   │   ├── auth_repository.dart
│   │   │   ├── personal_repository.dart
│   │   │   ├── business_repository.dart
│   │   │   ├── invoices_repository.dart
│   │   │   ├── accounting_repository.dart
│   │   │   └── settings_repository.dart
│   │   └── providers/
│   │       └── database_providers.dart
│   ├── demo/
│   │   └── demo_auth.dart
│   ├── network/
│   │   ├── api_client.dart
│   │   ├── api_interceptors.dart
│   │   ├── api_response.dart
│   │   ├── dio_provider.dart
│   │   ├── error_handler.dart
│   │   └── retry_interceptor.dart
│   ├── router/
│   │   ├── app_router.dart            # GoRouter Setup
│   │   ├── route_names.dart           # كل أسماء المسارات
│   │   └── role_config.dart           # Personas + Allowed Routes
│   ├── security/
│   │   ├── jwt_service.dart
│   │   └── rate_limiter.dart
│   ├── storage/
│   │   └── secure_storage.dart
│   ├── sync/                          # Offline Sync Engine
│   │   ├── sync_engine.dart
│   │   ├── sync_queue.dart
│   │   ├── conflict_resolver.dart
│   │   ├── sync_status.dart
│   │   └── connectivity_monitor.dart
│   ├── theme/
│   │   ├── app_colors.dart
│   │   ├── app_radius.dart
│   │   ├── app_spacing.dart
│   │   └── app_theme.dart
│   └── responsive/
│       └── r_api.dart
│
├── features/                          # Business Modules
│   ├── <module_name>/                  # e.g., accounting, sales, hr
│   │   ├── data/
│   │   │   ├── models/               # DTO + fromJson/toJson
│   │   │   ├── datasources/          # Remote API calls
│   │   │   └── repositories/         # Repository implementations
│   │   ├── domain/
│   │   │   ├── services/             # Business Logic
│   │   │   └── repositories/         # Abstract interfaces
│   │   ├── presentation/
│   │   │   ├── pages/                # Screens
│   │   │   ├── providers/            # Riverpod StateNotifier
│   │   │   └── widgets/              # Module-specific widgets
│   │   └── di/
│   │       └── <module>_providers.dart
│   └── ...                            # 49 Modules
│
├── shared/                            # مشترك بين كل الـ Features
│   ├── models/
│   │   └── user_model.dart
│   ├── providers/
│   │   ├── auth_provider.dart
│   │   ├── theme_provider.dart
│   │   └── locale_provider.dart
│   └── widgets/
│       ├── app_drawer.dart
│       ├── stat_card.dart
│       ├── empty_states.dart
│       ├── skeleton.dart
│       ├── trial_banner.dart
│       ├── expiring_banner.dart
│       ├── subscription_gate.dart
│       ├── subscription_badge.dart
│       ├── confirm_dialog.dart
│       ├── search_field.dart
│       ├── currency_selector.dart
│       ├── pdf_actions.dart
│       └── receipt_overlay.dart
│
├── test/                              # Tests
│   ├── unit/
│   ├── widget/
│   └── integration/
│
└── assets/
    ├── fonts/
    │   └── Cairo-Variable.ttf
    ├── images/
    │   └── logo.png
    └── videos/
        └── splash.mp4
```

### 2.2 FastAPI — Final Structure

```
backend/
├── app/
│   ├── __init__.py
│   ├── main.py                    # FastAPI app entry
│   ├── core/
│   │   ├── config.py              # Settings (pydantic)
│   │   ├── security.py            # JWT + Password Hashing
│   │   ├── database.py            # SQLAlchemy engine
│   │   ├── redis.py               # Redis client
│   │   ├── storage.py             # MinIO/S3 abstraction
│   │   ├── event_bus.py           # Redis Pub/Sub
│   │   └── logging.py             # Structured logging
│   │
│   ├── domain/                    # Entities + Business Logic
│   │   ├── entities/              # SQLAlchemy Models
│   │   ├── models/                # Pydantic Models
│   │   ├── services/              # Business Logic
│   │   ├── repositories/          # Database access
│   │   └── events/                # Event handlers
│   │
│   ├── api/                       # REST API Layer
│   │   ├── v1/
│   │   │   ├── auth.py
│   │   │   ├── users.py
│   │   │   ├── organizations.py
│   │   │   ├── accounting.py
│   │   │   ├── sales.py
│   │   │   ├── purchases.py
│   │   │   ├── inventory.py
│   │   │   ├── hr.py
│   │   │   ├── reports.py
│   │   │   ├── ai.py
│   │   │   ├── subscriptions.py
│   │   │   ├── files.py
│   │   │   └── sync.py
│   │   └── deps.py                # Dependency Injection
│   │
│   ├── workers/                   # Celery Tasks
│   │   ├── email_tasks.py
│   │   ├── report_tasks.py
│   │   ├── sync_tasks.py
│   │   ├── recurring_tasks.py
│   │   └── ai_tasks.py
│   │
│   └── schemas/                   # Response/Request Schemas
│       └── ...
│
├── migrations/                    # Alembic
│   ├── versions/
│   └── alembic.ini
│
├── tests/
│   ├── unit/
│   ├── integration/
│   └── api/
│
├── scripts/
│   ├── seed_data.py
│   └── migrate.sh
│
├── Dockerfile
├── docker-compose.yml
└── requirements.txt
```

### 2.3 Database — Final Structure

```
database/
├── schema/
│   ├── 001_core.sql               # organizations, users, sessions
│   ├── 002_accounting.sql         # accounts, journal, fiscal
│   ├── 003_crm.sql                # customers, suppliers
│   ├── 004_inventory.sql          # products, categories, stock
│   ├── 005_invoices.sql           # sales, purchases, payments
│   ├── 006_hr.sql                 # employees, payroll, contracts
│   ├── 007_personal.sql           # personal finance tables
│   ├── 008_subscriptions.sql      # plans, billing
│   ├── 009_sync.sql               # sync_queue, sync_status
│   └── 010_security.sql           # permissions, audit_logs
```

### 2.4 Infrastructure — Docker Structure

```
infra/
├── docker-compose.yml              # All services
├── docker-compose.dev.yml          # Dev overrides
├── nginx/
│   └── default.conf                # Reverse Proxy + SSL
├── prometheus/
│   └── prometheus.yml
├── grafana/
│   └── dashboards/
├── minio/
│   └── data/
└── scripts/
    ├── deploy.sh
    └── backup.sh
```

---

## 3. Naming Convention

### 3.1 Flutter

| العنصر | القاعدة | مثال |
|--------|---------|------|
| **Folders** | snake_case | `personal_finance/` |
| **Files** | snake_case | `personal_dashboard_page.dart` |
| **Classes** | PascalCase | `PersonalDashboardPage` |
| **Widgets** | PascalCase | `StatCard`, `EmptyStateWidget` |
| **Services** | PascalCase + Service | `PersonalFinanceService` |
| **Repositories** | PascalCase + Repository | `PersonalRepository` |
| **Providers** | camelCase + Provider | `personalFinanceProvider` |
| **StateNotifier** | PascalCase + Notifier | `PersonalFinanceNotifier` |
| **State** | PascalCase + State | `PersonalFinanceState` |
| **DTO/Models** | PascalCase | `PersonalTransaction` |
| **Enums** | PascalCase | `AuthStatus`, `DocumentType` |
| **Constants** | camelCase | `kDefaultPageSize`, `_defaultCurrency` |
| **Private fields** | \_camelCase | `\_userId`, `\_mockGoals` |
| **Public fields** | camelCase | `totalBalance`, `isLoading` |
| **Functions** | camelCase | `load()`, `getTransactions()` |
| **Routes** | snake_case | `/personal/wallet` |
| **Route names** | camelCase + Route | `personalDashboard` |

### 3.2 FastAPI

| العنصر | القاعدة | مثال |
|--------|---------|------|
| **Files** | snake_case | `accounting_service.py` |
| **Classes** | PascalCase | `AccountingService` |
| **Functions** | snake_case | `get_chart_of_accounts()` |
| **API Endpoints** | kebab-case + plural | `/api/v1/accounts/` |
| **Models (Pydantic)** | PascalCase | `AccountCreate`, `AccountResponse` |
| **Entities (SQLAlchemy)** | PascalCase | `AccountModel` |
| **Database Tables** | snake_case + plural | `chart_of_accounts` |
| **Database Columns** | snake_case | `parent_account_id` |
| **Enums** | PascalCase | `AccountType` |
| **Config Vars** | UPPER_SNAKE | `DATABASE_URL` |
| **Environment** | UPPER_SNAKE | `JWT_SECRET_KEY` |

### 3.3 Git

| العنصر | القاعدة | مثال |
|--------|---------|------|
| **Main Branch** | `main` | — |
| **Develop Branch** | `develop` | — |
| **Feature Branches** | `feature/<module>-<description>` | `feature/auth-jwt` |
| **Fix Branches** | `fix/<short-description>` | `fix/sync-conflict` |
| **Release Branches** | `release/v<major>.<minor>.<patch>` | `release/v2.1.0` |
| **Commit Messages** | Conventional Commits | `feat(auth): add JWT support` |

### 3.4 Docker

| العنصر | القاعدة | مثال |
|--------|---------|------|
| **Images** | `fyona/<service>:<tag>` | `fyona/api:latest` |
| **Container** | `fyona-<service>` | `fyona-api` |
| **Networks** | `fyona-network` | — |
| **Volumes** | `fyona-<data>` | `fyona-postgres` |

---

## 4. Coding Standards

### 4.1 Size Limits

| المقياس | الحد الأقصى | استثناء |
|---------|:----------:|---------|
| **ملف واحد** | 500 سطر | نادراً (بحد أقصى 800 مع موافقة) |
| **كلاس واحد** | 300 سطر | StateNotifier مع دوال كثيرة |
| **دالة واحدة** | 40 سطر | — |
| **Widget build()** | 100 سطر | شاشة معقدة |
| **Parameter count** | 5 parameters | استخدم Data Class |

### 4.2 متى يتم تقسيم الملفات

| الحالة | الإجراء |
|--------|---------|
| 1 ملف > 500 سطر | قسمه إلى ملفات أصغر |
| Widget > 100 سطر في build() | استخرج دوال `_buildSection()` |
| Service > 300 سطر | قسمه إلى Services أصغر |
| نفس الدالة تظهر مرتين في Module | استخرجها لـ Helper |

### 4.3 متى يتم إنشاء Service جديد

| إنشئ Service جديد إذا | مثال |
|-----------------------|------|
| Domain مختلف | `InvoiceService` و `CustomerService` |
| Business Logic مستقل | `SyncEngine` ليس جزءاً من `AuthService` |
| مصدر بيانات مختلف | API Service vs Local Service |

### 4.4 متى يتم إنشاء Module جديد

| إنشئ Module جديد إذا | مثال |
|----------------------|------|
| Concept Domain مختلف | `accounting/` ليس جزءاً من `sales/` |
| له شاشته الخاصة | صفحة جديدة كاملة |
| له Service خاص | Service جديد بمسؤوليات مختلفة |

---

## 5. API Standards

### 5.1 Unified JSON Format

```json
// Success Response
{
  "success": true,
  "data": { ... },
  "message": "تمت العملية بنجاح",
  "meta": {
    "page": 1,
    "per_page": 20,
    "total": 156,
    "total_pages": 8
  }
}

// Error Response
{
  "success": false,
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "بيانات غير صحيحة",
    "details": {
      "email": "البريد الإلكتروني مطلوب",
      "amount": "المبلغ يجب أن يكون رقماً"
    }
  },
  "correlation_id": "uuid-123"
}

// Validation Error
{
  "success": false,
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "يرجى مراجعة الحقول التالية",
    "fields": {
      "name": ["هذا الحقل مطلوب"],
      "email": ["صيغة البريد غير صحيحة"]
    }
  }
}
```

### 5.2 Pagination

```
GET /api/v1/customers?page=1&per_page=20&search=أحمد&sort=name&order=asc

Parameters:
  - page: int (default: 1)
  - per_page: int (default: 20, max: 100)
  - search: string (optional)
  - sort: string (field name)
  - order: asc | desc

Response meta:
{
  "page": 1,
  "per_page": 20,
  "total": 156,
  "total_pages": 8,
  "has_next": true,
  "has_previous": false
}
```

### 5.3 API Versioning

```
URL Prefix: /api/v1/
Headers: Accept: application/json, Accept-Language: ar
Breaking Changes: v2 (لا تعديل على v1)
```

### 5.4 HTTP Status Codes

| الكود | الاستخدام |
|:-----:|-----------|
| 200 | Success |
| 201 | Created |
| 204 | No Content (تعديل/حذف ناجح) |
| 400 | Bad Request |
| 401 | Unauthorized |
| 403 | Forbidden |
| 404 | Not Found |
| 409 | Conflict |
| 422 | Validation Error |
| 429 | Rate Limited |
| 500 | Internal Server Error |

---

## 6. Database Standards

### 6.1 Naming

| العنصر | القاعدة | مثال |
|--------|---------|------|
| **Table Names** | snake_case + plural | `sales_invoices`, `chart_of_accounts` |
| **Column Names** | snake_case | `parent_account_id`, `invoice_no` |
| **Primary Keys** | `id` | كل جدول له `id INTEGER PRIMARY KEY` |
| **Foreign Keys** | `<referenced_table>_id` | `customer_id`, `organization_id` |
| **Indexes** | `idx_<table>_<column>` | `idx_sales_invoices_org_status` |
| **Unique** | `uq_<table>_<columns>` | `uq_org_sku` |

### 6.2 Mandatory Columns

كل جدول في PostgreSQL يجب أن يحتوي على:

| العمود | النوع | الوصف |
|--------|:-----:|-------|
| `id` | `UUID` | Primary Key (UUID v4) |
| `organization_id` | `UUID` | Multi-Tenant Isolation |
| `created_at` | `TIMESTAMPTZ` | وقت الإنشاء |
| `updated_at` | `TIMESTAMPTZ` | وقت آخر تعديل |
| `is_deleted` | `BOOLEAN` | Soft Delete |
| `version` | `INTEGER` | Optimistic Locking |

**SQLite (Cache) تستخدم `INTEGER PRIMARY KEY`** لأن UUID مكلف في SQLite.

### 6.3 Indexes

| النوع | متى تستخدم |
|-------|-----------|
| **Index** | على كل `foreign_key` و `status` و `date` |
| **Unique Index** | على `organization_id + code/sku/invoice_no` |
| **Composite Index** | على `organization_id + status + created_at` |
| **Full Text Index** | على `name`, `description` (PostgreSQL) |

### 6.4 Soft Delete

```
لا يتم حذف أي سطر فعلياً من قاعدة البيانات.
is_deleted = TRUE + deleted_at TIMESTAMP.

الـ Queries:
  SELECT ... WHERE is_deleted = FALSE
  DELETE ... UPDATE SET is_deleted = TRUE

الاستثناء: Sync Queue (تحذف بعد المزامنة).
```

---

## 7. Security Standards

| # | القاعدة | التفاصيل |
|:-:|---------|----------|
| 1 | **JWT Access Token** | 15 دقيقة، من حقنة في Authorization header |
| 2 | **Refresh Token** | 30 يوم، مع Rotation + Revocation |
| 3 | **Password Hashing** | bcrypt (12 rounds minimum) |
| 4 | **Multi-Tenant Isolation** | EVERY query has `WHERE organization_id = X` |
| 5 | **Role-Based Access** | كل Endpoint له Role محدد |
| 6 | **Rate Limiting** | 100 req/min لكل مستخدم، 1000 req/min للـ API |
| 7 | **Input Validation** | Pydantic لـ FastAPI، Validators لـ Flutter |
| 8 | **SQL Injection** | SQLAlchemy ORM (parameters only) |
| 9 | **HTTPS Only** | HSTS + Redirect HTTP→HTTPS |
| 10 | **Secrets Management** | `.env` → Vault/Secrets Manager |
| 11 | **Audit Log** | كل تعديل يُسجل (user, action, resource, timestamp) |
| 12 | **CORS** | تقييد Origins المسموحة |
| 13 | **File Upload** | Validate MIME type + Size limit (50MB) |
| 14 | **API Keys** | للأتمتة مع Rotate كل 90 يوم |
| 15 | **Session Management** | عرض/إنهاء الجلسات النشطة |

---

## 8. Git Workflow

### 8.1 Branch Strategy

```
main
  └── develop
        ├── feature/auth-jwt
        ├── feature/sync-engine
        ├── fix/sync-conflict
        └── release/v2.1.0
```

### 8.2 Commit Convention (Conventional Commits)

```
type(scope): description

Types: feat, fix, refactor, test, docs, chore, style
Scope: module name (auth, sales, accounting, infra)

Examples:
  feat(auth): add JWT authentication
  fix(inventory): correct stock calculation on return
  refactor(sync): extract conflict resolver
  test(accounting): add journal entry tests
  docs(api): add customer endpoints
```

### 8.3 Pull Request Rules

| الشرط | إلزامي؟ |
|-------|:-------:|
| `flutter analyze` = 0 errors | ✅ |
| `pytest` = all passed | ✅ |
| Code Review من مطور آخر | ✅ |
| الـ PR يصف التغيير بالعربي | ✅ |
| لا يوجد `// TODO` أو `// FIXME` | ✅ |
| Tests موجودة (Unit/Widget) | ✅ |
| Documentation محدثة | ✅ |

### 8.4 Release Process

```
1. feature branch → develop (PR)
2. develop → staging branch (CI/CD deploy)
3. Staging testing
4. develop → release/vX.X.X (من develop)
5. release → main (PR with merge commit)
6. main tag vX.X.X
7. Deploy to production
```

---

## 9. Documentation Rules

### 9.1 ما يجب توثيقه

| المستوى | المطلوب |
|---------|---------|
| **Module** | README.md: الغرض + المسؤوليات + Team |
| **Service** | Docstring: المدخلات + المخرجات + Business Rules |
| **API** | Auto-generated (FastAPI Swagger) |
| **Database** | ERD + جدول لكل جدول (الحقول + المعنى) |
| **Migration** | اسم + تاريخ + وصف التغيير |
| **Feature** | رابط الـ PR + Tests + Screenshots |

### 9.2 Docstring Format (Python)

```python
def get_customer_invoices(customer_id: UUID, org_id: UUID) -> list[Invoice]:
    """
    يجلب كل فواتير عميل معين خلال فترة.

    Args:
        customer_id: UUID العميل
        org_id: UUID المؤسسة (للعزل)

    Returns:
        list[Invoice]: قائمة الفواتير مرتبة تنازلياً حسب التاريخ

    Raises:
        NotFoundError: إذا العميل غير موجود
        PermissionError: إذا المستخدم ليس له صلاحية

    Business Rules:
        - الفواتير الملغاة لا تظهر (status != cancelled)
        - أقصى 100 فاتورة في الطلب الواحد
        - الترتيب: الأحدث أولاً
    """
```

### 9.3 Flutter Documentation

```dart
/// شاشة إضافة معاملة مالية جديدة.
///
/// تدعم:
/// - إضافة دخل (income) أو مصروف (expense)
/// - اختيار التصنيف من اقتراحات
/// - طريقة الدفع: كاش أو بنك
/// - تخزين في SQLite أولاً ثم مزامنة مع API
class TransactionFormWidget extends ConsumerStatefulWidget {
  /// نوع المعاملة: income أو expense
  final String transactionType;

  /// [transactionType] مطلوب ويجب أن يكون 'income' أو 'expense'
  const TransactionFormWidget({required this.transactionType, super.key});
  ...
}
```

---

## 10. Definition of Done (DoD)

### ✅ لا يعتبر أي Feature مكتملاً إلا بعد تحقيق ALL

| # | المعيار | المسؤول |
|:-:|---------|---------|
| 1 | **Clean Architecture مطبقة** (presentation/domain/data) | Developer |
| 2 | **Business Logic في Service** وليس في UI | Developer |
| 3 | **Riverpod State Management** وليس setState | Developer |
| 4 | **Routes في GoRouter** مع Route Guard | Developer |
| 5 | **fromJson + toJson** لكل Model | Developer |
| 6 | **Error Handling** (try/catch + Snackbar) | Developer |
| 7 | **Loading State** (Skeleton/CircularProgress) | Developer |
| 8 | **Empty State** (عند عدم وجود بيانات) | Developer |
| 9 | **Validation** (Form + Server-side) | Developer |
| 10 | **Logging** (أخطاء + عمليات مهمة) | Developer |
| 11 | **Unit Tests موجودة** (minimum happy + sad path) | Developer |
| 12 | **`flutter analyze` = 0 errors** | Developer |
| 13 | **Integration مع SQLite** (Offline ready) | Developer |
| 14 | **Documentation** (README أو Docstring) | Developer |
| 15 | **No TODOs / FIXMEs** (ممنوع منعاً باتاً) | Developer |
| 16 | **No Mock/Fake/Hardcoded Data** | Developer |
| 17 | **Code Review من زميل** | Reviewer |
| 18 | **العمل يمر على Dev Environment** | QA |
| 19 | **لا يوجد Regression** في Features قديمة | QA |
| 20 | **Screenshots أو Video مرفق** | Developer |

### 🚫 ممنوعات DoD

| ممنوع | السبب |
|-------|-------|
| ⛔ `// TODO: complete later` | سينتهي في الـ Production |
| ⛔ `catch (_) {}` | سيخفي الأخطاء |
| ⛔ `return []` | سيبدو كبيانات صحيحة |
| ⛔ `onPressed: () {}` | زر ميت لا يعمل |
| ⛔ `await Future.delayed` | تأخير وهمي غير ضروري |
| ⛔ بيانات Hardcoded | ستفشل مع بيانات حقيقية |
| ⛔ ألوان Hardcoded | ستكسر الثيم |

---

## ✅ الخلاصة — FYONA Engineering Standards

| القسم | الحالة |
|-------|:------:|
| **Project Rules** | 20 قاعدة إلزامية ✅ |
| **Folder Structure** | Flutter + FastAPI + Database + Infra ✅ |
| **Naming Convention** | Flutter + FastAPI + Git + Docker ✅ |
| **Coding Standards** | Size limits + تقسيم الملفات ✅ |
| **API Standards** | JSON + Pagination + Errors + Versioning ✅ |
| **Database Standards** | Naming + Columns + Indexes + Soft Delete ✅ |
| **Security Standards** | 15 قاعدة أمنية ✅ |
| **Git Workflow** | Branch + Commit + PR + Release ✅ |
| **Documentation** | Docstrings + README ✅ |
| **Definition of Done** | 20 معيار ✅ |

**هذه الوثيقة هي المرجع الرسمي والوحيد لتطوير FYONA ERP. أي كود يخالفها يُعاد.** 🎯
