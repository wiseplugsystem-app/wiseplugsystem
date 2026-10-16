import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wiseplug/models/gadget_status.dart';
import 'package:wiseplug/screens/user_profile_screen.dart';
import 'package:wiseplug/services/device_binding.dart';

class FakeUser extends Fake implements User {
  final calls = <String>[];
  @override
  String get uid => 'u1';
  @override
  String? get email => 'owner@example.com';
  @override
  Future<UserCredential> reauthenticateWithCredential(
    AuthCredential credential,
  ) async {
    final password = (credential as EmailAuthCredential).password;
    calls.add('reauth:${credential.email}');
    if (password != 'right') {
      throw FirebaseAuthException(code: 'wrong-password');
    }
    return FakeCredential();
  }

  @override
  Future<void> delete() async => calls.add('delete');
}

class FakeCredential extends Fake implements UserCredential {}

class FakeAuth extends Fake implements FirebaseAuth {
  final user = FakeUser();
  @override
  User? get currentUser => user;
}

void main() {
  test('gadget status parses the devices/gadget-1/status schema', () {
    final now = DateTime.now();
    final status = GadgetStatus.fromMap({
      'outletA': true,
      'outletB': false,
      'powerDraw': 120.5,
      'connectionStatus': 'Online',
      'remainingLimit': 30,
      'safetyTriggered': false,
      'lastSeen': now.millisecondsSinceEpoch,
    });
    expect(status.activeOutlets, 1);
    expect(status.powerDraw, 120.5);
    expect(status.isOnline(now), isTrue);
    expect(status.needsSafetyAlert, isFalse);
    expect(status.isOnline(now.add(const Duration(minutes: 1))), isFalse);
    expect(
      GadgetStatus.fromMap({'remainingLimit': 0}).needsSafetyAlert,
      isTrue,
    );
    expect(
      GadgetStatus.fromMap({'remainingLimit': -2}).needsSafetyAlert,
      isTrue,
    );
    expect(
      GadgetStatus.fromMap({'safetyTriggered': true}).needsSafetyAlert,
      isTrue,
    );
    // No limit published (nothing running) must not raise the alert.
    expect(GadgetStatus.fromMap({}).needsSafetyAlert, isFalse);
  });

  test('device binding is locked to gadget-1', () async {
    SharedPreferences.setMockInitialValues({'boundDeviceId': 'other-device'});
    final prefs = await SharedPreferences.getInstance();
    expect(await DeviceBinding.ensureBound(prefs), 'gadget-1');
    expect(prefs.getString('boundDeviceId'), 'gadget-1');
    expect(DeviceBinding.statusPath, 'devices/gadget-1/status');
    expect(DeviceBinding.wifiConfigPath, 'devices/gadget-1/wifiConfig');
  });

  testWidgets('account deletion requires password re-authentication first', (
    tester,
  ) async {
    final auth = FakeAuth();
    final removed = <String>[];
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<bool>(
              context: context,
              builder: (_) => DeleteAccountDialog(
                auth: auth,
                removeUserData: (uid) async {
                  auth.user.calls.add('removeData:$uid');
                  removed.add(uid);
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
    await tester.pump();
    expect(find.text('Enter your password to confirm.'), findsOneWidget);
    expect(auth.user.calls, isEmpty);

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
    await tester.pumpAndSettle();
    expect(
      find.text('Incorrect password. Your account was not deleted.'),
      findsOneWidget,
    );
    expect(auth.user.calls, ['reauth:owner@example.com']);
    expect(removed, isEmpty);

    await tester.enterText(find.byType(TextField), 'right');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
    await tester.pumpAndSettle();
    expect(auth.user.calls.skip(1), [
      'reauth:owner@example.com',
      'removeData:u1',
      'delete',
    ]);
    expect(result, isTrue);
  });
}
