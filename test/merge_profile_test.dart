import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/screens/esp32_dashboard.dart';
import 'package:wiseplug/services/esp32_service.dart';

class MergeDevice extends Fake implements Esp32Service {
  final merges = <String>[];
  final registered = <String>[];
  @override
  Future<void> mergeProfile(
    OutletReading reading,
    LearnedAppliance source,
    LearnedAppliance target,
  ) async => merges.add('${source.profileID}->${target.profileID}');
  @override
  Future<void> registerProfile(LearnedAppliance profile, String name) async =>
      registered.add(name);
}

void main() {
  final fresh = LearnedAppliance.fromMap('B', 'UNNAMED_DEVICE_66W', {
    'steadyPower_W': 66.5,
  });
  final laptop = LearnedAppliance.fromMap('A', 'UNNAMED_DEVICE_145W', {
    'name': 'Charge ni luzie',
    'registered': true,
  });
  final phone = LearnedAppliance.fromMap('A', 'UNNAMED_DEVICE_5W', {
    'name': 'phonecahrger',
    'registered': true,
  });

  Future<MergeDevice> open(
    WidgetTester tester, {
    List<LearnedAppliance> existing = const [],
  }) async {
    final device = MergeDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Esp32ProfileEditor(
            service: device,
            reading: OutletReading.fromMap('B', {}),
            profile: fresh,
            registration: true,
            existing: existing,
          ),
        ),
      ),
    );
    return device;
  }

  testWidgets('a new reading can be merged into a saved appliance', (
    tester,
  ) async {
    final device = await open(tester, existing: [laptop, phone]);
    expect(find.text('Or is it one of your saved appliances?'), findsOneWidget);
    // Nothing chosen yet: the merge button is disabled.
    final button = find.widgetWithText(OutlinedButton, 'Same appliance');
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);

    await tester.tap(find.byType(DropdownButtonFormField<LearnedAppliance>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charge ni luzie').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, it is Charge ni luzie'));
    await tester.pumpAndSettle();

    expect(device.merges, ['UNNAMED_DEVICE_66W->UNNAMED_DEVICE_145W']);
    expect(device.registered, isEmpty, reason: 'merged, not saved as a copy');
  });

  testWidgets('without saved appliances only naming is offered', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Or is it one of your saved appliances?'), findsNothing);
    expect(find.text('Save Profile'), findsOneWidget);
  });
}
