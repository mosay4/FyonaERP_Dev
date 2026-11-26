typedef SessionExpiredCallback = void Function();

class SessionNotifier {
  static SessionExpiredCallback? onExpired;

  /// The server revoked this device (auth2 `device_revoked`): sign out
  /// cleanly to the login page (no re-entry gate).
  static SessionExpiredCallback? onDeviceRevoked;
}
