import 'directory_scope.dart';

/// Only the directory fields. No link, balance, invoices or account data.
final class DirectoryParty {
  const DirectoryParty({
    required this.id,
    required this.kind,
    required this.organizationId,
    required this.branchId,
    required this.name,
    required this.createdAt,
    this.phone,
    this.email,
  });

  factory DirectoryParty.fromFixture(
    DirectoryPartyKind kind,
    Map<String, dynamic> row,
  ) => DirectoryParty(
    id: row['id'] as String,
    kind: kind,
    organizationId: row['organization_id'] as String,
    branchId: row['branch_id'] as String,
    name: row['name'] as String,
    phone: row['phone'] as String?,
    email: row['email'] as String?,
    createdAt: DateTime.parse(row['created_at'] as String),
  );

  final String id;
  final DirectoryPartyKind kind;
  final String organizationId;
  final String branchId;
  final String name;
  final String? phone;
  final String? email;
  final DateTime createdAt;
}

/// A local navigation target. It is passed in memory, never as a server ID
/// in a URL or in a request for the legacy directory.
final class DirectoryPartyReference {
  DirectoryPartyReference({
    required this.scope,
    required this.kind,
    required this.id,
  }) {
    if (!isDirectoryId(id) || !scope.canRead(kind)) {
      throw const DirectoryAccessDenied();
    }
  }

  final DirectoryAccess scope;
  final DirectoryPartyKind kind;
  final String id;

  DirectoryAccess requireScope(
    DirectoryAccess? selected, {
    bool write = false,
  }) {
    if (selected == null ||
        selected.workspace.storageId != scope.workspace.storageId ||
        selected.branchId != scope.branchId ||
        !(write ? selected.canCreate(kind) : selected.canRead(kind))) {
      throw const DirectoryAccessDenied();
    }
    return selected;
  }
}

final class DirectoryPartyNotFound implements Exception {
  const DirectoryPartyNotFound();
}

final class DirectoryDebtGroupReference {
  const DirectoryDebtGroupReference({required this.party, required this.id});

  final DirectoryPartyReference party;
  final String id;
}

final class DirectoryDebtInvoiceReference {
  const DirectoryDebtInvoiceReference({required this.party, required this.id});

  final DirectoryPartyReference party;
  final String id;
}

enum DirectoryValidationProblem {
  nameLength,
  phoneLength,
  duplicateName,
  duplicatePhone,
  groupNameLength,
}

final class DirectoryValidation implements Exception {
  const DirectoryValidation(this.problem);
  final DirectoryValidationProblem problem;
}

/// Divergent fixture IDs or contents must never overwrite an existing party.
final class DirectoryImportConflict implements Exception {
  const DirectoryImportConflict();
}
