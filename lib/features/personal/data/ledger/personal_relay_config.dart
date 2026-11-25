import '../../../../core/config/directory_pilot_build.dart';

/// The one switch for the Personal device relay (Stage 3).
///
/// On: every Personal ledger commit also records one relay operation, and
/// the runtime carries them between the user's devices. The old server sync
/// keeps running in parallel until the Stage 6 cutover.
///
/// Default: on for QA builds (`FYONA_DIRECTORY_PILOT=true`), off otherwise;
/// `--dart-define=FYONA_PERSONAL_RELAY=true|false` overrides it.
abstract final class PersonalRelayConfig {
  static const build = bool.fromEnvironment(
    'FYONA_PERSONAL_RELAY',
    defaultValue: DirectoryPilotBuild.enabled,
  );

  /// Mutable only so tests can turn capture on/off.
  static bool enabled = build;
}
