import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';

/// Constructs a synthetic authority checkpoint for tests that do not run the
/// PostgreSQL fixture. The wire test checks the independently generated hash.
BusinessCashCheckpoint cashTestCheckpoint(
  DirectoryAccess scope,
  String account, {
  required int balance,
  String currency = 'SAR',
  bool allowNegative = false,
}) => (
  sequence: 0,
  digest: sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'fyona.cash.checkpoint.v2',
            scope.workspace.organizationId,
            scope.branchId,
            0,
            [
              [account, currency, balance, allowNegative],
            ],
          ]),
        ),
      )
      .toString(),
);
