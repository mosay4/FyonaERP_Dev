import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/services/reminder_codec.dart';

/// Reminder store pure parts:
/// - FNV-1a request codes stable across runs (golden values)
/// - namespace separation debt: vs recur:
/// - entry build + prune/due logic
void main() {
  group('FNV stability', () {
    test('golden values (same across launches, impls, platforms)', () {
      expect(ReminderCodec.requestCode('recur:r1'), 1717315325);
      expect(ReminderCodec.requestCode('debt:d1'), 1131472521);
      expect(ReminderCodec.stableId('r1'), 206831020);
      expect(
        ReminderCodec.requestCode(
            'recur:550e8400-e29b-41d4-a716-446655440000'),
        527812113,
      );
      expect(
        ReminderCodec.requestCode(
            'debt:550e8400-e29b-41d4-a716-446655440000'),
        2032761075,
      );
    });

    test('deterministic within a run', () {
      expect(ReminderCodec.requestCode('recur:x'),
          ReminderCodec.requestCode('recur:x'));
    });

    test('valid non-negative 31-bit range', () {
      for (final k in ['debt:a', 'recur:b', 'debt:', 'recur:xyz-123']) {
        final rc = ReminderCodec.requestCode(k);
        expect(rc >= 0, isTrue, reason: k);
        expect(rc <= 0x7FFFFFFF, isTrue, reason: k);
      }
    });

    test('debt and recur namespaces never collide', () {
      expect(ReminderCodec.debtRequestCode('same-id'),
          isNot(ReminderCodec.recurringRequestCode('same-id')));
    });

    test('convenience helpers match namespaced form', () {
      expect(ReminderCodec.debtRequestCode('d1'),
          ReminderCodec.requestCode('debt:d1'));
      expect(ReminderCodec.recurringRequestCode('r1'),
          ReminderCodec.requestCode('recur:r1'));
    });
  });

  group('routes', () {
    test('debt + recurring deep links', () {
      expect(ReminderCodec.debtRouteFor('d1'), '/personal/debts?debtId=d1');
      expect(ReminderCodec.recurringRouteFor('r1'),
          '/personal/recurring/detail?id=r1');
    });
  });

  group('store entries', () {
    test('buildEntry carries native-bridge fields', () {
      final e = ReminderCodec.buildEntry(
        millis: 123,
        title: 't',
        body: 'b',
        kind: 'recurring',
        refId: 'r1',
        requestCode: 42,
        route: '/personal/recurring/detail?id=r1',
      );
      expect(e['millis'], 123);
      expect(e['kind'], 'recurring');
      expect(e['refId'], 'r1');
      expect(e['requestCode'], 42);
      expect(e['route'], '/personal/recurring/detail?id=r1');
    });

    test('prunePastKeys drops missing + past, keeps future', () {
      const now = 1000;
      final all = <String, Map<String, dynamic>>{
        'recur_future': {'millis': 2000},
        'recur_past': {'millis': 500},
        'recur_zero': {'millis': 0},
        'recur_missing': <String, dynamic>{},
      };
      expect(
        ReminderCodec.prunePastKeys(all, now).toSet(),
        {'recur_past', 'recur_zero', 'recur_missing'},
      );
    });

    test('dueKeys finds passed fire instants only', () {
      const now = 1000;
      final all = <String, Map<String, dynamic>>{
        'a': {'millis': 999},
        'b': {'millis': 1000},
        'c': {'millis': 1001},
      };
      expect(
          ReminderCodec.dueKeys(all, now).toSet(), {'a', 'b'});
    });
  });
}
