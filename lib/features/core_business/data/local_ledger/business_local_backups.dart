import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../local_directory/directory_database.dart';
import '../local_directory/directory_pilot.dart';
import '../local_directory/directory_scope.dart';

const businessBackupExtension = 'fyonabiz';

final class LocalBusinessBackupFile {
  const LocalBusinessBackupFile(this.id, this.file, this.createdAt, this.bytes);

  final String id;
  final File file;
  final DateTime createdAt;
  final int bytes;
  String get name => 'fyona-business-$id.$businessBackupExtension';
}

/// Only Business files, in an account/branch namespace. The catalogue stores
/// no keys or plaintext metadata, and an imported file is never opened in place.
final class LocalBusinessBackups {
  LocalBusinessBackups(this.scope, this._store, this._root, this._selected);

  final DirectoryAccess scope;
  final DirectoryPilotStore _store;
  final Future<Directory> Function() _root;
  final DirectoryAccess? Function() _selected;
  final _io = Lock();
  late final _grant = BusinessLedgerAccess(scope, {
    BusinessLedgerAction.manageBackup,
  });

  bool get isCurrent {
    final actual = _selected();
    return scope.financialCutover &&
        actual?.financialCutover == true &&
        sameDirectoryScope(scope, actual);
  }

  Future<Directory> _folder() async => Directory(
    p.join((await _root()).path, scope.workspace.storageId, scope.branchId),
  );

  Future<void> _allowed() async {
    if (!isCurrent || await _store.entry(scope) == null || !isCurrent) {
      throw const DirectoryAccessDenied();
    }
  }

  File _file(Directory root, String id) {
    if (id != id.toLowerCase() || !isDirectoryId(id)) {
      throw const BusinessBackupRejected(BusinessBackupProblem.invalidArchive);
    }
    return File(p.join(root.path, '$id.$businessBackupExtension'));
  }

  Future<LocalBusinessBackupFile> _describe(File file, String id) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const BusinessBackupRejected(BusinessBackupProblem.invalidArchive);
    }
    final stat = await file.stat();
    if (stat.size < 1 || stat.size > businessBackupMaxBytes) {
      throw const BusinessBackupRejected(BusinessBackupProblem.invalidArchive);
    }
    return LocalBusinessBackupFile(id, file, stat.modified, stat.size);
  }

  Future<List<LocalBusinessBackupFile>> list() => _io.synchronized(() async {
    await _allowed();
    final folder = await _folder();
    final result = <LocalBusinessBackupFile>[];
    if (await folder.exists()) {
      await for (final entity in folder.list(followLinks: false)) {
        if (!isCurrent) throw const DirectoryAccessDenied();
        if (entity is! File ||
            p.extension(entity.path) != '.$businessBackupExtension')
          continue;
        final id = p.basenameWithoutExtension(entity.path);
        if (!isDirectoryId(id) || id.toLowerCase() != id) continue;
        try {
          result.add(await _describe(entity, id));
        } on BusinessBackupRejected {
          // No deletion or overwrite if an existing file is unreadable.
        }
      }
    }
    await _allowed();
    return result..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  });

  Future<LocalBusinessBackupFile> create(BusinessBackupCode code) =>
      _io.synchronized(() async {
        await _allowed();
        final folder = await _folder();
        await folder.create(recursive: true);
        final id = const Uuid().v4();
        final dest = _file(folder, id);
        final scratch = await folder.createTemp('.writing-');
        final staging = File(p.join(scratch.path, 'archive'));
        try {
          await _store.withLedger(
            _grant,
            _selected,
            (ledger) => ledger.captureBackup(
              _grant,
              id: id,
              destination: staging,
              code: code,
              allowed: () => isCurrent,
            ),
          );
          final stat = await _describe(staging, id);
          await _allowed();
          if (await FileSystemEntity.type(dest.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const BusinessBackupRejected(
              BusinessBackupProblem.invalidArchive,
            );
          }
          final file = await staging.rename(dest.path);
          return LocalBusinessBackupFile(id, file, stat.createdAt, stat.bytes);
        } finally {
          await _removeScratch(scratch);
        }
      });

  Future<LocalBusinessBackupFile> file(String id) => _io.synchronized(() async {
    await _allowed();
    final result = await _describe(_file(await _folder(), id), id);
    await _allowed();
    return result;
  });

  Future<void> remove(String id) => _io.synchronized(() async {
    await _allowed();
    final target = _file(await _folder(), id);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const BusinessBackupRejected(BusinessBackupProblem.invalidArchive);
    }
    await _allowed();
    await target.delete();
  });

  Future<BusinessBackupRestore> restoreFile(
    String id,
    BusinessBackupCode code,
  ) => _io.synchronized(() async {
    await _allowed();
    final target = await _describe(_file(await _folder(), id), id);
    return _restore(target.file, code, expectedId: id);
  });

  Future<BusinessBackupRestore> restoreStream(
    Stream<List<int>> input,
    BusinessBackupCode code,
  ) => _io.synchronized(() async {
    await _allowed();
    final folder = await _folder();
    await folder.create(recursive: true);
    final scratch = await folder.createTemp('.incoming-');
    final local = File(p.join(scratch.path, 'archive'));
    try {
      final handle = await local.open(mode: FileMode.writeOnly);
      try {
        var written = 0;
        await for (final bytes in input) {
          if (!isCurrent) throw const DirectoryAccessDenied();
          written += bytes.length;
          if (written > businessBackupMaxBytes) {
            throw const BusinessBackupRejected(BusinessBackupProblem.tooLarge);
          }
          await handle.writeFrom(bytes);
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
      return await _restore(local, code);
    } finally {
      await _removeScratch(scratch);
    }
  });

  Future<BusinessBackupRestore> _restore(
    File source,
    BusinessBackupCode code, {
    String? expectedId,
  }) {
    return _store.withLedger(
      _grant,
      _selected,
      (ledger) => ledger.restoreBackup(
        _grant,
        source: source,
        code: code,
        allowed: () => isCurrent,
        expectedId: expectedId,
      ),
    );
  }

  static Future<void> _removeScratch(Directory scratch) async {
    try {
      await scratch.delete(recursive: true);
    } on FileSystemException {
      // A failed cleanup never turns a committed restore into a false
      // failure. The catalogue ignores these uniquely named scratch folders.
    }
  }
}
