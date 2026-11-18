// The appliance icon mapping (lib/models/appliance_icons.dart): every type
// has an icon, the fallbacks are right, and the database migration that fills
// appliance_types.icon_key uses the same keys and words.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/appliance_icons.dart';

void main() {
  test('every standard type has its own key, label and icon', () {
    final keys = applianceKinds.map((k) => k.key).toSet();
    final labels = applianceKinds.map((k) => k.label.toLowerCase()).toSet();
    expect(keys.length, applianceKinds.length);
    expect(labels.length, applianceKinds.length);
    expect(keys, isNot(contains(otherKind.key)));
    expect(keys, isNot(contains(unknownKind.key)));
    for (final k in applianceKinds) {
      expect(RegExp(r'^[a-z_]{1,32}$').hasMatch(k.key), isTrue, reason: k.key);
      expect(kindOfKey(k.key), same(k));
      expect(kindForType(k.label), same(k), reason: k.label);
    }
    // The 17 types asked for.
    expect(keys, {
      'fan', 'rice_cooker', 'flat_iron', 'air_fryer', 'microwave', 'kettle', //
      'tv', 'refrigerator', 'phone_charger', 'laptop_charger', 'lamp',
      'water_dispenser', 'hair_dryer', 'blender', 'induction_cooker',
      'washing_machine', 'aircon',
    });
  });

  test('types written by people find their icon from the words in them', () {
    expect(kindForType('Electric fan').key, 'fan');
    expect(kindForType('Black Fan').key, 'fan');
    expect(kindForType('Air fryer').key, 'air_fryer'); // not aircon
    expect(kindForType('Hair dryer').key, 'hair_dryer');
    expect(kindForType('Laptop charger').key, 'laptop_charger');
    expect(kindForType('Phone charger').key, 'phone_charger');
    expect(kindForType('Window aircon').key, 'aircon');
    expect(kindForType('LED bulb').key, 'lamp');
  });

  test('"Other" and unknown loads get their own fallback icons', () {
    expect(kindForType('Electric grill'), same(otherKind));
    expect(kindForType(''), same(otherKind));
    expect(kindForType(null), same(otherKind));
    expect(kindOfKey('no_such_icon'), same(otherKind));
    expect(kindOfKey('unknown'), same(unknownKind));
    expect(otherKind.icon, Icons.electrical_services);
    expect(unknownKind.icon, Icons.question_mark);
    // A stored key wins over the words in the name.
    expect(kindForType('Electric fan', iconKey: 'tv').key, 'tv');
  });

  test('the migration fills icon_key with the same keys, so every type in the '
      'database gets a valid icon', () {
    final sql = File('supabase/migrations/20261104000000_appliance_icons.sql')
        .readAsStringSync();
    final keys = RegExp(r"then '([a-z_]+)'")
        .allMatches(sql)
        .map((m) => m.group(1)!)
        .toList();
    expect(keys, applianceKinds.map((k) => k.key).toList());
    expect(sql, contains("else 'other'"));
    for (final k in applianceKinds) {
      for (final w in k.words) {
        expect(sql, contains("like '%$w%'"), reason: '${k.key}: $w');
      }
    }
  });

  testWidgets('the icon has a screen-reader label and the asked-for size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              ApplianceIcon(kindOfKey('fan'), size: 48, label: 'Bedroom fan'),
            ],
          ),
        ),
      ),
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.air));
    expect(icon.size, 48);
    expect(icon.semanticLabel, 'Bedroom fan');
    expect(icon.color, iconBlue);
  });

  test('the icon set and its license are credited', () {
    final credits = File('CREDITS.md').readAsStringSync();
    expect(credits, contains('Material Icons'));
    expect(credits, contains('Apache License 2.0'));
  });
}
