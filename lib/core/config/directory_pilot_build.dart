/// Build-time fence for the separate Phase 1 app. It can use the USB lab or
/// an explicitly approved HTTPS sandbox, never the production API.
abstract final class DirectoryPilotBuild {
  static const enabled = bool.fromEnvironment('FYONA_DIRECTORY_PILOT');
  static const signupEnabled =
      enabled && bool.fromEnvironment('FYONA_DIRECTORY_PILOT_SIGNUP');
  static const loopbackBase = 'http://127.0.0.1:18083/api/v1';
  static const stagingBase = 'https://qa.fyonacompany.com:18443/api/v1';
  static const accountId = String.fromEnvironment('FYONA_DIRECTORY_ACCOUNT');
  static const organizationId = String.fromEnvironment('FYONA_DIRECTORY_ORG');
  static const branchId = String.fromEnvironment('FYONA_DIRECTORY_BRANCH');
  static const setupUrl = String.fromEnvironment(
    'FYONA_DIRECTORY_SETUP_URL',
    defaultValue: loopbackBase,
  );
  static String get baseUrl => setupUri?.toString() ?? loopbackBase;

  static Uri? get setupUri =>
      const {loopbackBase, stagingBase}.contains(setupUrl)
      ? Uri.parse(setupUrl)
      : null;

  static bool allows(Uri uri) {
    final origin = setupUri ?? Uri.parse(loopbackBase);
    return uri.scheme == origin.scheme &&
        uri.host == origin.host &&
        uri.port == origin.port &&
        uri.userInfo.isEmpty;
  }
}
