import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/chat_timeline.dart';

Map<String, dynamic> message(int i, {bool mine = false}) => {
  'id': '$i',
  'mine': mine,
  'kind': 'text',
  'text': 'Message $i',
  'created_at': DateTime(2026).add(Duration(seconds: i)).toIso8601String(),
};

void main() {
  test('idempotency fallback dedupes text, invoice and media across pages', () {
    final timeline = ChatTimeline();
    final accepted = <Map<String, dynamic>>[];
    for (final (i, kind) in ['text', 'invoice', 'image', 'album'].indexed) {
      final pending = {
        ...message(i, mine: true),
        'id': 'pending-$i',
        'kind': kind,
        'client_message_id': 'key-$i',
        'busy': true,
      };
      timeline.merge([pending]);
      final server = {
        ...message(i, mine: true),
        'kind': kind,
        'idempotency_key': 'key-$i',
        'delivered': true,
      };
      accepted.add(server);
      timeline.merge([server]);
      timeline.merge([pending]); // A late retry must not restore its clock.
    }
    timeline.merge(accepted, live: true);
    timeline.merge(accepted.reversed.toList(), older: true);
    timeline.merge([
      for (final server in accepted)
        Map<String, dynamic>.from(server)..remove('idempotency_key'),
    ]);
    expect(timeline.messages, hasLength(4));
    expect(timeline.messages.every((m) => m['busy'] == null), isTrue);
    expect(timeline.messages.map(ChatTimeline.clientId).toSet(), {
      'key-0',
      'key-1',
      'key-2',
      'key-3',
    });
    // An equal key from the other side is a distinct message.
    timeline.merge([
      {...message(5), 'idempotency_key': 'key-0'},
    ]);
    expect(timeline.messages, hasLength(5));
  });

  test(
    'canonical key collapses pre-existing server/pending pairs atomically',
    () {
      for (final reverse in [false, true]) {
        final timeline = ChatTimeline();
        final pending = {
          ...message(1, mine: true),
          'id': 'pending',
          'client_id': 'c1',
          'busy': true,
          'failed': true,
        };
        final server = {...message(1, mine: true), 'id': 1};
        timeline.messages.addAll(
          reverse ? [server, pending] : [pending, server],
        );
        timeline.merge([
          {...server, 'client_message_id': 'c1', 'read': true},
        ]);
        expect(timeline.messages, hasLength(1));
        expect(timeline.messages.single['busy'], isNull);
        expect(timeline.messages.single['failed'], isNull);
        timeline.merge([
          {...server, 'id': '1', 'read': true},
        ]);
        timeline.merge([pending]); // Stale retry cannot resurrect the clock.
        expect(timeline.messages, hasLength(1));
        expect(timeline.messages.single['id'], '1');
        expect(timeline.messages.single['busy'], isNull);
      }
    },
  );

  test(
    'rapid optimistic sends reconcile by client id across refresh and retry',
    () {
      final timeline = ChatTimeline();
      for (var i = 0; i < 3; i++) {
        timeline.merge([
          {
            ...message(i, mine: true),
            'id': 'pending-$i',
            'client_id': 'c$i',
            'busy': true,
          },
        ]);
      }
      final accepted = List.generate(
        3,
        (i) => {
          ...message(i, mine: true),
          'client_id': 'c$i',
          'delivered': true,
        },
      );
      timeline.merge(accepted, live: true);
      timeline.merge(accepted, older: true);
      timeline.merge(accepted);
      expect(timeline.messages.length, 3);
      expect(timeline.messages.every((m) => m['busy'] == null), true);
      expect(timeline.messages.map((m) => m['id']), ['0', '1', '2']);
      for (var i = 0; i < 3; i++) {
        expect(timeline.accepted('c$i'), true);
        expect(timeline.accepted('c$i'), false);
        expect(timeline.rendered('$i'), false);
      }
    },
  );

  test(
    'send once, receive only on first live render; history/refresh never replay',
    () {
      final timeline = ChatTimeline();
      timeline.merge([message(1)]);
      expect(timeline.rendered('1'), false);
      timeline.merge([message(2)], live: true);
      expect(timeline.rendered('2'), true);
      expect(timeline.rendered('2'), false);
      expect(timeline.merge([message(2)], live: true), false);
      expect(timeline.rendered('2'), false);
      timeline.merge([message(0)], older: true);
      expect(timeline.rendered('0'), false);
      expect(timeline.accepted('3'), true);
      expect(timeline.accepted('3'), false);
      timeline.merge([message(3, mine: true)], live: true);
      expect(timeline.rendered('3'), false);
      expect(timeline.messages.length, 4);
    },
  );

  test(
    '5000 messages in bounded pages keep memory capped and merge responsive',
    () {
      final timeline = ChatTimeline();
      final watch = Stopwatch()..start();
      for (var i = 0; i < 5000; i += ChatTimeline.pageSize) {
        timeline.merge(
          List.generate(ChatTimeline.pageSize, (j) => message(i + j)),
          live: true,
        );
        expect(
          timeline.messages.length,
          lessThanOrEqualTo(ChatTimeline.capacity),
        );
      }
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(5000));
      expect(timeline.messages.first['id'], '4500');
      timeline.merge(List.generate(40, (i) => message(4460 + i)), older: true);
      expect(timeline.messages.first['id'], '4460');
      expect(timeline.messages.length, ChatTimeline.capacity);
    },
  );
}
