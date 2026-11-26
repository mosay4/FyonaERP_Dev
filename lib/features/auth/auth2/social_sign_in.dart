import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Public OAuth web client of project `fyonaerp` (not a secret): Google
/// returns an ID token whose `aud` is this client; the backend verifies it.
const String kGoogleWebClientId =
    '1008683392214-2lmo76djt9t5bf77g3cunlc3ja8pfjik.apps.googleusercontent.com';

class SocialCredential {
  final String provider; // google | apple
  final String idToken;
  final String? authorizationCode;
  final String? rawNonce;
  final String? fullName;

  const SocialCredential({
    required this.provider,
    required this.idToken,
    this.authorizationCode,
    this.rawNonce,
    this.fullName,
  });
}

class SocialSignInCancelled implements Exception {
  const SocialSignInCancelled();
}

class SocialSignInFailed implements Exception {
  final String code;
  const SocialSignInFailed(this.code);
  @override
  String toString() => 'SocialSignInFailed($code)';
}

/// Google only on Android, Apple only on iOS (owner's spec).
bool get googleSignInAvailable => defaultTargetPlatform == TargetPlatform.android;
bool get appleSignInAvailable => defaultTargetPlatform == TargetPlatform.iOS;

abstract class SocialSignIn {
  Future<SocialCredential> google();
  Future<SocialCredential> apple();
}

class NativeSocialSignIn implements SocialSignIn {
  NativeSocialSignIn({GoogleSignIn? googleSignIn, MethodChannel? appleChannel})
      : _google = googleSignIn ??
            GoogleSignIn(
              serverClientId: kGoogleWebClientId,
              scopes: const ['email', 'profile'],
            ),
        _apple = appleChannel ?? const MethodChannel('com.fyona.erp/apple_sign_in');

  final GoogleSignIn _google;
  final MethodChannel _apple;

  @override
  Future<SocialCredential> google() async {
    GoogleSignInAccount? account;
    try {
      // Always offer the account chooser (a previous account is not reused
      // silently on a shared phone).
      try {
        await _google.signOut();
      } catch (_) {}
      account = await _google.signIn();
    } on PlatformException catch (e) {
      if (e.code == GoogleSignIn.kSignInCanceledError) {
        throw const SocialSignInCancelled();
      }
      throw SocialSignInFailed(e.code);
    }
    if (account == null) throw const SocialSignInCancelled();
    final auth = await account.authentication;
    final token = auth.idToken;
    if (token == null || token.isEmpty) throw const SocialSignInFailed('no_id_token');
    return SocialCredential(
      provider: 'google',
      idToken: token,
      fullName: account.displayName,
    );
  }

  static String randomNonce([int length = 32]) {
    final rnd = Random.secure();
    final bytes = List<int>.generate(length, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  @override
  Future<SocialCredential> apple() async {
    final raw = randomNonce();
    Map<dynamic, dynamic>? res;
    try {
      res = await _apple.invokeMethod<Map<dynamic, dynamic>>('signIn', {'nonce': raw});
    } on PlatformException catch (e) {
      if (e.code == 'canceled') throw const SocialSignInCancelled();
      throw SocialSignInFailed(e.code);
    }
    final token = res?['identity_token']?.toString() ?? '';
    if (token.isEmpty) throw const SocialSignInFailed('no_identity_token');
    final name = [
      res?['given_name']?.toString() ?? '',
      res?['family_name']?.toString() ?? '',
    ].where((s) => s.trim().isNotEmpty).join(' ').trim();
    return SocialCredential(
      provider: 'apple',
      idToken: token,
      authorizationCode: res?['authorization_code']?.toString(),
      rawNonce: raw,
      // Apple sends the name only on the very first authorization.
      fullName: name.isEmpty ? null : name,
    );
  }
}

final socialSignInProvider = Provider<SocialSignIn>((ref) => NativeSocialSignIn());
