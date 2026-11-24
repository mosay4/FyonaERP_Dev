import '../local_ledger/business_money.dart';
import 'directory_database.dart';
import 'directory_pilot.dart';
import 'directory_scope.dart';

/// One branch's answer inside the «جميع الفروع» view.
final class BranchRead<T> {
  const BranchRead(this.branchId, this.branchName, this.value);
  final String branchId;
  final String branchName;
  final T value;
}

/// «جميع الفروع» on a device-ledger organization: every branch of the
/// organization lives in the same encrypted database (rows tagged with
/// branch_id), so the merged view reads each branch with a read-only scope
/// and merges the answers. Nothing here can write: the scopes have no
/// writable kind and the store refuses any non-read ledger action while the
/// view is selected. A new instance is made for every branch selection, so a
/// return to one branch never sees merged rows.
final class BusinessAllBranches {
  BusinessAllBranches({
    required this.workspace,
    required DirectoryPilotStore store,
    required Future<Map<String, String>> Function() branches,
    required bool Function() isCurrent,
  }) : _store = store,
       _branches = branches,
       _isCurrent = isCurrent;

  final DirectoryWorkspace workspace;
  final DirectoryPilotStore _store;
  final Future<Map<String, String>> Function() _branches;
  final bool Function() _isCurrent;
  Future<Map<String, String>>? _known;

  bool get isCurrent => _isCurrent();

  String get scopeKey => 'all:${workspace.storageId}';

  /// Read-only scope of one branch of this organization.
  DirectoryAccess scopeOf(String branchId) => DirectoryAccess(
    workspace: workspace,
    branchId: branchId,
    readable: DirectoryPartyKind.values.toSet(),
    writable: const {},
    financialCutover: true,
  );

  /// The organization's branches on this device: id → name (archived ones
  /// are not part of the merged view).
  Future<Map<String, String>> branches() => _known ??= () async {
    final all = await _branches();
    return {
      for (final entry in all.entries)
        if (isDirectoryId(entry.key)) entry.key: entry.value,
    };
  }();

  Future<String> branchName(String branchId) async =>
      (await branches())[branchId] ?? '';

  /// Runs [read] once per branch, all inside one database session.
  Future<List<BranchRead<T>>> each<T>(
    Set<BusinessLedgerAction> actions,
    Future<T> Function(BusinessLedger ledger, BusinessLedgerAccess access)
    read, {
    Iterable<String>? only,
  }) async {
    if (!isCurrent) throw const DirectoryAccessDenied();
    final names = await branches();
    final ids = [
      for (final id in names.keys)
        if (only == null || only.contains(id)) id,
    ];
    if (ids.isEmpty) return const [];
    final scopes = [for (final id in ids) scopeOf(id)];
    return _store.withBranchesLedger(scopes, () => isCurrent, (ledger) async {
      final out = <BranchRead<T>>[];
      for (final scope in scopes) {
        if (!isCurrent) throw const DirectoryAccessDenied();
        final access = BusinessLedgerAccess(scope, actions);
        out.add(
          BranchRead(
            scope.branchId,
            names[scope.branchId] ?? '',
            await read(ledger, access),
          ),
        );
      }
      return out;
    });
  }

  /// A per-branch source (bank, commerce, report…) stays usable only while
  /// this very view is selected.
  DirectoryAccess? Function() currentScope(DirectoryAccess scope) =>
      () => isCurrent ? scope : null;
}

/// Bank name identity across branches: case, spacing and the three cash
/// spellings never split one bank into two.
String allBranchesBankKey(String bankName) {
  final name = bankName.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
  return const {'كاش', 'cash', 'الكاش'}.contains(name) ? 'كاش' : name;
}

/// Merges every branch's bank accounts into the merchant's whole wealth:
/// one bank per name; inside it one row per currency (and account type)
/// whose balance is the exact sum of the branches' balances. A currency only
/// one branch holds is simply one more currency of that bank. Each merged row
/// remembers its original accounts (`merged_accounts`) for the statement.
List<Map<String, dynamic>> mergeAllBranchesBanks(
  List<BranchRead<List<Map<String, Object?>>>> reads, {
  required bool includeBalances,
}) {
  final rows = <String, Map<String, dynamic>>{};
  final sums = <String, int>{};
  for (final read in reads) {
    for (final raw in read.value) {
      final bankName = '${raw['bank_name'] ?? ''}';
      final bank = allBranchesBankKey(bankName);
      final currency = '${raw['currency'] ?? ''}'.trim().toUpperCase();
      final type = '${raw['account_type'] ?? 'checking'}';
      final key = '$bank|$currency|${bank == 'كاش' ? '' : type}';
      final member = {
        'branch_id': read.branchId,
        'branch_name': read.branchName,
        'id': '${raw['id']}',
      };
      final minor = raw['balance_minor'] is int ? raw['balance_minor'] as int : 0;
      final row = rows[key];
      if (row == null) {
        rows[key] = {
          'id': '${raw['id']}',
          'bank_name': bankName,
          'account_name': raw['account_name'],
          'account_number': raw['account_number'],
          'iban': raw['iban'],
          'account_type': type,
          'currency': currency,
          'is_active': raw['is_active'] == 1 || raw['is_active'] == true,
          'group_key': 'all:name:$bank',
          'branch_ids': [read.branchId],
          'branch_names': [read.branchName],
          'merged_accounts': [member],
        };
        sums[key] = minor;
        continue;
      }
      sums[key] = sums[key]! + minor;
      (row['merged_accounts'] as List).add(member);
      if (!(row['branch_ids'] as List).contains(read.branchId)) {
        (row['branch_ids'] as List).add(read.branchId);
        (row['branch_names'] as List).add(read.branchName);
      }
      if (raw['is_active'] == 1 || raw['is_active'] == true) {
        row['is_active'] = true;
      }
      if ('${row['account_number'] ?? ''}' != '${raw['account_number'] ?? ''}') {
        row['account_number'] = '';
        row['iban'] = null;
      }
    }
  }
  return [
    for (final entry in rows.entries)
      {
        ...entry.value,
        'balance': includeBalances
            ? BusinessMoney.display(sums[entry.key]!)
            : 0,
      },
  ];
}

final _decimal = RegExp(r'^-?\d+\.\d{2}$');

BigInt _minor(String value) {
  final negative = value.startsWith('-');
  final digits = value.replaceFirst('-', '').replaceFirst('.', '');
  final minor = BigInt.parse(digits);
  return negative ? -minor : minor;
}

String _decimalOf(BigInt minor) => BusinessMoney.displayTotal(minor);

/// Keys that describe the report rather than measure it.
const _firstWins = {
  'report',
  'currency',
  'local_valuation',
  'fx_basis',
  'stock_value_basis',
  'basis',
  'warn_days',
  'status',
  'name',
  'unit',
  'image',
  'date',
  'kind',
  'number',
  'party',
  'category',
  'product_id',
  'id',
};

/// Lists whose rows are keyed by a field and summed (charts, breakdowns).
const _keyedBy = ['date', 'month', 'day', 'category', 'label', 'currency'];

/// Merges the same report computed by several branches in ONE report
/// currency (each branch already valued its own figures with the shared
/// rates), so the totals are the merchant's whole business:
/// money values add up exactly (an incomplete total stays incomplete),
/// counts add up, breakdowns by currency/date/category are summed per key,
/// record lists are joined and every row names its branch, and
/// `by_branch` keeps each branch's own headline figures for advice.
Map<String, dynamic> mergeBranchReports(
  List<BranchRead<Map<String, dynamic>>> reads,
) {
  if (reads.isEmpty) return {};
  if (reads.length == 1) {
    return {
      ...reads.single.value,
      'by_branch': [_headline(reads.single)],
    };
  }
  final merged = _mergeMaps([
    for (final read in reads) (read, read.value),
  ], const []);
  merged['branch_ids'] = [for (final read in reads) read.branchId];
  merged['by_branch'] = [for (final read in reads) _headline(read)];
  return merged;
}

Map<String, dynamic> _headline(BranchRead<Map<String, dynamic>> read) {
  final out = <String, dynamic>{
    'branch_id': read.branchId,
    'branch_name': read.branchName,
  };
  void take(String prefix, Map source, int depth) {
    for (final entry in source.entries) {
      final key = prefix.isEmpty ? '${entry.key}' : '$prefix.${entry.key}';
      final value = entry.value;
      if (value is Map && depth < 2) {
        if (value.containsKey('total')) {
          out[key] = value['total'];
          if (value['count'] is int) out['$key.count'] = value['count'];
        } else {
          take(key, value, depth + 1);
        }
      } else if (value is String && _decimal.hasMatch(value)) {
        out[key] = value;
      } else if (value is int && !_firstWins.contains('${entry.key}')) {
        out[key] = value;
      }
    }
  }

  take('', read.value, 0);
  return out;
}

typedef _Part = (BranchRead<Map<String, dynamic>>, Object?);

Map<String, dynamic> _mergeMaps(List<_Part> parts, List<String> path) {
  final keys = <String>[];
  for (final (_, value) in parts) {
    if (value is! Map) continue;
    for (final key in value.keys) {
      if (!keys.contains('$key')) keys.add('$key');
    }
  }
  return {
    for (final key in keys)
      key: _mergeValue(
        key,
        [
          for (final (read, value) in parts)
            if (value is Map && value.containsKey(key)) (read, value[key]),
        ],
        [...path, key],
      ),
  };
}

Object? _mergeValue(String key, List<_Part> parts, List<String> path) {
  if (parts.isEmpty) return null;
  final values = [for (final (_, value) in parts) value];
  if (key == 'branch_ids') {
    return {
      for (final value in values)
        if (value is List) ...value.map((e) => '$e'),
    }.toList();
  }
  if (_firstWins.contains(key)) {
    return values.firstWhere((v) => v != null, orElse: () => null);
  }
  final present = values.where((v) => v != null).toList();
  if (present.isEmpty) return null;
  if (present.every((v) => v is bool)) {
    final flags = present.cast<bool>();
    return key.contains('complete')
        ? flags.every((v) => v)
        : flags.any((v) => v);
  }
  if (present.every((v) => v is String && _decimal.hasMatch(v))) {
    // A branch without a valid valuation makes the merged total incomplete.
    if (present.length != values.length) return null;
    return _decimalOf(
      present.fold<BigInt>(BigInt.zero, (sum, v) => sum + _minor(v as String)),
    );
  }
  if (present.every((v) => v is int)) {
    return present.fold<int>(0, (sum, v) => sum + (v as int));
  }
  if (present.every((v) => v is num)) {
    return present.fold<double>(0, (sum, v) => sum + (v as num).toDouble());
  }
  if (present.every((v) => v is Map)) {
    // A missing section in one branch is fine; a null total is not.
    return _mergeMaps([
      for (final part in parts)
        if (part.$2 is Map) part,
    ], path);
  }
  if (present.every((v) => v is List)) {
    return _mergeLists(key, [
      for (final part in parts)
        if (part.$2 is List) part,
    ], path);
  }
  return present.first;
}

List<Object?> _mergeLists(String key, List<_Part> parts, List<String> path) {
  final items = [
    for (final (read, list) in parts)
      for (final item in list as List) (read, item),
  ];
  if (items.isEmpty) return const [];
  if (items.every((item) => item.$2 is Map)) {
    final maps = [for (final item in items) item.$2 as Map];
    final field = _keyedBy.firstWhere(
      (field) => maps.every(
        (m) =>
            m[field] is String &&
            !m.containsKey('id') &&
            !m.containsKey('product_id') &&
            !m.containsKey('number'),
      ),
      orElse: () => '',
    );
    if (field.isNotEmpty) {
      final groups = <String, List<_Part>>{};
      for (final (read, item) in items) {
        groups.putIfAbsent('${(item as Map)[field]}', () => []).add((read, item));
      }
      final keys = groups.keys.toList();
      if (field == 'date' || field == 'month' || field == 'day') keys.sort();
      return [
        for (final group in keys)
          group == 'null' ? groups[group]!.first.$2 : _mergeMaps(groups[group]!, [...path, group]),
      ];
    }
    // Records: every branch's own rows, each naming its branch.
    return [
      for (final (read, item) in items)
        {
          ...Map<String, dynamic>.from(item as Map),
          'branch_id': read.branchId,
          'branch_name': read.branchName,
        },
    ];
  }
  if (items.every((item) => item.$2 is String || item.$2 is num)) {
    return {for (final (_, item) in items) item}.toList();
  }
  return [for (final (_, item) in items) item];
}

/// Customers/suppliers of every branch: one row per person (same name and
/// phone), the branches it deals with, and its open debt per currency summed
/// over those branches.
List<Map<String, dynamic>> mergeAllBranchesParties(
  List<BranchRead<List<Map<String, dynamic>>>> reads,
) {
  final rows = <String, Map<String, dynamic>>{};
  final sums = <String, Map<String, BigInt>>{};
  for (final read in reads) {
    for (final party in read.value) {
      final name = '${party['name'] ?? ''}'.trim();
      final phone = '${party['phone'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
      final key = '${name.toLowerCase().split(RegExp(r'\s+')).join(' ')}|$phone';
      final row = rows.putIfAbsent(
        key,
        () => {
          'id': party['id'],
          'name': name,
          'phone': party['phone'],
          'branch_ids': <String>[],
          'branch_names': <String>[],
          'members': <Map<String, dynamic>>[],
        },
      );
      if (!(row['branch_ids'] as List).contains(read.branchId)) {
        (row['branch_ids'] as List).add(read.branchId);
        (row['branch_names'] as List).add(read.branchName);
      }
      (row['members'] as List).add({
        'branch_id': read.branchId,
        'branch_name': read.branchName,
        'id': party['id'],
        'debts': party['debts'] ?? const [],
      });
      final bucket = sums.putIfAbsent(key, () => {});
      for (final debt in (party['debts'] as List? ?? const []).whereType<Map>()) {
        final total = '${debt['total'] ?? ''}';
        if (!_decimal.hasMatch(total)) continue;
        final code = '${debt['currency']}';
        bucket.update(
          code,
          (v) => v + _minor(total),
          ifAbsent: () => _minor(total),
        );
      }
    }
  }
  return [
    for (final entry in rows.entries)
      {
        ...entry.value,
        'debts': [
          for (final code in sums[entry.key]!.keys.toList()..sort())
            if (sums[entry.key]![code] != BigInt.zero)
              {'currency': code, 'total': _decimalOf(sums[entry.key]![code]!)},
        ],
      },
  ];
}
