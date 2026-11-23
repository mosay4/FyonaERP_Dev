import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/chat_page.dart';
import 'package:fyona_flutter/features/personal/data/chat_upload_manager.dart';
import 'package:fyona_flutter/features/personal/data/chat_sounds.dart';
import 'package:fyona_flutter/features/personal/data/active_chat.dart';

class _SoundSpy implements ChatSounds {
  int sent = 0;
  int received = 0;
  @override
  void play({required bool sent}) {
    if (sent) {
      this.sent++;
    } else {
      received++;
    }
  }

  @override
  void dispose() {}
}

class _Stage4Chat extends _FakeChat {
  final rows = <Map<String, dynamic>>[];
  final responses = <Completer<Map<String, dynamic>>>[];
  final presence = <bool>[];
  @override
  Future<void> chatPresence(
    String linkId, {
    bool active = true,
    String? side,
  }) async {
    presence.add(active);
  }

  @override
  Future<List<Map<String, dynamic>>> chatMessages(
    String linkId, {
    String? after,
    String? before,
    String? around,
    String? side,
    int limit = 40,
    bool waitForChanges = false,
    CancelToken? cancelToken,
  }) async => rows.map((m) => Map<String, dynamic>.from(m)).toList();
  @override
  Future<Map<String, dynamic>> sendChat(
    String linkId, {
    required String kind,
    String? side,
    String? text,
    String? mediaPath,
    String? fileName,
    String? invoiceId,
    String? replyToId,
    int? durationMs,
    List<Map<String, dynamic>>? media,
    String? clientId,
  }) {
    rows.add({
      'id': 'server-$clientId',
      'client_id': clientId,
      'mine': true,
      'kind': kind,
      'text': text,
      'delivered': true,
      'read': true,
      'created_at': DateTime(
        2026,
      ).add(Duration(seconds: rows.length)).toIso8601String(),
    });
    final response = Completer<Map<String, dynamic>>();
    responses.add(response);
    return response.future;
  }
}

class _FakeChat extends MerchantApi {
  _FakeChat() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> chatInfo(String linkId, {String? side}) async =>
      {
        'link_id': linkId,
        'is_merchant': false,
        'other_name': 'بقالة النور',
        'other_avatar': null,
        'online': true,
        'unread': 1,
      };
  @override
  Future<List<Map<String, dynamic>>> chatMessages(
    String linkId, {
    String? after,
    String? before,
    String? around,
    String? side,
    int limit = 40,
    bool waitForChanges = false,
    CancelToken? cancelToken,
  }) async => [
    {
      'id': 'm1',
      'mine': false,
      'kind': 'text',
      'text': 'أهلاً بك',
      'delivered': true,
      'read': true,
      'created_at': '2026-10-17T10:00:00',
    },
    {
      'id': 'm2',
      'mine': true,
      'kind': 'invoice',
      'invoice_id': 'inv1',
      'invoice_number': 'INV-0012',
      'delivered': true,
      'read': true,
      'created_at': '2026-10-17T10:01:00',
    },
  ];
  @override
  Future<void> markChatRead(String linkId) async {}
  @override
  Future<void> chatPresence(
    String linkId, {
    bool active = true,
    String? side,
  }) async {}
  @override
  Future<List<Map<String, dynamic>>> chatInvoices(
    String linkId, {
    String? q,
  }) async => [];
}

class _FourMessagesChat extends _Stage4Chat {
  @override
  Future<List<Map<String, dynamic>>> chatInvoices(
    String linkId, {
    String? q,
  }) async => [
    {'id': 'inv-four', 'number': 'INV-FOUR', 'total': '100', 'currency': 'SAR'},
  ];

  @override
  Future<Map<String, dynamic>> sendChat(
    String linkId, {
    required String kind,
    String? side,
    String? text,
    String? mediaPath,
    String? fileName,
    String? invoiceId,
    String? replyToId,
    int? durationMs,
    List<Map<String, dynamic>>? media,
    String? clientId,
  }) {
    final response = super.sendChat(
      linkId,
      kind: kind,
      text: text,
      clientId: clientId,
    );
    rows.last
      ..remove('client_id')
      ..['idempotency_key'] = clientId
      ..['invoice_id'] = invoiceId
      ..['invoice_number'] = kind == 'invoice' ? 'INV-FOUR' : null;
    return response;
  }
}

class _LongChat extends _FakeChat {
  final limits = <int>[];
  final olderCursors = <String>[];
  final sendIds = <String?>[];
  @override
  Future<List<Map<String, dynamic>>> chatMessages(
    String linkId, {
    String? after,
    String? before,
    String? around,
    String? side,
    int limit = 40,
    bool waitForChanges = false,
    CancelToken? cancelToken,
  }) async {
    limits.add(limit);
    if (before != null) olderCursors.add(before);
    if (after != null) return [];
    final end = before == null ? 5000 : int.parse(before);
    final start = (end - limit).clamp(0, end);
    return List.generate(
      end - start,
      (j) => {
        'id': '${start + j}',
        'mine': false,
        'kind': 'text',
        'text': 'Message ${start + j}',
        'read': true,
        'created_at': DateTime(
          2026,
        ).add(Duration(seconds: start + j)).toIso8601String(),
      },
    );
  }

  @override
  Future<Map<String, dynamic>> sendChat(
    String linkId, {
    required String kind,
    String? side,
    String? text,
    String? mediaPath,
    String? fileName,
    String? invoiceId,
    String? replyToId,
    int? durationMs,
    List<Map<String, dynamic>>? media,
    String? clientId,
  }) async {
    sendIds.add(clientId);
    if (sendIds.length == 1) {
      throw DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionTimeout,
      );
    }
    return {
      'message': {
        'id': 'accepted',
        'client_id': clientId,
        'mine': true,
        'kind': 'text',
        'text': text,
        'read': true,
        'created_at': '2027-01-01T00:00:00',
      },
    };
  }
}

class _RetryChat extends _LongChat {
  int failures = 3;
  int uploads = 0;
  @override
  Future<List<Map<String, dynamic>>> chatInvoices(
    String linkId, {
    String? q,
  }) async => [
    {
      'id': 'invoice-new',
      'number': 'INV-RETRY',
      'total': '100',
      'currency': 'SAR',
    },
  ];
  @override
  Future<Map<String, String>> uploadChatMedia(
    String linkId,
    List<int> bytes,
    String filename,
    String mime, {
    String? path,
    CancelToken? cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    uploads++;
    return {'url': 'uploads/$filename'};
  }

  @override
  Future<Map<String, dynamic>> sendChat(
    String linkId, {
    required String kind,
    String? side,
    String? text,
    String? mediaPath,
    String? fileName,
    String? invoiceId,
    String? replyToId,
    int? durationMs,
    List<Map<String, dynamic>>? media,
    String? clientId,
  }) async {
    sendIds.add(clientId);
    if (failures-- > 0)
      throw DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionTimeout,
      );
    return {
      'message': {
        'id': 'server-$clientId',
        'client_id': clientId,
        'kind': kind,
        'invoice_id': invoiceId,
        'invoice_number': kind == 'invoice' ? 'INV-RETRY' : null,
        'file_name': fileName,
        'mine': true,
        'text': text,
        'read': true,
        'created_at': '2027-01-01T00:00:00',
      },
    };
  }
}

Future<void> _open(
  WidgetTester tester,
  MerchantApi api, {
  ChatUploadManager? uploads,
  ChatSounds? sounds,
}) async {
  await tester.runAsync(() => AppLocalizations.preload('ar'));
  SharedPreferences.setMockInitialValues(const {});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [merchantApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ChatPage(
          linkId: 'L1',
          isMerchant: false,
          uploadManager: uploads,
          sounds: sounds,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('disposing the chat scope leaves no deferred presence errors', (
    tester,
  ) async {
    final api = _Stage4Chat();
    await _open(tester, api);
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(ChatPage)),
      ).read(activeChatViewProvider)?.linkId,
      'L1',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));

    expect(api.presence.last, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving chat clears local presence in a surviving scope', (
    tester,
  ) async {
    final api = _Stage4Chat();
    await _open(tester, api);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatPage)),
    );
    final subscription = container.listen(activeChatViewProvider, (_, __) {});
    expect(container.read(activeChatViewProvider)?.linkId, 'L1');
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(container.read(activeChatViewProvider), isNull);
    expect(api.presence.last, false);
    expect(tester.takeException(), isNull);
    subscription.close();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'R00: 3 texts + invoice, ack and refresh leave exactly 4 bubbles and no clocks',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _FourMessagesChat();
      await _open(tester, api);
      for (var i = 0; i < 3; i++) {
        await tester.enterText(find.byType(TextField).first, 'R00 text $i');
        tester.widget<TextField>(find.byType(TextField).first).onSubmitted!('');
        await tester.pump();
      }
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byIcon(Icons.receipt_long_outlined).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('INV-FOUR'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(FilledButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(api.rows, hasLength(4));
      // Old server responses without an echo still bind to the originating row.
      for (final i in [0, 3]) {
        final ack = Map<String, dynamic>.from(api.rows[i])
          ..remove('idempotency_key');
        api.responses[i].complete({'message': ack});
      }
      await tester.pump();
      // Poll accepts the other two before their HTTP responses arrive.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      for (final i in [1, 2]) {
        api.responses[i].complete({'message': api.rows[i]});
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 13));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        expect(find.text('R00 text $i'), findsOneWidget);
      }
      expect(find.textContaining('INV-FOUR'), findsOneWidget);
      expect(find.byIcon(Icons.schedule), findsNothing);
      expect(find.byType(ListTile), findsNothing); // No gray outbox duplicates.
      final list = tester.widget<ListView>(find.byType(ListView).first);
      expect(list.childrenDelegate.estimatedChildCount, 4);
      expect(find.byIcon(Icons.done_all), findsNWidgets(4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'Stage4 rapid sends poll before response, refresh, 3+3 sounds and lifecycle',
    (tester) async {
      final api = _Stage4Chat();
      final sounds = _SoundSpy();
      await _open(tester, api, sounds: sounds);
      expect(api.presence, [true]);
      for (var i = 0; i < 3; i++) {
        await tester.enterText(find.byType(TextField).first, 'Outgoing $i');
        tester.widget<TextField>(find.byType(TextField).first).onSubmitted!(
          'Outgoing $i',
        );
        await tester.pump();
      }
      expect(sounds.sent, 3); // Not delayed until HTTP returns.
      expect(find.byIcon(Icons.schedule), findsNWidgets(3));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        expect(find.text('Outgoing $i'), findsOneWidget);
        api.responses[i].complete({'message': api.rows[i]});
      }
      await tester.pump();
      expect(find.byIcon(Icons.schedule), findsNothing);
      expect(sounds.sent, 3);
      for (var i = 0; i < 3; i++) {
        api.rows.add({
          'id': 'incoming-$i',
          'mine': false,
          'kind': 'text',
          'text': 'Incoming $i',
          'read': true,
          'created_at': DateTime(
            2026,
          ).add(Duration(minutes: i + 1)).toIso8601String(),
        });
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
      }
      expect(sounds.received, 3);
      await tester.enterText(find.byType(TextField).first, 'rebuild only');
      await tester.pump(const Duration(seconds: 12));
      await tester.pump();
      expect((sounds.sent, sounds.received), (3, 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(api.presence.last, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.presence.last, true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(api.presence.last, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invoice keeps one red optimistic row; manual retry succeeds with same ID',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _RetryChat();
      await _open(tester, api);
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byIcon(Icons.receipt_long_outlined).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('INV-RETRY'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(FilledButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pump();
      expect(api.sendIds.length, 3);
      final key = ValueKey<String>(api.sendIds.first!);
      expect(find.byKey(key), findsOneWidget);
      final row = tester.widget<ListTile>(find.byKey(key));
      expect((row.title! as Text).style!.color, Colors.red);
      final retry = find.descendant(
        of: find.byKey(key),
        matching: find.byIcon(Icons.refresh),
      );
      await tester.tap(retry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.sendIds.length, 4);
      expect(api.sendIds.toSet().length, 1);
      expect(find.byKey(key), findsNothing);
      expect(find.textContaining('INV-RETRY'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'file failure row retries once without duplicates alongside 5000-message history',
    (tester) async {
      final api = _RetryChat();
      final uploads = ChatUploadManager(persist: false, wait: (_) async {});
      await _open(tester, api, uploads: uploads);
      uploads.enqueueSingle(
        api: api,
        linkId: 'L1',
        side: 'personal',
        kind: 'file',
        fileName: 'retry.pdf',
      );
      final id = uploads.pending('L1').single['id'];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final failedKey = ValueKey('failed-upload-$id');
      expect(find.byKey(failedKey), findsOneWidget);
      final row = tester.widget<ListTile>(find.byKey(failedKey));
      expect((row.title! as Text).style!.color, Colors.red);
      await tester.enterText(
        find.byType(TextField).first,
        'Composer remains responsive',
      );
      await tester.tap(find.byKey(ValueKey('retry-upload-$id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(uploads.pending('L1'), isEmpty);
      expect(find.byKey(failedKey), findsNothing);
      expect(api.uploads, 1);
      expect(api.sendIds.length, 4);
      expect(api.sendIds.toSet().length, 1);
      expect(find.text('retry.pdf'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    '5000-message conversation builds lazily, paginates, retries only failed send',
    (tester) async {
      final api = _LongChat();
      final watch = Stopwatch()..start();
      await _open(tester, api);
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(5000));
      // Realtime and receipt refreshes may also request bounded recent pages.
      expect(api.limits, isNotEmpty);
      expect(api.limits.every((limit) => limit == 40), true);
      expect(api.olderCursors, isEmpty);
      expect(find.text('Message 4999'), findsOneWidget);
      expect(find.text('Message 0'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView).first, const Offset(0, 6000));
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.olderCursors, isNotEmpty);
      expect(api.limits.every((limit) => limit == 40), true);
      await tester.enterText(find.byType(TextField).first, 'Retry once');
      tester.widget<TextField>(find.byType(TextField).first).onSubmitted!(
        'Retry once',
      );
      await tester.pump();
      expect(api.sendIds.length, 1);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(api.sendIds.length, 2);
      expect(api.sendIds.toSet().length, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(api.sendIds.length, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets('chat page renders header, messages and read receipt', (
    tester,
  ) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    SharedPreferences.setMockInitialValues(const {});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [merchantApiProvider.overrideWithValue(_FakeChat())],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ChatPage(linkId: 'L1', isMerchant: false),
        ),
      ),
    );
    // Polling timer → use pump (not pumpAndSettle).
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.text('بقالة النور'), findsOneWidget);
    expect(find.text('أهلاً بك'), findsOneWidget);
    expect(find.textContaining('INV-0012'), findsOneWidget);
    // Read receipt for my message → blue double check.
    expect(find.byIcon(Icons.done_all), findsWidgets);
    final avatar = tester.getRect(
      find.byKey(const ValueKey('chat-peer-avatar')),
    );
    final name = tester.getRect(find.byKey(const ValueKey('chat-peer-name')));
    final status = tester.getRect(
      find.byKey(const ValueKey('chat-peer-status')),
    );
    final back = tester.getRect(find.byKey(const ValueKey('chat-back')));
    expect(avatar.left, greaterThan(name.right));
    expect((avatar.left - name.right).abs(), lessThan(14));
    expect((name.right - status.right).abs(), lessThan(20));
    expect(status.top, greaterThan(name.top));
    expect(back.right, lessThan(name.left));
  });
}
