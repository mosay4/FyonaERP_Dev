# FYONA ERP Documentation

## Overview
An integrated ERP system built with Flutter, covering accounting, sales, purchasing, inventory, HR, CRM, and project management.

## Quick Start
```bash
flutter pub get
flutter run
```

## Build Commands
```bash
# Debug APK
flutter build apk --debug

# Release APK (requires signing key)
flutter build apk --release
```

## Architecture
- **State Management**: Riverpod
- **Navigation**: GoRouter
- **Networking**: Dio
- **Storage**: FlutterSecureStorage
- **Architecture**: Clean Architecture + Feature First

## Project Structure
- `lib/core/` - Shared infrastructure (theme, network, router, security)
- `lib/shared/` - Shared models, providers, widgets
- `lib/features/` - Feature modules (auth, customers, sales, etc.)

## Key Features
- Authentication (JWT, MFA, sessions)
- Dashboard with KPI charts
- Customer/Supplier management
- Product/Inventory management
- Sales/Purchase invoicing
- Accounting (Chart of Accounts, Journal, Trial Balance, BS, P&L)
- Banking, Expenses, Payments, Cheques
- HR (Employees, Attendance, Leaves, Payroll)
- CRM (Leads, Pipeline)
- Projects & Tasks
- Reports center
- Notifications

## Dependencies
- flutter_riverpod
- go_router
- dio
- flutter_secure_storage
- fl_chart
- intl
- equatable
- shimmer
- logger
