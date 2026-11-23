# Architecture — FYONA ERP Backend

> **Version:** 1.0.0
> **Stack:** FastAPI + SQLAlchemy 2.0 (async) + PostgreSQL + Redis + MinIO + Celery

---

## Layer Architecture

```
┌─────────────────────────────────────────────────┐
│                  FastAPI App                     │
│  Middleware (CORS, Security, Rate-Limit, Log)    │
│  Exception Handlers                              │
├─────────────────────────────────────────────────┤
│              API Layer (app/api)                 │
│  v1/auth.py, v1/business.py, v1/invoices.py      │
│  deps.py (dependencies), responses.py (wrapper) │
├─────────────────────────────────────────────────┤
│            Service Layer (app/domain/services)   │
│  AuthService, BusinessService, InvoiceService    │
│  Business logic, validation, orchestration       │
├─────────────────────────────────────────────────┤
│         Repository Interfaces (domain/repos)     │
│  Abstract repositories for DI & testability      │
├─────────────────────────────────────────────────┤
│       Infrastructure (infrastructure/repos)      │
│  SQLAlchemy implementations, Celery tasks        │
├─────────────────────────────────────────────────┤
│            Domain Layer (domain/entities)        │
│  SQLAlchemy models (auth_entities,               │
│  business_entities, invoice_entities)            │
├─────────────────────────────────────────────────┤
│            Schema Layer (domain/models)          │
│  Pydantic v2 schemas (request/response)          │
├─────────────────────────────────────────────────┤
│  PostgreSQL  │  Redis  │  MinIO  │  Celery       │
└─────────────────────────────────────────────────┘
```

### Principles

- **Clean Architecture**: Dependencies point inward (Infrastructure → Domain → Application)
- **Repository Pattern**: Data access abstracted behind interfaces for testability
- **Service Layer**: Business logic isolated from HTTP concerns
- **Dependency Injection**: Services receive repositories via constructor injection
- **Async Everywhere**: All I/O operations are async (SQLAlchemy async, Redis async)

---

## Authentication Flow

```
Client                    API                     Database
  │                       │                         │
  │  POST /auth/register  │                         │
  │──────────────────────►│                         │
  │                       │  Check email unique     │
  │                       │────────────────────────►│
  │                       │  Create Organization    │
  │                       │────────────────────────►│
  │                       │  Create default roles   │
  │                       │────────────────────────►│
  │                       │  Create User (bcrypt)   │
  │                       │────────────────────────►│
  │                       │  Create UserSession     │
  │                       │────────────────────────►│
  │  { access_token,      │                         │
  │    refresh_token }    │                         │
  │◄──────────────────────│                         │
```

### Token Details
- **Access Token**: JWT, 15 min expiry, contains `sub` (user_id), `org` (org_id), `role`
- **Refresh Token**: Rotated on each use, 30 day expiry, stored in `user_sessions`
- **Password**: bcrypt (12 rounds)
- **JWT Algorithm**: HS256

---

## Authorization Flow

```
Request → JWT Middleware → Decode Token → Extract Role
                                                  │
                                                  ▼
                       ┌──────────────────────────┐
                       │  require_permission()     │
                       │  resource: "products"     │
                       │  action: "create"         │
                       └────────────────┬─────────┘
                                        │
                                        ▼
                       ┌──────────────────────────┐
                       │  role_repo                │
                       │  .user_has_permission()   │
                       └────────────────┬─────────┘
                                        │
                      ┌─────────────────┴──────────┐
                      │  YES (200)    NO (403)      │
                      ▼                 ▼           │
                   Execute           Forbidden      │
                   Handler           Response       │
```

### Default Roles & Permissions

| Role | Permissions |
|------|-------------|
| `owner` | Full access to all resources |
| `manager` | CRUD on customers, products, categories, invoices, inventory, reports |
| `employee` | CRUD on customers, invoices (read on products, inventory) |
| `accountant` | CRUD on invoices, reports (read on customers, products) |

---

## Inventory Flow

```
Record Movement → Lock Product Row (FOR UPDATE)
                        │
                        ▼
            Check: product.is_service?
                        │
              No ───────┴─────── Yes
              │                    │
              ▼                    ▼
      Check: new_stock      Reject (ValueError)
      = stock + quantity
              │
      ┌───────┴───────┐
      │ >= 0    < 0    │
      ▼                ▼
  Create Movement  Reject
  Update Stock    (Insufficient)
```

- **Atomic**: Both movement creation and stock update in one transaction
- **Locking**: `SELECT ... FOR UPDATE` prevents concurrent stock corruption
- **Negative stock**: Prevented by check before write

---

## Invoice Flow

```
Create (Draft) → Update (Draft) → Confirm → Payment → Paid
                                      │
                                      ▼
                                  Cancel (rollback)
```

### Status Transitions
- `draft` → `confirmed`: Validates items exist, locks invoice row
- `draft` → `cancelled`: Direct cancel allowed
- `confirmed` → `cancelled`: Balance reset to 0
- `confirmed` → `partially_paid` / `paid`: Via `add_payment`

### Calculation Pipeline
```
Items: subtotal = Σ(qty × unit_price - discount)
       ↓
Discount: after_discount = subtotal - (subtotal × discount_rate% | fixed)
       ↓
Tax: tax_amount = after_discount × tax_rate%
       ↓
Total: total = after_discount + tax_amount
       ↓
Payments: balance = total - paid_amount
       ↓
Status: balance ≈ 0 → "paid", else "partially_paid"
```

---

## Rate Limiting

```
Request → Rate Limit Middleware
              │
       ┌──────┴──────┐
       │ Per-IP      │ Per-User
       │ Redis ZSET  │ Redis ZSET
       └──────┬──────┘
              │
         ┌────┴────┐
         │ Under   │ Over
         │ limit   │ limit
         ▼         ▼
      Proceed   429 Too Many
                 Requests
```

- **Redis**: Sorted sets with timestamps as scores
- **Window**: Sliding window (default 60s)
- **Per-IP**: 200 req/min
- **Per-User**: 100 req/min
- **Graceful degradation**: Silently passes when Redis unavailable

---

## Security

### Headers (applied by `SecurityHeadersMiddleware`)
| Header | Value |
|--------|-------|
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `DENY` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` |
| `Content-Security-Policy` | `default-src 'none'; script-src 'self'; ...` |

### CORS
- Origins: configured via `CORS_ORIGINS` in settings
- Methods: `GET, POST, PUT, DELETE, OPTIONS`
- Headers: `Authorization, Content-Type, X-Correlation-ID`

### Trusted Hosts
- Enforced via `TrustedHostMiddleware`
- Only configured hosts are allowed

---

## Error Handling

```
FastAPI Exception Handler
    │
    ├── HTTPException → { "success": false, "message": detail }
    │
    └── Generic Exception → { "success": false, "message": "Internal..." }
                               + log to structlog
```

- All errors return `{"success": false, ...}` format
- Business logic errors return HTTP 400 with Arabic message
- Auth errors return 401
- Permission errors return 403
- Not found returns 404
- Rate limit returns 429

---

## Pagination Standard

**Request:** `?page=1&per_page=20&search=...&status=...`

**Response data:**
```json
{
  "items": [...],
  "total": 50,
  "page": 1,
  "per_page": 20,
  "total_pages": 3
}
```

- `page` is 1-indexed
- `per_page` max 100
- `total_pages = ceil(total / per_page)`, minimum 1

---

## Database Conventions

- All tables use UUID primary keys
- All tables have `created_at` timestamps
- All tables use `DateTime(timezone=True)` for timezone-aware storage
- Timestamps are stored in UTC
- Financial columns use `Numeric(12, 2)` for precise decimal storage
- Soft delete via `is_deleted` + `deleted_at` columns
- Foreign keys are indexed
- Unique constraints at organizational level (org_id + identifier)
