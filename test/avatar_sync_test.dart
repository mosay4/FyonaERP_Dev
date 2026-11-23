import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/profile/presentation/providers/avatar_provider.dart'
    show AvatarSyncAction, avatarSyncDecision;

/// Avatar reconcile decisions: the local picture must survive offline, sync
/// across devices when online, and never resurrect after an offline delete.
void main() {
  const urlA = 'uploads/avatars/u1.jpg';
  const urlB = 'uploads/avatars/u1-new.jpg';

  group('avatarSyncDecision', () {
    test('offline unknown server state never touches local', () {
      expect(
          avatarSyncDecision(
              serverRel: null, knownRel: urlA, fresh: false),
          AvatarSyncAction.none);
      expect(
          avatarSyncDecision(serverRel: null, knownRel: null, fresh: false),
          AvatarSyncAction.none);
    });

    test('fresh proof of remote removal clears local', () {
      expect(
          avatarSyncDecision(serverRel: null, knownRel: urlA, fresh: true),
          AvatarSyncAction.clearLocal);
    });

    test('fresh empty with nothing known stays put', () {
      expect(
          avatarSyncDecision(serverRel: null, knownRel: null, fresh: true),
          AvatarSyncAction.none);
    });

    test('matching urls mean in sync', () {
      expect(
          avatarSyncDecision(
              serverRel: urlA, knownRel: urlA, fresh: true),
          AvatarSyncAction.none);
    });

    test('new server picture downloads', () {
      expect(
          avatarSyncDecision(
              serverRel: urlB, knownRel: urlA, fresh: true),
          AvatarSyncAction.download);
      expect(
          avatarSyncDecision(serverRel: urlB, knownRel: null, fresh: true),
          AvatarSyncAction.download);
    });

    test('offline delete tombstone retries instead of resurrecting', () {
      expect(
          avatarSyncDecision(
              serverRel: urlA, knownRel: 'DELETED:$urlA', fresh: true),
          AvatarSyncAction.retryDelete);
    });

    test('newer server picture wins over stale tombstone', () {
      expect(
          avatarSyncDecision(
              serverRel: urlB, knownRel: 'DELETED:$urlA', fresh: true),
          AvatarSyncAction.download);
    });
  });
}
