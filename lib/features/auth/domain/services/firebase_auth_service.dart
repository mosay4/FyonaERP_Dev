import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class FirebaseUserResult {
  final String uid;
  final String email;
  final String? displayName;
  final String? photoUrl;
  final String idToken;
  final String? googleIdToken;
  final String provider;
  final bool isEmailVerified;

  const FirebaseUserResult({
    required this.uid,
    required this.email,
    this.displayName,
    this.photoUrl,
    required this.idToken,
    this.googleIdToken,
    required this.provider,
    required this.isEmailVerified,
  });
}

class FirebaseAuthService {
  fb.FirebaseAuth? _auth;
  final GoogleSignIn _googleSignIn;

  FirebaseAuthService({
    fb.FirebaseAuth? auth,
    GoogleSignIn? googleSignIn,
    String? serverClientId,
  })  : _auth = auth ?? _tryGetAuth(),
        _googleSignIn =
            googleSignIn ??
            GoogleSignIn(serverClientId: serverClientId ?? firebaseWebClientId);

  static fb.FirebaseAuth? _tryGetAuth() {
    try {
      return fb.FirebaseAuth.instance;
    } catch (_) {
      // Firebase not initialized yet (offline startup) - will be retried on use.
      return null;
    }
  }

  fb.FirebaseAuth get _authOrThrow {
    final a = _auth;
    if (a != null) return a;
    // Lazy retry: maybe Firebase finished initializing in background.
    final retried = _tryGetAuth();
    if (retried != null) {
      _auth = retried;
      return retried;
    }
    throw fb.FirebaseAuthException(
      code: 'network-request-failed',
      message: AppLocalizations.t('fbErrNetwork'),
    );
  }

  static const String firebaseWebClientId =
      '1008683392214-2lmo76djt9t5bf77g3cunlc3ja8pfjik.apps.googleusercontent.com';

  Future<FirebaseUserResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final credential = await _authOrThrow.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await credential.user?.reload();
    return _buildResult(credential.user, provider: 'password');
  }

  Future<FirebaseUserResult> registerWithEmailPassword({
    required String fullName,
    required String email,
    required String password,
  }) async {
    final credential = await _authOrThrow.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = credential.user;
    if (user != null) {
      if (fullName.trim().isNotEmpty) {
        await user.updateDisplayName(fullName.trim());
      }
      await user.reload();
      await user.sendEmailVerification();
    }
    return _buildResult(user, provider: 'password');
  }

  Future<void> resendVerificationEmail() async {
    final user = _authOrThrow.currentUser;
    if (user == null) {
      throw fb.FirebaseAuthException(
        code: 'no-current-user',
        message: AppLocalizations.t('fbErrNoUser'),
      );
    }
    await user.sendEmailVerification();
  }

  Future<FirebaseUserResult> signInWithGoogle() async {
    final googleUser = await _authenticateGoogleAccount();
    final idToken = (await googleUser.authentication).idToken;
    if (idToken == null || idToken.isEmpty) {
      throw fb.FirebaseAuthException(
        code: 'missing-id-token',
        message: AppLocalizations.t('fbErrNoToken'),
      );
    }
    final credential = fb.GoogleAuthProvider.credential(idToken: idToken);
    final userCredential = await _authOrThrow.signInWithCredential(credential);
    return _buildResult(userCredential.user, provider: 'google.com', googleIdToken: idToken);
  }

  /// Runs the interactive Google sign-in flow, returning the selected account.
  ///
  /// Uses the classic `GoogleSignInClient` flow (google_sign_in 6.x), which
  /// shows the native Google account picker and obtains an ID token via
  /// AccountManager. This bypasses the Credential Manager one-tap flow, whose
  /// Google provider times out on some devices (e.g. the Realme RMX3710) and
  /// surfaces as a spurious "operation cancelled" even after an account is
  /// selected.
  Future<GoogleSignInAccount> _authenticateGoogleAccount() async {
    debugPrint('[GoogleSignIn] starting signIn()');
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        debugPrint('[GoogleSignIn] signIn() returned null (cancelled)');
        throw fb.FirebaseAuthException(
          code: 'cancelled',
          message: AppLocalizations.t('fbErrCancelled'),
        );
      }
      debugPrint('[GoogleSignIn] signIn() OK: ${account.email}');
      return account;
    } on PlatformException catch (e) {
      debugPrint(
        '[GoogleSignIn] signIn() FAILED: code=${e.code} msg=${e.message}',
      );
      if (e.code == GoogleSignIn.kSignInCanceledError) {
        throw fb.FirebaseAuthException(
          code: 'cancelled',
          message: AppLocalizations.t('fbErrCancelled'),
        );
      }
      if (e.code == GoogleSignIn.kSignInFailedError) {
        // Route to the API only when it IS that concrete code — all other
        // PlatformException codes (e.g. DEVELOPER_ERROR from Play misconfig)
        // carry a descriptive message we surface verbatim so "تعذر المصادقة"
        // never masks the real cause.
        final msg = e.message?.trim() ?? '';
        throw fb.FirebaseAuthException(
          code: 'sign-in-failed',
          message: msg.isNotEmpty ? msg : AppLocalizations.t('fbErrAuth'),
        );
      }
      // Any other PlatformException (e.g. 10 DEVELOPER_ERROR, 7 NETWORK_ERROR)
      // surfaces verbatim — never collapses to a vague "cancelled".
      final raw = e.message?.trim() ?? '';
      throw fb.FirebaseAuthException(
        code: e.code,
        message: raw.isNotEmpty ? raw : e.toString(),
      );
      rethrow;
    }
  }

  /// Sends a password reset email through Firebase Auth (link-based).
  Future<void> sendPasswordResetEmail(String email) async {
    await _authOrThrow.sendPasswordResetEmail(email: email.trim());
  }

  /// Changes the signed-in user's password after re-authenticating with the
  /// current password (required by Firebase for sensitive account changes).
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _authOrThrow.currentUser;
    if (user == null) {
      throw fb.FirebaseAuthException(
        code: 'no-current-user',
        message: AppLocalizations.t('fbErrNoUser'),
      );
    }
    final email = user.email;
    if (email == null || email.isEmpty) {
      throw fb.FirebaseAuthException(
        code: 'no-email',
        message: AppLocalizations.t('fbErrNoEmail'),
      );
    }
    final credential = fb.EmailAuthProvider.credential(
      email: email,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(credential);
    await user.updatePassword(newPassword);
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    try {
      final a = _auth ?? _tryGetAuth();
      if (a != null) await a.signOut();
    } catch (_) {}
  }

  Future<FirebaseUserResult> _buildResult(
    fb.User? user, {
    required String provider,
    String? googleIdToken,
  }) async {
    if (user == null) {
      throw fb.FirebaseAuthException(
        code: 'no-current-user',
        message: AppLocalizations.t('fbErrNoUser'),
      );
    }
    final idToken = (await user.getIdToken(true)) ?? '';
    debugPrint('[Auth] Firebase ID Token obtained successfully');
    return FirebaseUserResult(
      uid: user.uid,
      email: user.email ?? '',
      displayName: user.displayName,
      photoUrl: user.photoURL,
      idToken: idToken,
      googleIdToken: googleIdToken,
      provider: provider,
      isEmailVerified: user.emailVerified,
    );
  }
}

String firebaseErrorMessage(Object error) {
  if (error is fb.FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-email':
        return AppLocalizations.t('fbErrInvalidEmail');
      case 'user-disabled':
        return AppLocalizations.t('fbErrDisabled');
      case 'user-not-found':
        return AppLocalizations.t('fbErrNotFound');
      case 'wrong-password':
        return AppLocalizations.t('fbErrWrongPassword');
      case 'invalid-credential':
        return AppLocalizations.t('fbErrBadCredential');
      case 'email-already-in-use':
        return AppLocalizations.t('fbErrInUse');
      case 'weak-password':
        return AppLocalizations.t('fbErrWeakPassword');
      case 'invalid-action-code':
      case 'invalid-oob-code':
        return AppLocalizations.t('fbErrBadResetLink');
      case 'expired-action-code':
        return AppLocalizations.t('fbErrResetExpired');
      case 'too-many-requests':
        return AppLocalizations.t('fbErrTooMany');
      case 'requires-recent-login':
        return AppLocalizations.t('fbErrRecentLogin');
      case 'network-request-failed':
        return AppLocalizations.t('fbErrNetwork');
      case 'operation-not-allowed':
        return AppLocalizations.t('fbErrNotAllowed');
      case 'cancelled':
      case 'popup-closed-by-user':
        return AppLocalizations.t('fbErrCancelled');
      case 'no-current-user':
        return AppLocalizations.t('fbErrNoUser');
      case 'missing-id-token':
        return AppLocalizations.t('fbErrNoToken');
      case 'no-email':
        return AppLocalizations.t('fbErrNoEmail');
      default:
        return error.message ?? AppLocalizations.t('fbErrAuth');
    }
  }
  return error.toString();
}
