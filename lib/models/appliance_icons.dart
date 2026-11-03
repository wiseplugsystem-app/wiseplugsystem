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
