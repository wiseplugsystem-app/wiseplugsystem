import 'package:firebase_auth/firebase_auth.dart';

String authErrorMessage(FirebaseAuthException error) {
  final code = error.code.replaceFirst(RegExp(r'^auth/'), '');
  final explanation = switch (code) {
    'email-already-in-use' =>
      'This email already has an account. Please sign in.',
    'weak-password' => 'Please choose a stronger password.',
    'invalid-email' => 'Enter a valid email address.',
    'invalid-credential' || 'user-not-found' || 'wrong-password' => 'Email or password is incorrect. New to WisePlug? Create an account below.',
    'operation-not-allowed' || 'password-login-disabled' => 'Email/password accounts are disabled for this app. The app administrator must enable Email/Password in Firebase Authentication.',
    'configuration-not-found' => 'Authentication has not been set up for this app. The app administrator must configure Firebase Authentication and enable Email/Password.',
    'invalid-api-key' || 'app-not-authorized' => 'This app cannot access Firebase Authentication. The app administrator must check its Firebase configuration and API key restrictions.',
    'network-request-failed' => 'Check your internet connection and try again.',
    'too-many-requests' => 'Too many attempts. Please wait and try again.',
    'user-disabled' =>
      'This account has been disabled. Contact your administrator.',
    _ => 'Firebase could not complete the request. Please share the error code with the app administrator.',
  };
  return '$explanation (Code: ${code.isEmpty ? 'unknown' : code})';
}
