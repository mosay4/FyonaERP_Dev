import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/employees/data/employee_permissions.dart';

void main() {
  tearDown(() { BranchScope.allMode = false; BranchScope.token = null; });
  test('legacy all token never grants writes even with explicit branch IDs', () {
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'write_scope': 'branch', 'branch_ids': ['a', 'b'],
    })));
    BranchScope.token = 'x.$payload.x';
    BranchScope.allMode = true;
    expect(BranchScope.readOnly, isTrue);
    BranchScope.allMode = false;
    expect(BranchScope.readOnly, isFalse);
  });
  test('Sara is not configurable or granted to any employee', () {
    expect(employeePermissionGroups.containsKey('ai'), isFalse);
    expect(employeePermissionOrder.contains('ai'), isFalse);
    expect(employeePermissionAllowed({'ai': true}, 'ai'), isFalse);
    expect(employeeHasFullAccess(defaultEmployeePermissions()), isTrue);
  });
}
