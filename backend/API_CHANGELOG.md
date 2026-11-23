# API Changelog — FYONA ERP v1

> **Last updated:** 2026-07-14
> **API Version:** v1 (Frozen)
> **Base URL:** `/api/v1`
> **OpenAPI:** `/docs` (Swagger), `/redoc` (ReDoc)

---

## Authentication

All endpoints require `Authorization: Bearer <access_token>` (JWT).
Access tokens expire after 15 minutes. Refresh tokens expire after 30 days.

### Register
`POST /api/v1/auth/register`
- **Request:** `RegisterRequest` (full_name, email, password, phone, organization_name)
- **Response:** `AuthResponse` (access_token, refresh_token, user)
- **Status:** 201 Created
- **Permission:** Public

### Login
`POST /api/v1/auth/login`
- **Request:** `LoginRequest` (email, password)
- **Response:** `AuthResponse` (access_token, refresh_token, user)
- **Status:** 200 OK
- **Permission:** Public

### Refresh Token
`POST /api/v1/auth/refresh`
- **Request:** `RefreshTokenRequest` (refresh_token)
- **Response:** `TokenResponse` (access_token, refresh_token)
- **Status:** 200 OK
- **Permission:** Authenticated

### Logout
`POST /api/v1/auth/logout`
- **Request:** `RefreshTokenRequest` (refresh_token)
- **Response:** `{"success": true, "message": "..."}`
- **Status:** 200 OK
- **Permission:** Authenticated

### Get Current User
`GET /api/v1/auth/me`
- **Response:** `UserResponse`
- **Status:** 200 OK
- **Permission:** Authenticated

### Update Profile
`PUT /api/v1/auth/me`
- **Request:** `UserUpdate` (full_name, phone, preferred_language, preferred_currency, preferred_usage_mode, avatar)
- **Response:** `UserResponse`
- **Status:** 200 OK
- **Permission:** Authenticated

### Change Password
`POST /api/v1/auth/change-password`
- **Request:** `ChangePasswordRequest` (current_password, new_password)
- **Response:** `{"success": true, "message": "..."}`
- **Status:** 200 OK
- **Permission:** Authenticated

---

## Customers

| Method | Path | Description | Permission |
|--------|------|-------------|------------|
| POST | `/customers` | Create customer | `customers:create` |
| GET | `/customers` | List customers | `customers:read` |
| GET | `/customers/{id}` | Get customer | `customers:read` |
| PUT | `/customers/{id}` | Update customer | `customers:update` |
| DELETE | `/customers/{id}` | Delete customer | `customers:delete` |

**Query Parameters (list):** `search`, `page` (default 1), `per_page` (default 20)
**Status Codes:** 200, 201, 204, 400, 401, 403, 404

---

## Suppliers

| Method | Path | Description | Permission |
|--------|------|-------------|------------|
| POST | `/suppliers` | Create supplier | `suppliers:create` |
| GET | `/suppliers` | List suppliers | `suppliers:read` |
| GET | `/suppliers/{id}` | Get supplier | `suppliers:read` |
| PUT | `/suppliers/{id}` | Update supplier | `suppliers:update` |
| DELETE | `/suppliers/{id}` | Delete supplier | `suppliers:delete` |

**Query Parameters (list):** `search`, `page`, `per_page`
**Status Codes:** 200, 201, 204, 400, 401, 403, 404

---

## Product Categories

| Method | Path | Description | Permission |
|--------|------|-------------|------------|
| POST | `/categories` | Create category | `categories:create` |
| GET | `/categories` | List categories | `categories:read` |
| GET | `/categories/{id}` | Get category | `categories:read` |
| PUT | `/categories/{id}` | Update category | `categories:update` |

**Query Parameters (list):** `only_active` (bool)

---

## Products

| Method | Path | Description | Permission |
|--------|------|-------------|------------|
| POST | `/products` | Create product | `products:create` |
| GET | `/products` | List products | `products:read` |
| GET | `/products/{id}` | Get product | `products:read` |
| PUT | `/products/{id}` | Update product | `products:update` |
| DELETE | `/products/{id}` | Delete product | `products:delete` |

**Query Parameters (list):** `search`, `category_id`, `page`, `per_page`

---

## Inventory

| Method | Path | Description | Permission |
|--------|------|-------------|------------|
| POST | `/inventory/movements` | Record movement | `inventory:create` |
| GET | `/inventory/movements` | List movements | `inventory:read` |
| GET | `/inventory/movements/product/{id}` | Product movements | `inventory:read` |

**Movement Types:** `opening`, `purchase`, `sale`, `adjustment`, `transfer`
**Query Parameters (list):** `product_id`, `movement_type`, `page`, `per_page`

---

## Invoices

| Method | Path | Description | Permission |
|--------|------|-------------|------------|
| POST | `/invoices` | Create draft invoice | `invoices:create` |
| GET | `/invoices` | List invoices | `invoices:read` |
| GET | `/invoices/{id}` | Get invoice | `invoices:read` |
| PUT | `/invoices/{id}` | Update draft invoice | `invoices:update` |
| DELETE | `/invoices/{id}` | Delete draft invoice | `invoices:delete` |
| POST | `/invoices/{id}/status` | Confirm/cancel invoice | `invoices:update` |
| POST | `/invoices/{id}/payments` | Add payment | `invoices:update` |

**Invoice Statuses:** `draft` → `confirmed` → `paid`/`partially_paid`, also `cancelled`
**Query Parameters (list):** `search`, `status`, `invoice_type`, `page`, `per_page`

---

## Health

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Overall health |
| GET | `/health/ready` | Readiness check |
| GET | `/health/live` | Liveness check |

---

## Standard Response Format

### Success (single item):
```json
{
  "success": true,
  "message": "OK",
  "data": { ... }
}
```

### Success (paginated list):
```json
{
  "success": true,
  "message": "OK",
  "data": {
    "items": [ ... ],
    "total": 50,
    "page": 1,
    "per_page": 20,
    "total_pages": 3
  }
}
```

### Error:
```json
{
  "success": false,
  "message": "العميل غير موجود"
}
```

### 401 Unauthorized:
```json
{
  "success": false,
  "message": "Not authenticated"
}
```

### 403 Forbidden:
```json
{
  "success": false,
  "message": "ليس لديك صلاحية للقيام بهذه العملية"
}
```

### 429 Rate Limited:
```json
{
  "success": false,
  "message": "تجاوزت الحد المسموح من الطلبات، حاول لاحقاً"
}
```

---

## Standard Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `search` | string | — | Full-text search across name/phone/email |
| `page` | integer | 1 | Page number (1-indexed) |
| `per_page` | integer | 20 | Items per page (max 100) |
| `status` | string | — | Filter by status |
| `invoice_type` | string | — | Filter by type |

---

## HTTP Status Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 201 | Created |
| 204 | Deleted (no content) |
| 400 | Bad request / validation error |
| 401 | Not authenticated |
| 403 | Not authorized (missing permission) |
| 404 | Resource not found |
| 422 | Validation error |
| 429 | Rate limit exceeded |
| 500 | Internal server error |

---

## Error Messages

All error messages are in Arabic (Saudi Arabia locale).

---

## API Contract Freeze

This API contract is frozen as of 2026-07-14.
No breaking changes will be introduced without a major version bump.
Future additions (Milestones 4-7) will only add new endpoints, not modify existing ones.
