// The Appliances page's safe time follows the 7-use learning (it showed the
// type's 4 h ceiling forever), and an outlet card keeps a running appliance
// on screen when one meter answer is missed (it showed "Not measuring").
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/models/recognition.dart';

RegisteredAppliance fan({bool learned = false, int? usualS, int ownMins = 10080}) =>
    RegisteredAppliance.fromRow({
      'id': 'fan-1',
      'name': 'Fan',
      'max_runtime_mins': ownMins,
      'is_learned': learned,
      'use_count': learned ? 7 : 3,
      'baseline_runtime_s': usualS,
      'appliance_types': {'name': 'Fan', 'icon_key': 'fan'},
    }, modes: const []);

OutletReading outlet(String state, {required bool valid, num power = 0}) =>
    OutletReading.fromMap('A', {
      'currentState': state,
      'status': state == 'IDLE' ? 'Idle' : 'Active',
      'sensor_valid': valid,
      'power_W': power,
      'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
    });

void main() {
  group('safe time (same rule as confirmedCutoffS on the server)', () {
    const s = RecognitionSettings(); // 30 min default, x1.2, at least 5 min

    test('while learning: the 30-minute default, not the 4 h ceiling', () {
      expect(fan().safeTimeSeconds(s), 30 * 60);
    });

    test('after 7 uses: usual time x 1.2', () {
      // Usually on 45 min -> 54 min, not "4h".
      expect(fan(learned: true, usualS: 45 * 60).safeTimeSeconds(s), 54 * 60);
    });

    test('learned: at least 5 min, and no 4 h ceiling', () {
      expect(fan(learned: true, usualS: 60).safeTimeSeconds(s), 5 * 60);
      // Usually on 5 h -> 6 h (it used to stop at 4 h).
      expect(fan(learned: true, usualS: 5 * 3600).safeTimeSeconds(s), 6 * 3600);
    });

    test('a kettle (15 min cap) gets 15 min while learning, not 30', () {
      expect(fan(ownMins: 15).safeTimeSeconds(s), 15 * 60);
    });

    test('a heating cap still holds (rice cooker: 90 min)', () {
      expect(
        fan(learned: true, usualS: 2 * 3600, ownMins: 90).safeTimeSeconds(s),
        90 * 60,
      );
    });

    test('reads learned_margin and min_learned_cutoff_minutes', () {
      final row = RecognitionSettings.fromRow({
        'learned_margin': '1.50', // numeric may arrive as a string
        'min_learned_cutoff_minutes': 10,
      });
      expect(row.learnedMargin, 1.5);
      expect(fan(learned: true, usualS: 20 * 60).safeTimeSeconds(row), 30 * 60);
      expect(fan(learned: true, usualS: 60).safeTimeSeconds(row), 10 * 60);
    });
  });

  group('outlet card state', () {
    test('a run stays a run when one meter answer is missed', () {
      final r = outlet('ACTIVE', valid: false);
      expect(r.hasConnectedAppliance(DateTime.now()), isTrue);
      expect(r.livePower, isNull); // "—", not a made-up 0 W
    });

    test('live power while the meter answers', () {
      final r = outlet('ACTIVE', valid: true, power: 18.4);
      expect(r.hasConnectedAppliance(DateTime.now()), isTrue);
      expect(r.livePower, 18.4);
    });

    test('nothing plugged in is not a run', () {
      expect(
        outlet('IDLE', valid: true).hasConnectedAppliance(DateTime.now()),
        isFalse,
      );
    });
  });
}
