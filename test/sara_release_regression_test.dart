import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/subscription/presentation/pages/plans_page.dart';

void main() {
  test('specific packages filter paid cards; invalid filters show all', () {
    for (final filter in ['personal', 'business', 'premium', 'invalid', null]) {
      final page = PlansPage(packageFilter: filter);
      final keys = ['personal', 'business', 'premium'].where(page.includesPackage).toList();
      expect(keys, filter == null || filter == 'invalid' ? ['personal', 'business', 'premium'] : [filter]);
    }
  });

  test('voice preview has only audio controls and no note editor', () {
    final source = File('lib/shared/widgets/sara_chat_page.dart').readAsStringSync();
    final preview = source.split('Widget _buildAudioPreviewInput()').last.split('Widget _buildStaticWaveform').first;
    expect(preview, isNot(contains('TextField')));
    expect(preview, isNot(contains('اكتب ملاحظة')));
    for (final control in ['_sendPendingAudio', '_playPreviewAudio', '_cancelPendingAudio', 'Icons.stop_rounded']) {
      expect(preview, contains(control));
    }
  });

  test('Sara confirmation keeps dialog, scope and signed token without sensitive auth', () {
    final source = File('lib/shared/widgets/sara_chat_page.dart').readAsStringSync();
    final confirm = source.split('final approved = await showDialog<bool>').last.split('final envelope = result.data').first;
    expect(confirm, contains('approved != true'));
    expect(confirm, contains('BranchScope.token != scope || BranchScope.readOnly'));
    expect(confirm, contains("network.post('/business-sara/execute', data: {'token': params['token']})"));
    for (final forbidden in ['verifySensitiveAction', 'biometric', 'localAuthProvider', 'app_pin_sheet']) {
      expect(source, isNot(contains(forbidden)));
    }
  });

  test('header spans AppBar and has no independent leading or mute', () {
    final source = File('lib/shared/widgets/sara_chat_page.dart').readAsStringSync();
    final header = source.split('PreferredSizeWidget _buildAppBar()').last.split('Widget _buildPreviewBar()').first;
    expect(header, contains('automaticallyImplyLeading: false'));
    expect(header, contains('titleSpacing: 0'));
    expect(header, contains('onBack:'));
    expect(header, contains('actions: const []'));
  });
}
