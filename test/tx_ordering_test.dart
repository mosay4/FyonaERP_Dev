import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';

/// Execution order for "latest transactions": the operation that ran last is
/// on top, ordered by the created_at fingerprint down to fractions of a
/// second — never by random UUID order when rows share one accounting day.
void main() {
  PersonalTransaction tx({
    required String id,
    String? date,
    String? createdAt,
  }) =>
      PersonalTransaction(
        id: id,
        type: 'expense',
        amount: 10,
        category: 'Food',
        currency: 'SAR',
        date: date == null ? null : DateTime.parse(date),
        createdAt:
            createdAt == null ? null : DateTime.parse(createdAt),
      );

  group('sortTransactionsNewestExecutedFirst', () {
    test('same-day rows order by execution fingerprint, not id', () {
      final list = [
        tx(id: 'zzz', date: '2026-09-27T00:00:00', createdAt: '2026-09-27T10:00:00.100'),
        tx(id: 'aaa', date: '2026-09-27T00:00:00', createdAt: '2026-09-27T10:00:00.900'),
        tx(id: 'mmm', date: '2026-09-27T00:00:00', createdAt: '2026-09-27T10:00:00.300'),
      ];
      sortTransactionsNewestExecutedFirst(list);
      expect(list.map((t) => t.id).toList(), ['aaa', 'mmm', 'zzz']);
    });

    test('fractional seconds decide (microsecond precision)', () {
      final list = [
        tx(id: 'a', date: '2026-09-27T10:00:00', createdAt: '2026-09-27T10:00:00.000001'),
        tx(id: 'b', date: '2026-09-27T10:00:00', createdAt: '2026-09-27T10:00:00.000002'),
      ];
      sortTransactionsNewestExecutedFirst(list);
      expect(list.first.id, 'b');
    });

    test('different days still order newest day first', () {
      final list = [
        tx(id: 'old', date: '2026-09-20T00:00:00', createdAt: '2026-09-20T10:00:00'),
        tx(id: 'new', date: '2026-09-27T00:00:00', createdAt: '2026-09-27T09:00:00'),
      ];
      sortTransactionsNewestExecutedFirst(list);
      expect(list.map((t) => t.id).toList(), ['new', 'old']);
    });

    test('missing fingerprint falls back to date, then id', () {
      final list = [
        tx(id: 'b', date: '2026-09-27T00:00:00'),
        tx(id: 'a', date: '2026-09-27T00:00:00'),
        tx(id: 'c', date: null),
      ];
      sortTransactionsNewestExecutedFirst(list);
      expect(list.map((t) => t.id).toList(), ['b', 'a', 'c']);
    });

    test('execution stamp outranks a backdated accounting date', () {
      final list = [
        tx(id: 'backdated', date: '2026-01-01T00:00:00', createdAt: '2026-09-27T12:00:00'),
        tx(id: 'older-run', date: '2026-09-27T00:00:00', createdAt: '2026-09-26T12:00:00'),
      ];
      sortTransactionsNewestExecutedFirst(list);
      expect(list.first.id, 'backdated',
          reason: 'what ran last shows first');
    });
  });
}
