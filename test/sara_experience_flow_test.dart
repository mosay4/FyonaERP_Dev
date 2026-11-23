import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/shared/widgets/sara_chat_page.dart').readAsStringSync();

  test('audio preview has no note field and preserves send, play, stop and cancel', () {
    final preview = source.split('Widget _buildAudioPreviewInput() {')[1]
        .split('Widget _buildStaticWaveform')[0];
    expect(preview, isNot(contains('اكتب ملاحظة')));
    expect(preview, isNot(contains('TextField')));
    expect(preview, isNot(contains('_inputCtrl')));
    for (final control in ['_sendPendingAudio', '_playPreviewAudio',
      'Icons.stop_rounded', 'Icons.play_arrow_rounded', 'Icons.send_rounded', '_cancelPendingAudio']) {
      expect(preview, contains(control));
    }
  });

  test('business confirm uses signed token without biometric and retains scope guards', () {
    final confirm = source.split('Future<void> _sendBusiness(')[1]
        .split('Future<void> _send({')[0];
    expect(confirm, contains('showDialog<bool>'));
    expect(confirm, contains('approved != true'));
    expect(confirm, contains('BranchScope.token != scope || BranchScope.readOnly'));
    expect(confirm, contains("network.post('/business-sara/execute', data: {'token': params['token']})"));
    expect(confirm.toLowerCase(), isNot(contains('biometric')));
    expect(confirm, isNot(contains('.verify(')));
    expect(confirm, isNot(contains('.authenticate(')));
  });
}
