// Staying logged in and logging out (AuthGate + SessionService), without
// Firebase: the login is a fake whose state the tests change.
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/screens/auth_gate.dart';
import 'package:wiseplug/services/session_service.dart';

class FakeUser extends Fake implements User {
  @override
  String get uid => 'u1';
}

/// Firebase Auth as the app sees it: the saved login on start, then changes.
class FakeAuth extends Fake implements FirebaseAuth {
  User? user;
  final _changes = StreamController<User?>.broadcast();
  int signOuts = 0;
  FakeAuth({this.user});

  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() async* {
    yield user;
    yield* _changes.stream;
  }

  /// Firebase ends the session (e.g. online again, and the account is gone).
  void endSession() {
    user = null;
    _changes.add(null);
  }

  @override
  Future<void> signOut() async {
    ++signOuts;
    endSession();
  }
}

Future<void> mount(
  WidgetTester tester,
  FakeAuth auth, {
  SessionService? session,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AuthGate(
        auth: auth,
        setUpSession: false,
        child: Scaffold(
          body: Column(
            children: [
              const Text('Home'),
              if (session != null)
                TextButton(
                  onPressed: session.signOut,
                  child: const Text('Log out'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SessionService service(
  FakeAuth auth,
  List<String> calls, {
  String? token = 'tok',
  bool offline = false,
}) => SessionService(
  auth: auth,
  stepLimit: const Duration(milliseconds: 50),
  pushToken: () async => token,
  forgetToken: [
    (uid, t) async {
      calls.add('firebase forgets $uid $t');
      if (offline) await Completer<void>().future; // never answers
    },
    (uid, t) async {
      calls.add('supabase forgets $uid $t');
      if (offline) throw Exception('no internet');
    },
  ],
  deleteDeviceToken: () async => calls.add('phone deletes token'),
);

void main() {
  testWidgets('reopening the app with a saved login goes straight to Home', (
    tester,
  ) async {
    await mount(tester, FakeAuth(user: FakeUser()));
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(SignInScreen), findsNothing);
  });

  testWidgets('without a saved login the app shows Sign in', (tester) async {
    await mount(tester, FakeAuth());
    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.text('Home'), findsNothing);
  });

  testWidgets(
    'logging out removes this phone from the alerts, then shows Sign in',
    (tester) async {
      final auth = FakeAuth(user: FakeUser()), calls = <String>[];
      await mount(tester, auth, session: service(auth, calls));
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(calls, [
        'firebase forgets u1 tok',
        'supabase forgets u1 tok',
        'phone deletes token',
      ]);
      expect(auth.signOuts, 1);
      expect(find.byType(SignInScreen), findsOneWidget);
    },
  );

  testWidgets(
    'logging out without internet still logs out, without waiting long',
    (tester) async {
      final auth = FakeAuth(user: FakeUser()), calls = <String>[];
      await mount(tester, auth, session: service(auth, calls, offline: true));
      await tester.tap(find.text('Log out'));
      await tester.pump(
        const Duration(milliseconds: 60),
      ); // the first server never answers
      await tester.pumpAndSettle();
      expect(calls.last, 'phone deletes token');
      expect(auth.signOuts, 1);
      expect(find.byType(SignInScreen), findsOneWidget);
    },
  );

  testWidgets(
    'no notification token (web, desktop): logging out just logs out',
    (tester) async {
      final auth = FakeAuth(user: FakeUser()), calls = <String>[];
      await mount(tester, auth, session: service(auth, calls, token: null));
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(calls, ['phone deletes token']);
      expect(find.byType(SignInScreen), findsOneWidget);
    },
  );

  testWidgets(
    'an expired token while offline keeps Home; Sign in only once Firebase ends the session',
    (tester) async {
      final auth = FakeAuth(user: FakeUser());
      await mount(tester, auth);
      // Hours offline: the token expires, but Firebase keeps the login.
      await tester.pump(const Duration(hours: 2));
      expect(find.text('Home'), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      // Online again, and the account is no longer valid: Firebase signs out.
      auth.endSession();
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
    },
  );
}
