# Contributing to FYONA ERP

## Code Style
- Follow Flutter/Dart conventions
- Use `const` constructors where possible
- Follow Clean Architecture: Data → Domain → Presentation
- Use Riverpod for state management
- Name files in snake_case, classes in PascalCase

## Adding a New Feature
1. Create feature directory under `lib/features/`
2. Create data/domain/presentation layers
3. Add abstract repository in domain
4. Implement repository in data
5. Add Riverpod providers
6. Register routes in `core/router/app_router.dart`
7. Add route constants in `core/router/route_names.dart`
8. Write tests

## Testing
```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/core/security/rate_limiter_test.dart
```

## Commit Messages
- Use Arabic or English
- Format: `[Module] Short description`
- Example: `[Customers] Add form validation`
