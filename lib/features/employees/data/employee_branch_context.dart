import '../../branches/data/branch_scope.dart';

/// The branch travels with the finance route, independently of the workspace.
class EmployeeBranchContext {
  const EmployeeBranchContext(this.id, this.name);

  final String? id;
  final String? name;

  static String? _text(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  factory EmployeeBranchContext.payment({
    String? branchId,
    String? branchName,
  }) {
    final explicit = _text(branchId);
    final scope = BranchScope.allMode ? null : _text(BranchScope.branchId);
    return EmployeeBranchContext(
      explicit ?? scope,
      explicit != null
          ? (_text(branchName) ??
                (explicit == scope ? _text(BranchScope.branchName) : null))
          : (scope == null ? null : _text(BranchScope.branchName)),
    );
  }

  factory EmployeeBranchContext.resolve(
    Map employee,
    List<Map<String, dynamic>> companies,
  ) {
    final managed = (employee['managed_branches'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final organization =
        _text(employee['organization_id']) ?? _text(BranchScope.organizationId);
    // Never borrow a branch from a different company.
    final matching = organization == null
        ? (companies.length == 1 ? companies : <Map<String, dynamic>>[])
        : companies.where((c) => _text(c['organization_id']) == organization);
    final branches = [
      for (final company in matching)
        ...(company['branches'] as List? ?? const []).whereType<Map>(),
    ];
    final ids = employee['branch_ids'] as List? ?? const [];
    final scopeId = BranchScope.allMode ? null : _text(BranchScope.branchId);
    final id =
        scopeId ??
        (ids.isEmpty ? null : _text(ids.first)) ??
        (managed.isEmpty ? null : _text(managed.first['id'])) ??
        (branches.length == 1 ? _text(branches.single['id']) : null);
    String? name;
    if (id != null) {
      if (id == scopeId) name = _text(BranchScope.branchName);
      for (final branch in [...managed, ...branches]) {
        if (_text(branch['id']) == id) {
          name ??= _text(branch['name']);
        }
      }
    }
    return EmployeeBranchContext(id, name);
  }
}
