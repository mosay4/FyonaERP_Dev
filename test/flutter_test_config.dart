import 'dart:async';

import 'support/personal_ledger_test_support.dart';

/// Every test file: the encrypted Personal ledger uses a temp folder and
/// in-memory keys (no platform vault / path_provider under `flutter test`).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installPersonalLedgerForTests();
  await testMain();
}
