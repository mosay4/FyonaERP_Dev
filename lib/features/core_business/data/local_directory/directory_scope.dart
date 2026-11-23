import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/validation.dart';

enum DirectoryPartyKind { customer, supplier }

bool isDirectoryId(String value) =>
    UuidValidation.isValidUUID(fromString: value);

/// The account is part of the namespace, even if two accounts work in the
/// same organization on the same handset. The branch is deliberately not
/// part of the filename: it is a required scope on every repository operation.
final class DirectoryWorkspace {
  factory DirectoryWorkspace({
    required String server,
    required String accountId,
    required String organizationId,
  }) {
    final uri = Uri.tryParse(server);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !isDirectoryId(accountId) ||
        !isDirectoryId(organizationId)) {
      throw ArgumentError('Invalid Business directory workspace');
    }
    return DirectoryWorkspace._(
      uri.toString().replaceFirst(RegExp(r'/+$'), ''),
      accountId,
      organizationId,
    );
  }

  DirectoryWorkspace._(this.server, this.accountId, this.organizationId);

  final String server;
  final String accountId;
  final String organizationId;

  late final String storageId = sha256
      .convert(utf8.encode(jsonEncode([server, accountId, organizationId])))
      .toString();
}

/// Issued by Business session wiring, never built from route parameters or
/// imported rows. One concrete branch only; the all-branches view stays legacy.
final class DirectoryAccess {
  DirectoryAccess({
    required this.workspace,
    required this.branchId,
    required Set<DirectoryPartyKind> readable,
    required Set<DirectoryPartyKind> writable,
    this.financialCutover = false,
    this.writerSession,
    this.transferExpiry,
    this.cashLinkId,
    this.member = false,
    Map<String, String>? transferBranches,
  }) : _readable = Set.unmodifiable(readable),
       _writable = Set.unmodifiable(writable),
       transferBranches = Map.unmodifiable(transferBranches ?? {branchId: ''}) {
    if (!isDirectoryId(branchId)) {
      throw ArgumentError('A concrete directory branch is required');
    }
  }

  final DirectoryWorkspace workspace;
  final String branchId;
  final bool financialCutover;
  final String? writerSession;
  final DateTime? transferExpiry;
  final String? cashLinkId;
  /// An employee's device working in its employer's organization.
  final bool member;
  final Map<String, String> transferBranches;
  final Set<DirectoryPartyKind> _readable;
  final Set<DirectoryPartyKind> _writable;

  bool canRead(DirectoryPartyKind kind) => _readable.contains(kind);
  bool canCreate(DirectoryPartyKind kind) =>
      canRead(kind) && _writable.contains(kind);
}

final class DirectoryAccessDenied implements Exception {
  const DirectoryAccessDenied();
}
