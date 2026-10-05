import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/services/auth_error.dart';

void main() {
  test('generic Firebase messages retain the diagnostic code', () {
    final message = authErrorMessage(
      FirebaseAuthException(code: 'internal-error', message: 'Error'),
    );
    expect(message, contains('Code: internal-error'));
    expect(message, contains('could not complete'));
  });

  test('disabled registration explains the provider configuration', () {
    final message = authErrorMessage(
      FirebaseAuthException(
        code: 'auth/operation-not-allowed',
        message: 'Error',
      ),
    );
    expect(message, contains('enable Email/Password'));
    expect(message, contains('Code: operation-not-allowed'));
  });

  test('missing authentication configuration has actionable guidance', () {
    expect(
      authErrorMessage(FirebaseAuthException(code: 'configuration-not-found')),
      contains('configure Firebase Authentication'),
    );
  });
}
