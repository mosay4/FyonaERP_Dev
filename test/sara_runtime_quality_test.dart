import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyona_flutter/features/ai/domain/agent/chat_persistence.dart';
import 'package:fyona_flutter/features/ai/domain/agent/verification_gateway.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'dart:io';

class FakePath extends PathProviderPlatform {
  final Directory d;
  FakePath(this.d);
  @override
  Future<String?> getApplicationDocumentsPath() async => d.path;
  @override
  Future<String?> getTemporaryPath() async => d.path;
  @override
  Future<String?> getApplicationSupportPath() async => d.path;
}

void main() {
  group('runtime 7 scenarios', () {
    late Directory tmp;
    setUpAll(() async {
      sqfliteFfiInit();
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('sara_runtime');
      PathProviderPlatform.instance = FakePath(tmp);
    });

    test('1 normal -> collect -> confirm -> tool -> verification', () async {
      const user = 'rt1_personal';
      await ChatPersistence.instance.clearMessages(user);
      await ChatPersistence.instance.appendMessage(user, ChatPersistMessage(id: 'u1', text: 'سجل مصروف 5000 للطعام', role: 'user', time: DateTime.now()));
      // Simulate tool execution via gateway
      final gateway = SaraVerificationGateway(readLocal: (_, __) async => {'id': '123'});
      final res = await gateway.verifyCreate(
        tool: 'create_transaction', queueEntityType: 'personal_transaction',
        resolveId: () async => '123', successAr: 'تم', successEn: 'done', failureAr: 'فشل', failureEn: 'fail');
      expect(res.state, SaraVerificationState.successLocalPendingSync);
      await ChatPersistence.instance.appendMessage(user, ChatPersistMessage(id: 'a1', text: 'تم تسجيل المصروف 5000', role: 'assistant', time: DateTime.now()));
      final rel = await ChatPersistence.instance.retrieveRelevant(user, 'كم كان المبلغ؟');
      expect(rel.any((m) => m.text.contains('5000')), isTrue);
    });

    test('2 multi-currency question', () async {
      const user = 'rt2_personal';
      await ChatPersistence.instance.clearMessages(user);
      await ChatPersistence.instance.saveMessages(user, [
        ChatPersistMessage(id: '1', text: 'رصيد SAR 1000', role: 'assistant', time: DateTime.now()),
        ChatPersistMessage(id: '2', text: 'رصيد YER_NEW 500000', role: 'assistant', time: DateTime.now().add(const Duration(seconds: 1))),
      ]);
      final rel = await ChatPersistence.instance.retrieveRelevant(user, 'كم رصيدي؟');
      expect(rel.length, lessThanOrEqualTo(10));
      expect(rel.any((m) => m.text.contains('SAR')), isTrue);
      expect(rel.any((m) => m.text.contains('YER_NEW')), isTrue);
    });

    test('3 vague -> clarification -> specify -> execute', () async {
      const user = 'rt3_personal';
      await ChatPersistence.instance.clearMessages(user);
      await ChatPersistence.instance.appendMessage(user, ChatPersistMessage(id: 'u1', text: 'سجل مصروف', role: 'user', time: DateTime.now()));
      // Should be considered incomplete, not executed
      // Simulate asking for amount
      final rel = await ChatPersistence.instance.retrieveRelevant(user, 'كم المبلغ؟');
      expect(rel.any((m) => m.text.contains('سجل مصروف')), isTrue);
    });

    test('4 correction -> re-confirm -> once', () async {
      final gateway = SaraVerificationGateway(readLocal: (_, __) async => {'id': '1'});
      final opKey = SaraVerificationGateway.opKeyFor('create_transaction', {'amount': 5000});
      int calls = 0;
      Future<SaraVerificationResult> run() async {
        calls++;
        return SaraVerificationResult(state: SaraVerificationState.successConfirmed, tool: 'create_transaction', messageAr: 'ok', messageEn: 'ok', serverConfirmed: true, syncState: 'none');
      }
      final r1 = gateway.executeOnce(opKey: opKey, run: run);
      final r2 = gateway.executeOnce(opKey: opKey, run: run);
      await Future.wait([r1, r2]);
      expect(calls, 1);
    });

    test('5 question about old conversation', () async {
      const user = 'rt5_personal';
      await ChatPersistence.instance.clearMessages(user);
      await ChatPersistence.instance.saveMessages(user, [
        ChatPersistMessage(id: 'old', text: 'راتبي 500 ألف', role: 'user', time: DateTime.now().subtract(const Duration(days: 1))),
        ChatPersistMessage(id: 'new', text: 'ما راتبي؟', role: 'user', time: DateTime.now()),
      ]);
      final rel = await ChatPersistence.instance.retrieveRelevant(user, 'ما راتبي؟');
      expect(rel.any((m) => m.text.contains('500 ألف')), isTrue);
    });

    test('6 real failure -> real message', () async {
      final gateway = SaraVerificationGateway(readLocal: (_, __) async => null);
      final res = await gateway.verifyCreate(
        tool: 'create_transaction', queueEntityType: 'personal_transaction',
        resolveId: () async => null, successAr: 'ok', successEn: 'ok', failureAr: 'فشل العملية', failureEn: 'failed');
      expect(res.state, SaraVerificationState.notFound);
      expect(res.messageAr, 'فشل العملية');
    });

    test('7 success -> confirmed', () async {
      final gateway = SaraVerificationGateway(
        readLocal: (_, id) async => {'id': id},
        readServer: (_, __) async => {'id': '123'},
      );
      final res = await gateway.verifyCreate(
        tool: 'create_transaction', queueEntityType: 'personal_transaction',
        resolveId: () async => '123', successAr: 'تم بنجاح', successEn: 'done', failureAr: 'fail', failureEn: 'fail');
      expect(res.state, SaraVerificationState.successConfirmed);
      expect(res.messageAr, 'تم بنجاح');
    });
  });
}
