import 'package:flutter/material.dart';

/// Every appliance icon in the app is defined here, and only here.
///
/// The icons are Google's Material Icons as built into Flutter (Apache
/// License 2.0, see CREDITS.md): one consistent set, outline style, no brand
/// logos. Each standard appliance type has a [key], stored per type in the
/// database (appliance_types.icon_key), so all "Electric fan" appliances share
/// the fan icon. Where the set has no exact icon, the closest clear one is
/// used (marked "closest" below).
class ApplianceKind {
  /// Stored in appliance_types.icon_key.
  final String key;

  /// What the user sees and picks ("What are you adding?").
  final String label;
  final IconData icon;

  /// Words in a type or appliance name that point to this kind.
  final List<String> words;
  const ApplianceKind(this.key, this.label, this.icon, this.words);
}

/// The standard types, in the order of the "What are you adding?" grid.
/// Matching (kindForType) tries them in this order, so the more specific
/// words come first ("air fryer" before "air", "hair dryer" before "dryer").
const applianceKinds = <ApplianceKind>[
  ApplianceKind('fan', 'Electric fan', Icons.air, ['fan']), // closest: wind
  ApplianceKind('rice_cooker', 'Rice cooker', Icons.rice_bowl, ['rice']),
  ApplianceKind('flat_iron', 'Flat iron', Icons.iron, ['iron', 'straightener']),
  ApplianceKind('air_fryer', 'Air fryer', Icons.outdoor_grill, [
    'fryer',
  ]), // closest
  ApplianceKind('microwave', 'Microwave', Icons.microwave, ['microwave']),
  ApplianceKind('kettle', 'Electric kettle', Icons.coffee_maker, [
    'kettle',
  ]), // closest
  ApplianceKind('tv', 'TV', Icons.tv, ['tv', 'television']),
  ApplianceKind('refrigerator', 'Refrigerator', Icons.kitchen, [
    'fridge',
    'refrigerator',
  ]),
  ApplianceKind('laptop_charger', 'Laptop charger', Icons.laptop, [
    'laptop',
    'computer',
  ]),
  ApplianceKind('phone_charger', 'Phone charger', Icons.charging_station, [
    'phone',
    'charger',
  ]),
  ApplianceKind('lamp', 'Lamp / LED bulb', Icons.lightbulb_outline, [
    'lamp',
    'bulb',
    'light',
  ]),
  ApplianceKind('water_dispenser', 'Water dispenser', Icons.water_drop, [
    'dispenser',
  ]), // closest
  ApplianceKind('hair_dryer', 'Hair dryer', Icons.dry, [
    'hair',
    'dryer',
  ]), // closest
  ApplianceKind('blender', 'Blender', Icons.blender, ['blender']),
  ApplianceKind('induction_cooker', 'Induction cooker', Icons.countertops, [
    'induction',
    'stove',
  ]), // closest
  ApplianceKind(
    'washing_machine',
    'Washing machine',
    Icons.local_laundry_service,
    ['washing', 'washer', 'laundry'],
  ),
  ApplianceKind('aircon', 'Aircon', Icons.ac_unit, [
    'aircon',
    'air con',
    'air-con',
    'conditioner',
  ]),
];

/// What WisePlug's hardware can carry (socket 10 A 250 V, SSR-40DA on a
/// heatsink): 8 A for a load that stays on, 80 % of 10 A. The plug enforces
/// it (CONTINUOUS_CURRENT_A in the firmware); the app says it in words.
const maxApplianceWatts = 1760;

/// [maxApplianceWatts] as people read it: "1,760 W".
final maxApplianceText = '${wattsText(maxApplianceWatts)} W';

/// The usual power of each type, lowest to highest setting (W), from the
/// owner's appliance list (the chargers: typical adapter ratings). Unverified
/// estimates, shown as a guide on the "What are you adding?" tiles; the label
/// and WisePlug's own measurement decide. Only types listed here, and within
/// [maxApplianceWatts], can be picked (see [canAdd]).
const applianceWatts = <String, (int, int)>{
  'fan': (30, 100),
  'rice_cooker': (30, 700), // keep warm 30-50 W, cooking up to 700 W
  'flat_iron': (400, 1500),
  'microwave': (400, 1500),
  'kettle': (1200, 3000),
  'tv': (50, 150),
  'phone_charger': (5, 30),
  'laptop_charger': (30, 100),
  'refrigerator': (100, 400),
  'hair_dryer': (500, 3000),
  'induction_cooker': (300, 3000),
  'washing_machine': (300, 2200), // up to 2,200 W with its water heater
  'aircon': (800, 2000),
};

/// "30–100 W", "1,200–3,000 W".
String wattsText(int w) =>
    w < 1000 ? '$w' : '${w ~/ 1000},${(w % 1000).toString().padLeft(3, '0')}';
String? wattRangeText(String key) {
  final r = applianceWatts[key];
  return r == null ? null : '${wattsText(r.$1)}–${wattsText(r.$2)} W';
}

/// A standard type the user can pick in "What are you adding?": it has a
/// listed range, within what WisePlug can carry. Anything else goes under
/// "Other" (and is still refused if measured above the limit).
bool canAdd(ApplianceKind kind) {
  final range = applianceWatts[kind.key];
  return range != null && range.$2 <= maxApplianceWatts;
}

/// Kinds WisePlug cannot power: their range goes above [maxApplianceWatts]
/// (aircon, hair dryer, induction cooker, washing machine, electric kettle).
/// They keep their icon (for names like "Aircon") but cannot be added; an
/// appliance measured above the limit is refused too (register-sample).
final unsupportedKinds = {
  for (final MapEntry(:key, value: (_, max)) in applianceWatts.entries)
    if (max > maxApplianceWatts) key,
};

/// Any other appliance: a general electrical icon.
const otherKind = ApplianceKind(
  'other',
  'Other',
  Icons.electrical_services,
  [],
);

/// A load WisePlug has not recognised (yet): a question mark, so it never
/// looks like a known appliance.
const unknownKind = ApplianceKind(
  'unknown',
  'Unknown appliance',
  Icons.question_mark,
  [],
);

/// The kind stored as [key] (appliance_types.icon_key); "Other" if unknown.
ApplianceKind kindOfKey(String? key) {
  if (key == unknownKind.key) return unknownKind;
  for (final k in applianceKinds) {
    if (k.key == key) return k;
  }
  return otherKind;
}

/// The kind of an appliance of type [typeName]: its stored [iconKey] if any,
/// else guessed from the words in the type (e.g. "Electric fan" -> fan),
/// else "Other".
ApplianceKind kindForType(String? typeName, {String? iconKey}) {
  if (iconKey != null && iconKey.isNotEmpty) return kindOfKey(iconKey);
  final text = (typeName ?? '').toLowerCase();
  if (text.isEmpty) return otherKind;
  for (final k in applianceKinds) {
    if (k.label.toLowerCase() == text) return k;
  }
  for (final k in applianceKinds) {
    if (k.words.any(text.contains)) return k;
  }
  return otherKind;
}

/// An appliance icon at [size] (24 in lists, 48 on Home and in the grid),
/// in a soft square of [color]. Screen readers read [label] (the appliance's
/// name or type); the name is always shown as text next to it as well.
class ApplianceIcon extends StatelessWidget {
  final ApplianceKind kind;
  final Color color;
  final double size;
  final String? label;
  const ApplianceIcon(
    this.kind, {
    super.key,
    this.color = iconBlue,
    this.size = 24,
    this.label,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(size * .4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(size * .6),
    ),
    child: Icon(
      kind.icon,
      color: color,
      size: size,
      semanticLabel: label ?? kind.label,
    ),
  );
}

/// The icons' default colour: a darker WisePlug blue, about 4.6:1 on white
/// (the brand blue #00A4EF is only about 2.7:1, too faint for an icon).
const iconBlue = Color(0xFF0277BD);
