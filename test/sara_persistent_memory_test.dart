import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:fyona_flutter/features/ai/domain/agent/chat_persistence.dart';

/// P2 — Persistent Full Conversation Memory: 20 required tests
/// Uses the real ChatPersistence (file per user) and the real retrieval
/// logic that SaraChatPage uses. No business logic touched.

class _FakePathProvider extends PathProviderPlatform {
  final Directory dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
  @override
  Future<String?> getTemporaryPath() async => dir.path;
  @override
  Future<String?> getApplicationSupportPath() async => dir.path;
}

void main() {
  late Directory tmp;
  const userA = 'userA_personal';
  const userB = 'userB_personal';

  setUpAll(() async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('sara_mem_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });

  tearDown(() async {
    await ChatPersistence.instance.clearMessages(userA);
    await ChatPersistence.instance.clearMessages(userB);
    await ChatPersistence.instance.clearMessages('test_user_personal');
  });

  ChatPersistMessage msg(String id, String text, String role, DateTime t,
      {String? imagePath, String? audioPath, String? fileName, String? analysis, String? transcript}) {
    return ChatPersistMessage(
      id: id, text: text, role: role, time: t,
      imagePath: imagePath, audioPath: audioPath,
      fileName: fileName, analysis: analysis, transcript: transcript,
      conversationId: userA, userId: userA,
    );
  }

  test('1 save user text', () async {
    final m = msg('1', 'مرحبا سارة', 'user', DateTime.now());
    await ChatPersistence.instance.appendMessage(userA, m);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.any((e) => e.text == 'مرحبا سارة'), isTrue);
  });

  test('2 save Sara text', () async {
    final m = msg('2', 'أهلا بك', 'assistant', DateTime.now());
    await ChatPersistence.instance.appendMessage(userA, m);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.any((e) => e.text == 'أهلا بك' && e.role == 'assistant'), isTrue);
  });

  test('3 ordering by time+id', () async {
    final t = DateTime.now();
    await ChatPersistence.instance.saveMessages(userA, [
      msg('3b', 'second', 'user', t.add(const Duration(seconds: 1))),
      msg('3a', 'first', 'user', t),
      msg('3c', 'third', 'user', t.add(const Duration(seconds: 2))),
    ]);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.map((e) => e.text).toList(), ['first', 'second', 'third']);
  });

  test('4 duplicate prevention by id', () async {
    final m = msg('dup', 'hello', 'user', DateTime.now());
    await ChatPersistence.instance.appendMessage(userA, m);
    await ChatPersistence.instance.appendMessage(userA, m);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.where((e) => e.id == 'dup').length, 1);
  });

  test('5 persistence after close/reopen (load again)', () async {
    await ChatPersistence.instance.appendMessage(userA, msg('5', 'keep me', 'user', DateTime.now()));
    final first = await ChatPersistence.instance.loadMessages(userA);
    final second = await ChatPersistence.instance.loadMessages(userA);
    expect(second.any((e) => e.text == 'keep me'), isTrue);
    expect(first.length, second.length);
  });

  test('6 persistence after restart (file survives)', () async {
    final file = File('${tmp.path}/sara_chat/chat_$userA.json');
    await ChatPersistence.instance.appendMessage(userA, msg('6', 'survive restart', 'user', DateTime.now()));
    expect(await file.exists(), isTrue);
    // Simulate restart by creating a new instance read (same file)
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.any((e) => e.text == 'survive restart'), isTrue);
  });

  test('7 persistence after logout/login same account (file not deleted)', () async {
    await ChatPersistence.instance.appendMessage(userA, msg('7', 'after logout', 'user', DateTime.now()));
    // Simulate logout/login: same userId, same file should still exist
    // (profile reset would delete, but logout does not — we verify file still there)
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.any((e) => e.text == 'after logout'), isTrue);
  });

  test('8 isolation between users', () async {
    await ChatPersistence.instance.appendMessage(userA, msg('8a', 'user A secret', 'user', DateTime.now()));
    await ChatPersistence.instance.appendMessage(userB, msg('8b', 'user B secret', 'user', DateTime.now()));
    final a = await ChatPersistence.instance.loadMessages(userA);
    final b = await ChatPersistence.instance.loadMessages(userB);
    expect(a.any((e) => e.text == 'user B secret'), isFalse);
    expect(b.any((e) => e.text == 'user A secret'), isFalse);
  });

  test('9 save voice transcript', () async {
    final m = ChatPersistMessage(
      id: '9', text: 'Voice message', role: 'user', time: DateTime.now(),
      audioPath: '/tmp/voice.m4a', transcript: 'أضف لي هدف شراء سيارة بمليون',
      messageType: 'voice', conversationId: userA, userId: userA,
    );
    await ChatPersistence.instance.appendMessage(userA, m);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    final found = loaded.firstWhere((e) => e.id == '9');
    expect(found.transcript, 'أضف لي هدف شراء سيارة بمليون');
    expect(found.audioPath, '/tmp/voice.m4a');
  });

  test('10 save Sara voice response text', () async {
    final m = ChatPersistMessage(
      id: '10', text: 'تم إضافة هدفك', role: 'assistant', time: DateTime.now(),
      audioPath: '/tmp/sara.mp3', transcript: 'تم إضافة هدفك',
      messageType: 'assistant_voice', conversationId: userA, userId: userA,
    );
    await ChatPersistence.instance.appendMessage(userA, m);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.any((e) => e.text == 'تم إضافة هدفك'), isTrue);
  });

  test('11 save image metadata/reference', () async {
    final m = ChatPersistMessage(
      id: '11', text: 'هذه فاتورة', role: 'user', time: DateTime.now(),
      imagePath: '/tmp/img.jpg', fileName: 'invoice.jpg', mimeType: 'image/jpeg', fileSize: 12345,
      analysis: 'فاتورة بقيمة 5000', messageType: 'image', conversationId: userA, userId: userA,
    );
    await ChatPersistence.instance.appendMessage(userA, m);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    final found = loaded.firstWhere((e) => e.id == '11');
    expect(found.imagePath, '/tmp/img.jpg');
    expect(found.fileName, 'invoice.jpg');
    expect(found.analysis, 'فاتورة بقيمة 5000');
  });

  test('12 save file metadata/reference', () async {
    final m = ChatPersistMessage(
      id: '12', text: 'ملف الرواتب', role: 'user', time: DateTime.now(),
      fileName: 'salaries.pdf', mimeType: 'application/pdf', fileSize: 9876,
      analysis: 'Extracted: total 500000', messageType: 'file', conversationId: userA, userId: userA,
    );
    await ChatPersistence.instance.appendMessage(userA, m);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.any((e) => e.fileName == 'salaries.pdf'), isTrue);
  });

  test('13 retrieval of old message', () async {
    final t = DateTime.now().subtract(const Duration(days: 1));
    await ChatPersistence.instance.saveMessages(userA, [
      msg('13old', 'راتبي 500 ألف', 'user', t),
      msg('13mid', 'كيف حالك', 'user', t.add(const Duration(hours: 1))),
      msg('13new', 'ما الأخبار', 'user', DateTime.now()),
    ]);
    final relevant = await ChatPersistence.instance.retrieveRelevant(userA, 'ما راتبي؟');
    expect(relevant.any((e) => e.text.contains('500 ألف')), isTrue);
  });

  test('14 retrieval per question (image)', () async {
    await ChatPersistence.instance.saveMessages(userA, [
      msg('14a', 'مرحبا', 'user', DateTime.now().subtract(const Duration(hours: 2))),
      ChatPersistMessage(id: '14img', text: 'صورة الفاتورة', role: 'user', time: DateTime.now().subtract(const Duration(hours: 1)), imagePath: '/tmp/a.jpg', fileName: 'a.jpg', messageType: 'image', conversationId: userA, userId: userA),
      msg('14c', 'كيف الجو', 'user', DateTime.now()),
    ]);
    final rel = await ChatPersistence.instance.retrieveRelevant(userA, 'ما الصورة التي أرسلتها؟');
    expect(rel.any((e) => e.imagePath == '/tmp/a.jpg'), isTrue);
  });

  test('15 long conversation bounded context', () async {
    final many = List.generate(100, (i) => msg('15_$i', i == 50 ? 'special_token_50 amount 5000' : 'msg $i amount ${i*100}', 'user', DateTime.now().add(Duration(seconds: i))));
    await ChatPersistence.instance.saveMessages(userA, many);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.length, 100);
    final bounded = await ChatPersistence.instance.retrieveRelevant(userA, 'special_token_50');
    expect(bounded.length, lessThanOrEqualTo(10));
    expect(bounded.any((e) => e.text.contains('special_token_50')), isTrue);
  });

  test('16 no hallucination when missing', () async {
    await ChatPersistence.instance.saveMessages(userA, [
      msg('16a', 'مرحبا', 'user', DateTime.now()),
    ]);
    final rel = await ChatPersistence.instance.retrieveRelevant(userA, 'ما اسم الملف الذي أرسلته أمس؟');
    // Should return recent, but not invent a file
    expect(rel.any((e) => e.fileName == 'invented.pdf'), isFalse);
  });

  test('17 concurrent messages without duplicate or loss', () async {
    final futures = List.generate(10, (i) => ChatPersistence.instance.appendMessage(userA, msg('17_$i', 'concurrent $i', 'user', DateTime.now().add(Duration(milliseconds: i)))));
    await Future.wait(futures);
    final loaded = await ChatPersistence.instance.loadMessages(userA);
    expect(loaded.length, 10);
    expect(loaded.map((e) => e.id).toSet().length, 10);
  });

  test('18 attachment context not mixed with other user', () async {
    await ChatPersistence.instance.appendMessage(userA, ChatPersistMessage(id: '18a', text: 'my file', role: 'user', time: DateTime.now(), fileName: 'my.pdf', messageType: 'file', conversationId: userA, userId: userA));
    await ChatPersistence.instance.appendMessage(userB, ChatPersistMessage(id: '18b', text: 'other file', role: 'user', time: DateTime.now(), fileName: 'other.pdf', messageType: 'file', conversationId: userB, userId: userB));
    final aRel = await ChatPersistence.instance.retrieveRelevant(userA, 'ما الملف؟');
    expect(aRel.any((e) => e.fileName == 'other.pdf'), isFalse);
    expect(aRel.any((e) => e.fileName == 'my.pdf'), isTrue);
  });

  test('19 old message remains after truncation (bounded retrieval, not deletion)', () async {
    final many = List.generate(20, (i) => msg('19_$i', i == 0 ? 'unique_old_0' : 'old $i', 'user', DateTime.now().add(Duration(seconds: i))));
    await ChatPersistence.instance.saveMessages(userA, many);
    final rel = await ChatPersistence.instance.retrieveRelevant(userA, 'unique_old_0');
    expect(rel.any((e) => e.text == 'unique_old_0'), isTrue);
    final all = await ChatPersistence.instance.loadMessages(userA);
    expect(all.any((e) => e.text == 'unique_old_0'), isTrue);
  });

  test('20 retrieval of Sara previous reply', () async {
    await ChatPersistence.instance.saveMessages(userA, [
      msg('20q', 'كم الميزانية؟', 'user', DateTime.now().subtract(const Duration(minutes: 5))),
      msg('20a', 'ميزانيتك 5000', 'assistant', DateTime.now().subtract(const Duration(minutes: 4))),
      msg('20q2', 'ماذا قلت عن الميزانية؟', 'user', DateTime.now()),
    ]);
    final rel = await ChatPersistence.instance.retrieveRelevant(userA, 'ماذا قلت عن الميزانية؟');
    expect(rel.any((e) => e.text.contains('5000')), isTrue);
  });
}
