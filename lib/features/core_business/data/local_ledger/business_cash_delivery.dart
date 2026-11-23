import 'package:synchronized/synchronized.dart';

import '../local_directory/directory_database.dart';
import '../local_directory/directory_pilot.dart';
import '../local_directory/directory_scope.dart';
import 'business_money.dart';

enum BusinessCashMessage { withdraw, poll, ack, settle }

/// The adapter must bind a verified account and branch to the session. Wire
/// bodies intentionally contain neither. The directory-only build never starts
/// a relay, and connectivity never gates an ordinary local read or write.
typedef SendBusinessCash =
    Future<Map<String, Object?>> Function(
      BusinessCashMessage message,
      Map<String, Object?> body,
    );

final class BusinessCashDelivery {
  BusinessCashDelivery({
    required this.scope,
    required this.sessionId,
    required DirectoryPilotStore store,
    required DirectoryAccess? Function() current,
    required SendBusinessCash send,
    SendBusinessCash? sendV3,
    void Function()? changed,
  }) : _store = store,
       _current = current,
       _send = send,
       _sendV3 = sendV3,
       _changed = changed;

  final DirectoryAccess scope;
  final String sessionId;
  final DirectoryPilotStore _store;
  final DirectoryAccess? Function() _current;
  final SendBusinessCash _send;
  final SendBusinessCash? _sendV3;
  final void Function()? _changed;
  final _cycle = Lock();
  late final _access = BusinessLedgerAccess(scope, {
    BusinessLedgerAction.syncCash,
  }, cashSessionId: sessionId);

  Future<T> _local<T>(
    Future<T> Function(BusinessCashSync cash, BusinessLedgerAccess access) use,
  ) => _store.withLedger(
    _access,
    _current,
    (ledger) => use(ledger.cashSync, _access),
  );

  void _requireScope() {
    final selected = _current();
    if (!scope.financialCutover ||
        selected?.financialCutover != true ||
        !sameDirectoryScope(scope, selected)) {
      throw const DirectoryAccessDenied();
    }
  }

  Future<Object?> _call(
    BusinessCashCheckpoint checkpoint,
    int version,
    BusinessCashMessage message,
    Map<String, Object?> body,
  ) async {
    _requireScope();
    final transport = version == 2 ? _send : _sendV3;
    if (transport == null) throw const DirectoryAccessDenied();
    final frame = await transport(message, {
      ...body,
      'checkpoint': {
        'sequence': checkpoint.sequence,
        'digest': checkpoint.digest,
      },
    });
    _requireScope();
    final binding = frame['checkpoint'];
    if (frame['version'] != version ||
        frame['organization_id'] != scope.workspace.organizationId ||
        frame['account_id'] != scope.workspace.accountId ||
        frame['branch_id'] != scope.branchId ||
        frame['session_id'] != sessionId ||
        binding is! Map ||
        binding['sequence'] != checkpoint.sequence ||
        binding['digest'] != checkpoint.digest) {
      throw const DirectoryAccessDenied();
    }
    return frame['data'];
  }

  bool _stillAllowed() {
    final selected = _current();
    return selected?.financialCutover == true && sameDirectoryScope(scope, selected);
  }

  /// Push a bounded batch and fetch a page in authority order. A failed
  /// session/connection is retried by the caller, not the UI. No database
  /// lock stays held across a network call. Acknowledgment follows durable
  /// apply, never fetch or enqueue.
  Future<void> runOnce() => _cycle.synchronized(() async {
    final checkpoint = await _local(
      (cash, access) => cash.replicaCheckpoint(access, sessionId),
    );
    if (checkpoint == null) throw const DirectoryAccessDenied();
    final version = await _local((cash, access) => cash.supportsEqualization(access)) ? 3 : 2;
    final queued = await _local((cash, access) => cash.pending(access));
    for (final row in queued) {
      final id = _id(row['command_id']);
      final receipt = _object(
        await _call(checkpoint, version, BusinessCashMessage.withdraw, {
          'command_id': id,
          'account_id': row['account_id'],
          'currency': row['currency'],
          'amount_minor': row['amount_minor'],
          'grant_version': row['grant_version'],
        }),
      );
      if (receipt['command_id'] != id)
        throw const FormatException('Cash receipt mismatch');
      final decision = _cashDecision(receipt['decision']);
      final blocked = receipt['blocked_by'] == null
          ? null
          : _id(receipt['blocked_by']);
      if (blocked != null &&
          (blocked == id ||
              decision != BusinessCashDecision.insufficientBalance)) {
        throw const FormatException('Invalid cash conflict');
      }
      final seq = _positive(receipt['sequence']);
      if (seq <= checkpoint.sequence) {
        throw const FormatException('Cash receipt predates its checkpoint');
      }
      await _local(
        (cash, access) => cash.decide(
          access,
          commandId: id,
          sequence: seq,
          decision: decision,
          blockedBy: blocked,
        ),
      );
      _requireScope();
      _changed?.call();
    }
    String? acceptedId;
    int? acceptedSequence;
    if (version == 3) {
      if (queued.length == 100) return;
      final pending = await _local((cash, access) => cash.pendingEqualization(access));
      if (pending != null) {
        final id = _id(pending['command_id']);
        final receipt = _object(await _call(checkpoint, version, BusinessCashMessage.settle, pending));
        final sequence = _positive(receipt['sequence']);
        if (receipt['command_id'] != id || receipt['blocked_by'] != null ||
            sequence <= checkpoint.sequence) {
          throw const FormatException('Equalization receipt mismatch');
        }
        final decision = _cashDecision(receipt['decision']);
        if (decision == BusinessCashDecision.accepted) {
          // A committed declaration is not a local ledger write. Only the
          // ordered page below can apply the amounts and original check.
          acceptedId = id;
          acceptedSequence = sequence;
        } else {
          await _local((cash, access) => cash.rejectEqualization(access,
            commandId: id, sequence: sequence, decision: decision, allowed: _stillAllowed,
          ));
          _requireScope();
          _changed?.call();
        }
      }
    }
    for (var i = 0; i < (version == 3 ? 2 : 1); i++) {
      final more = await _pull(checkpoint, version, acceptedId, acceptedSequence);
      if (!more) break;
    }
  });

  Future<bool> _pull(
    BusinessCashCheckpoint checkpoint, int version, String? acceptedId, int? acceptedSequence,
  ) async {
    final message = await _call(checkpoint, version, BusinessCashMessage.poll, {});
    final frame = version == 3 ? _object(message) : null;
    final raw = frame == null ? message : frame['deliveries'];
    if (raw is! List || raw.length > 100)
      throw const FormatException('Invalid Business cash page');
    if (frame != null && raw.isEmpty) {
      final head = frame['observed_through'];
      if (head is! int || head < checkpoint.sequence) {
        throw const FormatException('Invalid Business cash head');
      }
      await _local((cash, access) => cash.observeThrough(access, head, allowed: _stillAllowed));
      return false;
    }
    if (frame?['observed_through'] != null) {
      throw const FormatException('Cash page cannot advance an unacknowledged head');
    }
    var previous = 0;
    final ids = <String>{};
    final page = [for (final row in raw) _CashDelivery(_object(row), version)];
    for (final row in page) {
      if (row.sequence <= previous ||
          row.sequence <= checkpoint.sequence ||
          !ids.add(row.id) ||
          (row.id == acceptedId && (row.lines == null || row.sequence != acceptedSequence))) {
        throw const FormatException('Out-of-order Business cash page');
      }
      previous = row.sequence;
    }
    for (final row in page) {
      final durable = await _local((cash, access) => row.lines == null
        ? cash.applyWithdrawal(
            access, commandId: row.id, accountId: row.account!, sequence: row.sequence,
            currency: row.currency!, amountMinor: row.amount!,
          )
        : cash.applyEqualization(access, commandId: row.id, sequence: row.sequence,
            lines: row.lines!, allowed: _stillAllowed),
      );
      if (!durable) return false; // Earlier unresolved spend; do not acknowledge.
      _requireScope();
      _changed?.call();
      final ack = _object(
        await _call(checkpoint, version, BusinessCashMessage.ack, {
          'command_id': row.id,
          'delivery_key': row.deliveryKey,
        }),
      );
      if (ack['command_id'] != row.id ||
          ack['delivery_key'] != row.deliveryKey) {
        throw const FormatException('Cash acknowledgment mismatch');
      }
    }
    return raw.isNotEmpty;
  }
}

BusinessCashDecision _cashDecision(Object? value) => switch (value) {
  'accepted' => BusinessCashDecision.accepted,
  'insufficient_balance' => BusinessCashDecision.insufficientBalance,
  'permission_changed' => BusinessCashDecision.permissionChanged,
  'unavailable_resource' => BusinessCashDecision.unavailableResource,
  'amount_out_of_range' => BusinessCashDecision.amountOutOfRange,
  'stale_measurement' => BusinessCashDecision.staleMeasurement,
  _ => throw const FormatException('Unknown cash decision'),
};

final class _CashDelivery {
  _CashDelivery(Map<String, Object?> row, int version)
    : id = _id(row['command_id']),
      sequence = _positive(row['sequence']),
      deliveryKey = _id(row['delivery_key']) {
    final kind = version == 2 ? 'withdrawal' : row['kind'];
    if (kind == 'withdrawal') {
      account = _id(row['account_id']);
      currency = businessCurrency('${row['currency']}');
      amount = BusinessMoney.checked(_positive(row['amount_minor']));
      lines = null;
    } else if (kind == 'settlement') {
      final entries = row['entries'];
      if (entries is! List || entries.isEmpty || entries.length > 100) {
        throw const FormatException('Invalid equalization delivery');
      }
      lines = entries.map((value) {
        final line = _object(value);
        if (line['expected_minor'] is! int || line['actual_minor'] is! int || line['currency'] is! String) {
          throw const FormatException('Invalid equalization line');
        }
        return (
          accountId: _id(line['account_id']), currency: line['currency'] as String,
          expectedMinor: line['expected_minor'] as int, actualMinor: line['actual_minor'] as int,
        );
      }).toList();
      account = currency = null;
      amount = null;
    } else {
      throw const FormatException('Unknown cash movement');
    }
  }

  final String id, deliveryKey;
  final int sequence;
  late final String? account, currency;
  late final int? amount;
  late final List<BusinessCashEqualizationLine>? lines;
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, dynamic>)
    throw const FormatException('Invalid Business cash data');
  return value;
}

String _id(Object? value) {
  if (value is! String ||
      value != value.toLowerCase() ||
      !isDirectoryId(value)) {
    throw const FormatException('Invalid Business cash identity');
  }
  return value;
}

int _positive(Object? value) {
  if (value is! int || value < 1)
    throw const FormatException('Invalid Business cash number');
  return value;
}
