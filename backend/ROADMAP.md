# Roadmap — FYONA ERP

> **Current Phase:** Foundation Freeze (Milestones 1-3 Complete)
> **Backend Production Readiness:** ~92%
> **Flutter App Status:** 433+ files, 0 errors, 49/49 tests

---

## Milestone 4: Sales + Purchases + Accounting (Next)

| Module | Components | Status |
|--------|-----------|--------|
| **Sales Orders** | CRUD, status workflow, customer link, inventory deduction | ❌ Pending |
| **Purchase Orders** | CRUD, status workflow, supplier link, inventory addition | ❌ Pending |
| **Accounting** | Chart of Accounts, Journal Entries, Ledger, Trial Balance | ❌ Pending |
| **Cash Management** | Cash Register, Bank Accounts, Transfers | ❌ Pending |
| **Expenses** | Expense Categories, Expense Records, Approvals | ❌ Pending |
| **Revenue** | Revenue Categories, Revenue Records | ❌ Pending |

---

## Milestone 5: HR + Reports + AI

| Module | Components | Status |
|--------|-----------|--------|
| **Employees** | Employee records, contracts, attendance, leaves | ❌ Pending |
| **Payroll** | Salary calculation, deductions, bonuses, payslips | ❌ Pending |
| **Reports** | Sales reports, Purchase reports, Profit & Loss, Balance Sheet, Cash Flow | ❌ Pending |
| **Dashboards** | Real-time KPIs, Charts, Export (PDF/CSV/Excel) | ❌ Pending |
| **AI Assistant** | Smart suggestions, anomaly detection, forecast, NL queries | ❌ Pending |

---

## Milestone 6: Offline Sync Engine (Flutter)

| Component | Description | Status |
|-----------|-------------|--------|
| **Sync Queue** | Pending changes queue with retry logic | ❌ Pending |
| **Conflict Resolution** | Last-Write-Wins strategy | ❌ Pending |
| **Change Tracking** | Track created/updated/deleted records | ❌ Pending |
| **Batch Sync** | Push/pull in batches of 100 | ❌ Pending |
| **Network Detection** | Auto-sync when online | ❌ Pending |
| **Local Cache** | SQLite as read-through cache | ❌ Pending |

---

## Milestone 7: Flutter → Backend Integration

| Component | Description | Status |
|-----------|-------------|--------|
| **Auth Integration** | Login/Register flows | ❌ Pending |
| **Customer Screens** | CRUD screens → API | ❌ Pending |
| **Product Screens** | CRUD screens → API | ❌ Pending |
| **Invoice Screens** | Invoice flow → API | ❌ Pending |
| **Dashboard** | Real-time data from API | ❌ Pending |
| **Offline Mode** | Use SQLite cache when offline | ❌ Pending |

---

## Legend

| Icon | Meaning |
|------|---------|
| ✅ | Completed (tested & verified) |
| ⚠️ | In progress |
| ❌ | Not started |
| 🚫 | Blocked |

---

## Milestone History

| Milestone | Scope | Files | Tests | Completed |
|-----------|-------|-------|-------|-----------|
| **M1** | Foundation (FastAPI, PostgreSQL, Redis, MinIO, Celery, Docker) | 25+ | 24 | ✅ 2026-07-14 |
| **M2** | Identity & Auth (register, login, JWT, RBAC, roles, permissions) | 15+ | 24 | ✅ 2026-07-14 |
| **M3** | Core Business (Customers, Products, Categories, Inventory, Invoices, Payments) | 25+ | 38 | ✅ 2026-07-14 |
| **Audit** | Production Readiness (Decimal, Security Headers, Rate Limiting, Integration Tests) | 10+ | 10 | ✅ 2026-07-14 |
| **Freeze** | API Contract Freeze (docs, architecture, standardized responses) | 3+ | — | ✅ 2026-07-14 |
| **M4** | Sales + Purchases + Accounting | TBD | TBD | ❌ |
