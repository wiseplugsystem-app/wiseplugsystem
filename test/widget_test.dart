import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/screens/settings_tab.dart';

void main() {
  test('device fields round trip', () {
    final device = WiseplugDevice(
      deviceID: 'd1',
      userID: 'u1',
      deviceStatus: 'Online',
      currentState: 'On',
      detectAppliance: true,
    );
    expect(
      WiseplugDevice.fromMap(device.toMap(), 'd1').toMap(),
      device.toMap(),
    );
  });
  test('fan names share icon and color', () {
    ApplianceProfile profile(String type) => ApplianceProfile(
      profileID: 'p1',
      deviceID: 'd1',
      applianceName: 'Fan',
      applianceType: type,
      outlet: 'A',
    );
    expect(profile('Electric fan').icon, Icons.air);
    expect(profile('Electric Fan').icon, profile('Electric fan').icon);
    expect(profile('Electric Fan').color, profile('Electric fan').color);
  });
  testWidgets('settings changes dark mode', (tester) async {
    bool? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsTab(
          darkMode: false,
          onDarkModeChanged: (value) => changed = value,
        ),
      ),
    );
    await tester.tap(find.byType(Switch));
    expect(changed, true);
  });
}
