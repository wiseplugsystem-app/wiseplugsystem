import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/services/esp32_service.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';

void main() {
  test(
    'metadata permission errors preserve catalog and recovery restores names',
    () async {
      final catalog = StreamController<Object?>();
      final metadata = StreamController<Object?>();
      final values = <List<LearnedAppliance>>[];
      final errors = <Object>[];
      final subscription = combineProfileStreams(
        catalog.stream,
        metadata.stream,
      ).listen(values.add, onError: errors.add);
      catalog.add({
        'OUTLET_A': {
          'sig': {'name': 'UNNAMED_DEVICE_1', 'steadyPower_W': 42},
        },
      });
      metadata.addError(StateError('permission-denied'));
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);
      expect(values.single.single.name, 'UNNAMED_DEVICE_1');
      expect(values.single.single.registrationMetadataAvailable, false);
      metadata.add({
        'OUTLET_A': {
          'sig': {'name': 'Bedroom Fan', 'applianceType': 'Electric fan'},
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(values.last.single.name, 'Bedroom Fan');
      expect(values.last.single.registrationMetadataAvailable, true);
      expect(values.last.single.baselineWattage, 42);
      expect(values.last.single.needsRegistration, false);
      expect(
        connectedProfile(
          OutletReading.fromMap('A', {'appliance': 'UNNAMED_DEVICE_1'}),
          values.last,
        )?.name,
        'Bedroom Fan',
      );
      catalog.addError(StateError('catalog denied'));
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      final count = values.length;
      metadata.add({});
      await Future<void>.delayed(Duration.zero);
      expect(values, hasLength(count));
      await subscription.cancel();
      await catalog.close();
      await metadata.close();
    },
  );
}
