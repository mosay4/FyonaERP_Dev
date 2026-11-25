import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'personal_ledger_database.dart';

Future<Directory> personalLedgerRoot() async => Directory(
  p.join((await getApplicationSupportDirectory()).path, 'personal_ledger_v1'),
);

/// Platform vault for Personal ledger keys. Separate from the session vault
/// and from the Business directory vault, and must never reset on error
/// (a reset would make the ledger unreadable — fail closed instead).
final class SecurePersonalLedgerKeys implements PersonalLedgerKeyStore {
  const SecurePersonalLedgerKeys();

  static const vault = FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'fyona_personal_ledger_v1',
      resetOnError: false,
    ),
  );

  @override
  Future<String?> read(String storageId) =>
      vault.read(key: 'personal-ledger-key-$storageId');

  @override
  Future<void> write(String storageId, String key) =>
      vault.write(key: 'personal-ledger-key-$storageId', value: key);
}
