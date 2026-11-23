import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/chat_background_upload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final state in [
    {'failed': true},
    {'attempts': 3},
  ]) {
    test('worker does not send or reschedule terminal job $state', () async {
      final dir = await Directory.systemTemp.createTemp('chat-worker-test-');
      try {
        final job = File('${dir.path}/job.json');
        await job.writeAsString(
          jsonEncode({
            'id': 'job',
            'base_url': 'https://never-contact.invalid',
            ...state,
          }),
        );
        expect(await ChatBackgroundUpload.runJobFile(job.path), true);
        expect(await job.exists(), true); // retained for explicit retry
        expect(
          jsonDecode(await job.readAsString()),
          containsPair(state.keys.first, state.values.first),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  }
  test(
    'completion/cancel tombstone stops queued job before networking',
    () async {
      final dir = await Directory.systemTemp.createTemp('chat-worker-test-');
      try {
        final job = File('${dir.path}/job.json');
        await job.writeAsString('{}');
        await File('${dir.path}/job.done').writeAsString('1');
        expect(await ChatBackgroundUpload.runJobFile(job.path), true);
        expect(await job.exists(), false);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
