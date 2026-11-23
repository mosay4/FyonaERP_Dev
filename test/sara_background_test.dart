import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:fyona_flutter/features/ai/domain/agent/chat_persistence.dart';

/// Sara background continuation: leaving the chat must never stall a task.
///
/// Root cause proven below: WidgetRef dies with dispose (ref.read throws),
/// so the async tail may only use send-time snapshots + static persistence.
/// The round-trip test proves the mechanism the fix relies on: appends made
/// while "away" are all present, in order, when the user returns.

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
  testWidgets('ref.read after dispose throws (capture-before-await required)',
      (tester) async {
    final prov = Provider((ref) => 42);
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Consumer(builder: (c, ref, _) {
          captured = ref;
          return const SizedBox();
        })),
      ),
    );
    expect(captured.read(prov), 42);
    // User leaves the chat -> consumer disposed.
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: SizedBox())));
    var threw = false;
    try {
      captured.read(prov);
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue,
        reason: 'background continuations must capture values before dispose');
  });

  test('background appends (reply + confirmation + error) survive reload in order',
      () async {
    final tmp = await Directory.systemTemp.createTemp('sara_bg');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
    const key = 'u1_personal';
    await ChatPersistence.instance.appendMessage(
        key, ChatPersistMessage(id: 'resp_1', text: 'main reply', role: 'assistant', time: DateTime.now()));
    await ChatPersistence.instance.appendMessage(
        key, ChatPersistMessage(id: 'confirm_1', text: 'confirm?', role: 'assistant', time: DateTime.now()));
    await ChatPersistence.instance.appendMessage(
        key, ChatPersistMessage(id: 'err_1', text: 'failed, retry', role: 'assistant', time: DateTime.now()));
    final loaded = await ChatPersistence.instance.loadMessages(key);
    expect(loaded.map((m) => m.text).toList(),
        ['main reply', 'confirm?', 'failed, retry']);
    await tmp.delete(recursive: true);
  });
}
