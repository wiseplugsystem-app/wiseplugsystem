import 'package:flutter/material.dart';

import '../theme.dart';

import '../models/appliance_icons.dart';
import '../models/recognition.dart';

/// "How to use WisePlug": a short, plain instruction manual (Settings).
/// Written for someone who has never used a smart plug: one idea per line,
/// numbered steps, the same words the app shows. Numbers come from
/// [settings] (recognition_config), so the help never disagrees with the app.
class HelpScreen extends StatelessWidget {
  final RecognitionSettings settings;
  const HelpScreen({super.key, this.settings = const RecognitionSettings()});

  @override
  Widget build(BuildContext context) {
    final minutes = settings.defaultCutoffMinutes;
    final uses = settings.learningUses;
    return Scaffold(
      appBar: AppBar(title: const Text('How to use WisePlug')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              'WisePlug turns your appliance off if it is left on too long. '
              'Tap a topic to read it.',
              style: TextStyle(fontSize: 17, color: context.muted),
            ),
            const SizedBox(height: 12),
            _Topic(
              icon: Icons.power,
              title: '1. Getting started',
              initiallyExpanded: true,
              steps: const [
                'Plug the WisePlug into the wall.',
                'Wait about 1 minute.',
                'At the top of Home it should say "Online".',
                'Says "Offline"? Go to Settings → Change Wi-Fi and connect '
                    'it to your home Wi-Fi.',
                'Acting strangely? Turn off your appliances, then go to '
                    'Settings → Restart WisePlug. It is back in about 20 '
                    'seconds.',
              ],
            ),
            _Topic(
              icon: Icons.add_circle_outline,
              title: '2. Adding a new appliance (first time only)',
              steps: [
                'Plug the appliance into Outlet A or Outlet B.',
                'Turn it on with its own switch.',
                'Wait about 20 seconds. A message appears: '
                    '"Something new on Outlet …".',
                'Type a name (for example "Bedroom fan") and tap what it is.',
                'Tap Register, then follow the steps on the screen.',
                'Each step: turn it on, wait about 1 minute without touching '
                    'it, then turn it off.',
                'Fan: do each speed once, in any order. Use a different '
                    'speed each time.',
                if (settings.samplesPerCharger > 1)
                  'Charger: charge ${settings.samplesPerCharger} times — '
                      'battery low, half full, nearly full.'
                else
                  'Charger: just charge a laptop or phone with it once.',
                'Busy? Tap "Finish later". Next time, tap "Continue '
                    'registering" on the appliance\'s page.',
              ],
              note:
                  'Until WisePlug knows the appliance, it turns it off after '
                  '$minutes minutes to keep you safe.',
            ),
            _Topic(
              icon: Icons.play_circle_outline,
              title: '3. Using an appliance every day',
              steps: const [
                'Plug it in and turn it on as usual.',
                'Within about 20 seconds, its name appears on the outlet card.',
                'The card shows how long it has been on and when it will '
                    'turn off.',
                'Turn it off with its own switch when you are done.',
              ],
              note:
                  'WisePlug learns how long you usually use each appliance. '
                  'After $uses uses, it picks a better time for it.',
            ),
            _Topic(
              icon: Icons.toggle_on_outlined,
              title: '4. Turning an outlet on or off from your phone',
              steps: const [
                'Go to Home and scroll to Power Control.',
                'Tap the switch next to the outlet.',
                'Green means on. Grey means off.',
                'The appliance\'s own switch must also be on for it to run.',
              ],
            ),
            _Topic(
              icon: Icons.timer_outlined,
              title: '5. When the safe time is up',
              steps: const [
                'Your phone shows "Safe time is up" and counts down from 60 '
                    'seconds.',
                'Still using it? Tap "Keep it on". You get extra time.',
                'Not using it? Tap "Turn off now".',
                'No answer in 60 seconds? WisePlug turns it off by itself.',
                'To use it again: check the appliance first, tap Reset Safety, '
                    'then Turn on again.',
              ],
            ),
            _Topic(
              icon: Icons.help_outline,
              title: '6. What the outlet cards mean',
              rows: const [
                ('Ready to use', 'Nothing is running. Plug in an appliance.'),
                ('In use', 'An appliance is on and being timed.'),
                ('Finding out what it is', 'Wait about 20 seconds.'),
                (
                  'Turned off',
                  'You turned it off. Use the switch to turn it on.',
                ),
                (
                  'Turned off for safety',
                  'Check the appliance, then tap Reset Safety.',
                ),
                (
                  'Not measuring',
                  'Check that the WisePlug is plugged into the wall.',
                ),
                ('No connection', 'Check the WisePlug and your Wi-Fi.'),
              ],
            ),
            _Topic(
              icon: Icons.devices_other,
              title: '7. Your appliances',
              steps: const [
                'Tap Appliances at the bottom to see them all.',
                'Tap one to see how long until it turns off and how often you '
                    'used it.',
                'Edit: change its name or what it is.',
                'Delete: remove it. Turn it off first.',
                'Two of the same appliance (two identical fans)? WisePlug '
                    'cannot tell them apart, so it asks you which one it is.',
              ],
            ),
            _Topic(
              icon: Icons.shield_outlined,
              title: '8. Staying safe',
              steps: [
                'Use only appliances up to $maxApplianceText. Check the label '
                    'on the appliance.',
                'Never use an aircon, electric kettle, hair dryer or '
                    'induction cooker on WisePlug.',
                'If the WisePlug gets hot, smells, or sparks, unplug it from '
                    'the wall at once.',
                'After a power cut, an outlet that was in use stays off until '
                    'you tap Reset Safety. This is on purpose.',
                'WisePlug works by time and power only. It cannot see smoke or '
                    'fire. Never leave a hot iron unattended.',
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One topic: a tap-to-open card with numbered steps, or a table of
/// "word on the card → what to do".
class _Topic extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<String> steps;
  final List<(String, String)> rows;
  final String? note;
  final bool initiallyExpanded;
  const _Topic({
    required this.icon,
    required this.title,
    this.steps = const [],
    this.rows = const [],
    this.note,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    const text = TextStyle(fontSize: 17, height: 1.4);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: Icon(icon, size: 28),
        title: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, s) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${i + 1}.',
                      style: text.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Expanded(child: Text(s, style: text)),
                ],
              ),
            ),
          for (final (word, meaning) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(word, style: text.copyWith(fontWeight: FontWeight.w700)),
                  Text(meaning, style: text),
                ],
              ),
            ),
          if (note != null)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(note!, style: text),
            ),
        ],
      ),
    );
  }
}
