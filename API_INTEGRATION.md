# API Integration Guide — FYONA ERP

## Base URL
Configure in `lib/core/config/app_config.dart`:
```dart
static const String apiBaseUrl = 'http://localhost:8000/api/v1';
```

## Authentication

### Login
```
POST /auth/login
Body: { "username": "...", "password": "..." }
Response: { "token": "...", "user": { ... } }
```

### Register
```
POST /auth/register
Body: { "username": "...", "email": "...", "password": "...", "full_name": "..." }
```

### Refresh Token
```
POST /auth/refresh
Body: { "refresh_token": "..." }
```

## Customers

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /customers | List (paginated) |
| GET | /customers/:id | Single customer |
| POST | /customers | Create |
| PUT | /customers/:id | Update |
| DELETE | /customers/:id | Delete |

## Products

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /products | List with search |
| POST | /products | Create |
| PUT | /products/:id | Update |
| GET | /products/categories | Categories list |
| GET | /products/low-stock | Low stock alerts |

## Sales

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /sales | List invoices |
| POST | /sales | Create invoice |
| PUT | /sales/:id/status | Update status |

## Accounting

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /accounts | Chart of accounts |
| POST | /accounts | Create account |
| GET | /journal | Journal entries |
| GET | /reports/trial-balance | Trial balance |
| GET | /reports/balance-sheet | Balance sheet |
| GET | /reports/profit-loss | P&L statement |

## Response Format
All APIs return:
```json
{
  "success": true,
  "data": { ... },
  "message": "...",
  "errors": []
}
```
