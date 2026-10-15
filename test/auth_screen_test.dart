import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/screens/auth_gate.dart';

void main() {
  passwordFeatures();
  testWidgets('new users can create an account and return to sign in', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SignInScreen()));
    await tester.tap(find.text('New to WisePlug? Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a password'), findsOneWidget);
    expect(find.text('Confirm password'), findsOneWidget);
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(0), 'new@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'secret123');
    await tester.enterText(find.byType(TextFormField).at(2), 'different');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    await tester.ensureVisible(find.text('Already have an account? Sign in'));
    await tester.tap(find.text('Already have an account? Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm password'), findsNothing);
    expect(find.text('Passwords do not match.'), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });
}

class ResetAuth extends Fake implements FirebaseAuth {
  final resets = <String>[];
  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    ActionCodeSettings? actionCodeSettings,
  }) async => resets.add(email);
}

void passwordFeatures() {
  testWidgets('forgot password sends a reset email and confirms it', (
    tester,
  ) async {
    final auth = ResetAuth();
    await tester.pumpWidget(MaterialApp(home: SignInScreen(auth: auth)));
    await tester.tap(find.text('Forgot Password?'));
    await tester.pump();
    expect(find.textContaining('Enter your account email'), findsOneWidget);
    expect(auth.resets, isEmpty);
    await tester.enterText(find.byType(TextFormField).at(0), 'me@example.com');
    await tester.tap(find.text('Forgot Password?'));
    await tester.pumpAndSettle();
    expect(auth.resets, ['me@example.com']);
    expect(find.text('Check your email'), findsOneWidget);
  });

  testWidgets('the eye icon shows and hides the password', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SignInScreen()));
    bool obscured() => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byType(TextFormField).at(1),
            matching: find.byType(EditableText),
          ),
        )
        .obscureText;
    expect(obscured(), isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(obscured(), isFalse);
  });
}
