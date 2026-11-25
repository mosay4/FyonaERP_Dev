import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_offline_notice.dart';

/// Personal Sara is ONLINE-ONLY: offline she shows a calm notice and never
/// answers from device data nor runs the local agent loop. Business Sara and
/// the on-device smart notifications are untouched.
void main() {
  test('policy: only Personal chat is blocked offline', () {
    expect(SaraOnlinePolicy.chatBlocked(accountType: 'personal', online: false), isTrue);
    expect(SaraOnlinePolicy.chatBlocked(accountType: 'personal', online: true), isFalse);
    expect(SaraOnlinePolicy.chatBlocked(accountType: 'business', online: false), isFalse);
    expect(SaraOnlinePolicy.allowsOfflineFallback('personal'), isFalse);
    expect(SaraOnlinePolicy.allowsOfflineFallback('business'), isTrue);
  });

  test('AI service never falls back to local answers for Personal', () {
    final src = File('lib/features/ai/domain/services/ai_service.dart').readAsStringSync();
    final calls = 'OfflineSara.answer('.allMatches(src).length;
    final gates = 'SaraOnlinePolicy.allowsOfflineFallback(accountType)'.allMatches(src).length;
    expect(calls, 2);
    expect(gates, calls, reason: 'every offline fallback is gated');
  });

  test('chat refuses the turn offline BEFORE any local processing', () {
    final src = File('lib/shared/widgets/sara_chat_page.dart').readAsStringSync();
    final send = src.split('Future<void> _send({String? text}) async {').last;
    final guard = send.indexOf('if (_blockedOffline()) return;');
    expect(guard, greaterThan(0));
    for (final local in ['_ambient.send()', '_handleMismatchReply', '_tryDirectBankCommand', '_executeToolFromContext', 'aiService.askQuestion']) {
      expect(send.indexOf(local), greaterThan(guard), reason: '$local after guard');
    }
    for (final entry in ['void _handleConfirmAction(_ChatMessage msg) {', 'void _retry(String query) {', 'void _sendPendingAudio() {']) {
      final body = src.split(entry).last.split('\n  }\n').first;
      expect(body, contains('_blockedOffline()'), reason: entry);
    }
    expect(src, contains("widget.accountType == 'personal' && _offline"));
    // Smart notifications stay independent of the chat.
    for (final f in Directory('lib/features/personal/services/smart_insights').listSync().whereType<File>()) {
      final s = f.readAsStringSync();
      expect(s, isNot(contains('sara_chat_page')), reason: f.path);
      expect(s, isNot(contains('connectivity')), reason: f.path);
    }
  });

  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('offline notice renders and settles ($lang, dark=$dark)', (t) async {
        await t.runAsync(() => AppLocalizations.delegate.load(Locale(lang)));
        var retried = 0;
        await t.pumpWidget(MaterialApp(
          locale: Locale(lang),
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SaraOfflineNotice(onRetry: () => retried++)),
        ));
        await t.pumpAndSettle();
        expect(find.byKey(const Key('saraOfflineNotice')), findsOneWidget);
        expect(
          find.text(lang == 'ar' ? 'سارة تحتاج إنترنت' : 'Sara needs the internet'),
          findsOneWidget,
        );
        await t.tap(find.byKey(const Key('saraOfflineRetry')));
        await t.pumpAndSettle();
        expect(retried, 1);
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    }
  }
}
