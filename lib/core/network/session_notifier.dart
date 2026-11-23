typedef SessionExpiredCallback = void Function();

class SessionNotifier {
  static SessionExpiredCallback? onExpired;
}