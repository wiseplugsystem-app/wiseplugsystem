import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'esp32_service.dart';
import 'supabase_backend.dart';

/// Logging out. The login itself is Firebase Auth: it stays saved on the
/// phone and is refreshed by Firebase (Supabase uses the same Firebase token),
/// so staying logged in needs nothing here.
///
/// Before the session ends, this phone stops receiving the account's safety
/// alerts: its notification token is removed from Firebase
/// (`users/<uid>/fcmTokens`) and Supabase (`push_tokens`), then deleted on the
/// phone. Each step is best effort with a short time limit, so logging out
/// without internet still works at once; a token left on a server stops
/// working once deleted on the phone, and evaluate-safety-alert then removes it.
class SessionService {
  final FirebaseAuth auth;

  /// This phone's notification token (null where there are none: web, desktop).
  final Future<String?> Function() pushToken;

  /// Removes [token] of [uid] from one server.
  final List<Future<void> Function(String uid, String token)> forgetToken;

  /// Deletes the token on the phone.
  final Future<void> Function() deleteDeviceToken;

  final Duration stepLimit;

  SessionService({
    required this.auth,
    required this.pushToken,
    required this.forgetToken,
    required this.deleteDeviceToken,
    this.stepLimit = const Duration(seconds: 5),
  });

  /// The app's sign-out: Firebase and Supabase on a phone; just the login
  /// elsewhere.
  factory SessionService.standard({FirebaseAuth? auth}) {
    final firebaseAuth = auth ?? FirebaseAuth.instance;
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return SessionService(
      auth: firebaseAuth,
      pushToken: () async => mobile
          // The registration token, as in auth_gate.dart (the senders need it).
          // ignore: deprecated_member_use
          ? await FirebaseMessaging.instance.getToken()
          : null,
      forgetToken: [
        (uid, token) =>
            Esp32Service().database.ref('users/$uid/fcmTokens/$token').remove(),
        if (SupabaseBackend.configured)
          (uid, token) => SupabaseBackend().removePushToken(token),
      ],
      deleteDeviceToken: () async {
        // The registration token (see above), so its deprecated delete.
        // ignore: deprecated_member_use
        if (mobile) await FirebaseMessaging.instance.deleteToken();
      },
    );
  }

  /// Logs out; the auth gate then shows Sign in.
  Future<void> signOut() async {
    final uid = auth.currentUser?.uid;
    final token = await _step('read the notification token', pushToken);
    if (uid != null && token != null) {
      for (final forget in forgetToken) {
        await _step('remove the notification token', () => forget(uid, token));
      }
    }
    await _step('delete the notification token', deleteDeviceToken);
    await auth.signOut();
  }

  Future<T?> _step<T>(String what, Future<T> Function() run) async {
    try {
      return await run().timeout(stepLimit);
    } catch (error) {
      debugPrint('Sign-out: could not $what: $error'); // for developers
      return null;
    }
  }
}
