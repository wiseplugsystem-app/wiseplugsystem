import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:wiseplug_alarm/wiseplug_alarm.dart';

import '../services/countdown_alarm.dart';
import '../theme.dart';

/// The phone brands that stop apps in the background, and what to switch on.
/// Android does not let an app read or change these settings: WisePlug can
/// only open the page, the user switches it on.
class _Brand {
  final String name;
  final List<String> steps;

  /// The settings pages to offer ('autostart', 'brandBattery',
  /// 'brandPermissions'), each with its button label.
  final Map<String, String> pages;
  final String? note;
  const _Brand(this.name, this.steps, this.pages, {this.note});
}

_Brand? _brandFor(String manufacturer, String brand) {
  bool any(List<String> names) =>
      names.any((n) => manufacturer.contains(n) || brand.contains(n));
  if (any(['xiaomi', 'redmi', 'poco'])) {
    return const _Brand(
      'Xiaomi, Redmi, POCO',
      [
        'Auto-start: turn it ON for WisePlug.',
        'Battery saver: choose "No restrictions".',
        'Other permissions: allow "Show on Lock screen" and "Display pop-up '
            'windows while running in the background".',
        'Recent apps: press and hold WisePlug, then tap the lock, so it is '
            'not closed when you clear the recent apps.',
      ],
      {
        'autostart': 'Open Auto-start',
        'brandBattery': 'Open Battery saver',
        'brandPermissions': 'Open Other permissions',
      },
    );
  }
  if (any(['samsung'])) {
    return const _Brand(
      'Samsung',
      [
        'Battery: choose "Unrestricted".',
        'Settings > Battery > Background usage limits: make sure WisePlug is '
            'NOT in "Sleeping apps" or "Deep sleeping apps".',
        'Notifications: allow them, and show them on the Lock screen.',
      ],
      {'brandBattery': 'Open Battery'},
    );
  }
  if (any(['oppo', 'realme', 'oneplus'])) {
    return const _Brand(
      'Oppo, Realme, OnePlus',
      [
        'Auto launch (Auto-start): turn it ON for WisePlug.',
        'Battery: choose "Allow background activity" (or "Don\'t optimize").',
        'Recent apps: press and hold WisePlug, then tap "Lock".',
        'Notifications: allow Lock screen and Banners.',
      ],
      {'autostart': 'Open Auto launch', 'brandBattery': 'Open Battery'},
    );
  }
  if (any(['vivo', 'iqoo'])) {
    return const _Brand(
      'Vivo, iQOO',
      [
        'Auto-start: turn it ON for WisePlug.',
        'Battery > Background power consumption: choose "Allow high '
            'background power consumption".',
        'Recent apps: pull WisePlug down to lock it.',
      ],
      {'autostart': 'Open Auto-start', 'brandBattery': 'Open Battery'},
    );
  }
  if (any(['huawei', 'honor'])) {
    return const _Brand(
      'Huawei, Honor',
      [
        'App launch: find WisePlug, turn off "Manage automatically", then '
            'turn ON Auto-launch, Secondary launch and Run in background.',
        'Recent apps: pull WisePlug down to lock it.',
      ],
      {'autostart': 'Open App launch', 'brandBattery': 'Open Battery'},
      note:
          'Phones without Google services (newer Huawei) cannot receive the '
          'warning push. The backup alarm still rings if WisePlug was opened '
          'while the appliance was running.',
    );
  }
  if (any(['infinix', 'tecno', 'itel', 'transsion'])) {
    return const _Brand(
      'Infinix, Tecno, itel',
      [
        'Phone Master > Auto-start: allow WisePlug.',
        'Phone Master > Power saving: turn it off for WisePlug.',
        'Recent apps: lock WisePlug.',
      ],
      {'autostart': 'Open Auto-start', 'brandBattery': 'Open Power saving'},
    );
  }
  if (any(['asus'])) {
    return const _Brand('Asus', [
      'Auto-start Manager: allow WisePlug.',
    ], {'autostart': 'Open Auto-start Manager'});
  }
  return null; // Motorola, Nokia, Google…: Android's own settings are enough
}

/// One thing the countdown alarm needs, from [WiseplugAlarm.status].
class _Check {
  final String title, okText, offText, fixLabel;
  final bool ok;
  final Future<void> Function() fix;
  const _Check(
    this.title, {
    required this.ok,
    required this.okText,
    required this.offText,
    required this.fixLabel,
    required this.fix,
  });
}

List<_Check> _checks(Map<String, Object?> s) {
  final sdk = (s['sdk'] as num?)?.toInt() ?? 0;
  final volume = (s['alarmVolume'] as num?)?.toInt() ?? 0;
  return [
    _Check(
      'Notifications',
      ok: s['notifications'] == true,
      okText: 'Allowed',
      offText: 'Off: the countdown cannot be shown',
      fixLabel: 'Allow',
      fix: () async {
        // Android 13+: the question first, then the settings page.
        await FirebaseMessaging.instance.requestPermission(
          alert: true,
          sound: true,
        );
        final now = await WiseplugAlarm.status();
        if (now?['notifications'] != true) {
          await WiseplugAlarm.open('notifications');
        }
      },
    ),
    _Check(
      'Alarm volume',
      ok: volume > 0,
      okText: 'On (the warning uses the alarm volume, like an alarm clock)',
      offText: 'Off: the warning would be silent',
      fixLabel: 'Turn up',
      fix: WiseplugAlarm.raiseAlarmVolume,
    ),
    _Check(
      'Do Not Disturb',
      ok: s['dndBlocksAlarms'] != true,
      okText: 'Lets alarms through',
      offText: 'Blocks alarms: allow "Alarms" in Do Not Disturb',
      fixLabel: 'Open',
      fix: () => WiseplugAlarm.open('dnd'),
    ),
    _Check(
      'Battery optimization',
      ok: s['batteryUnrestricted'] == true,
      okText: 'WisePlug is not optimized',
      offText: 'On: Android may delay or stop the alarm',
      fixLabel: 'Allow',
      fix: () => WiseplugAlarm.open('battery'),
    ),
    if (sdk >= 28)
      _Check(
        'Background activity',
        ok: s['backgroundRestricted'] != true,
        okText: 'Allowed',
        offText: 'Restricted: choose Battery > "Unrestricted"',
        fixLabel: 'Open',
        fix: () => WiseplugAlarm.open('appInfo'),
      ),
    if (sdk >= 31)
      _Check(
        'Alarms & reminders',
        ok: s['exactAlarms'] == true,
        okText: 'Allowed (the backup alarm rings on time)',
        offText: 'Off: the backup alarm may ring late',
        fixLabel: 'Allow',
        fix: () => WiseplugAlarm.open('exactAlarms'),
      ),
    if (sdk >= 34)
      _Check(
        'Full-screen alerts',
        ok: s['fullScreen'] == true,
        okText: 'Allowed (the countdown covers the lock screen)',
        offText: 'Off: only a notification on the lock screen',
        fixLabel: 'Allow',
        fix: () => WiseplugAlarm.open('fullScreen'),
      ),
  ];
}

bool _remindedThisStart = false;

/// At app start (Android): if a setting the countdown alarm needs is off,
/// one reminder with "Fix" (once per start of the app).
Future<void> remindAlarmSetup(BuildContext context) async {
  if (!CountdownAlarm.supported || _remindedThisStart) return;
  _remindedThisStart = true;
  final s = await WiseplugAlarm.status();
  if (s == null || !context.mounted) return;
  final off = _checks(s).where((c) => !c.ok).length;
  final brand = _brandFor('${s['manufacturer']}', '${s['brand']}');
  final brandOpen = brand != null && !await WiseplugAlarm.getFlag('brand_done');
  if ((off == 0 && !brandOpen) || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  messenger?.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 12),
      content: Text(
        off > 0
            ? 'Safety alarm: $off phone setting${off == 1 ? '' : 's'} '
                  'to check, so the warning sounds with the app closed.'
            : 'Safety alarm: one more step for ${brand!.name} phones, so the '
                  'warning sounds with the app closed.',
      ),
      action: SnackBarAction(
        label: 'Fix',
        onPressed: () => navigator.push(
          MaterialPageRoute<void>(builder: (_) => const AlarmSetupScreen()),
        ),
      ),
    ),
  );
}

/// "Safety alarm setup": what the phone must allow so the countdown alarm
/// sounds with the app closed or the phone locked, with a button for each,
/// the steps for this phone's brand, and a test alarm.
class AlarmSetupScreen extends StatefulWidget {
  const AlarmSetupScreen({super.key});

  @override
  State<AlarmSetupScreen> createState() => _AlarmSetupScreenState();
}

class _AlarmSetupScreenState extends State<AlarmSetupScreen>
    with WidgetsBindingObserver {
  Map<String, Object?>? _status;
  bool _brandDone = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from a settings page: read the settings again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await WiseplugAlarm.status();
    final done = await WiseplugAlarm.getFlag('brand_done');
    if (!mounted) return;
    setState(() {
      _status = s;
      _brandDone = done;
      _loaded = true;
    });
  }

  Future<void> _test() async {
    final started = await WiseplugAlarm.start(
      eventId: 'test_${DateTime.now().millisecondsSinceEpoch}',
      outlet: 'A',
      appliance: 'Test',
      endsAt: DateTime.now().add(const Duration(seconds: 15)),
      test: true,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          started
              ? 'Test alarm for 15 s. Lock the phone or close WisePlug to '
                    'try it; tap "Stop alarm" to end it.'
              : 'The test alarm could not start: allow notifications first.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final brand = s == null
        ? null
        : _brandFor('${s['manufacturer']}', '${s['brand']}');
    return Scaffold(
      appBar: AppBar(title: const Text('Safety alarm setup')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : s == null
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: Text('The safety alarm setup is for Android phones.'),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'When an appliance\'s safe time is up, WisePlug rings like '
                  'an alarm clock and shows the countdown, even with the app '
                  'closed or the phone locked. Your phone must allow it:',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      for (final c in _checks(s))
                        ListTile(
                          leading: Icon(
                            c.ok ? Icons.check_circle : Icons.warning_amber,
                            color: c.ok ? Colors.green : Colors.orange,
                          ),
                          title: Text(c.title),
                          subtitle: Text(c.ok ? c.okText : c.offText),
                          trailing: c.ok
                              ? null
                              : FilledButton(
                                  onPressed: () async {
                                    await c.fix();
                                    await _refresh();
                                  },
                                  child: Text(c.fixLabel),
                                ),
                        ),
                    ],
                  ),
                ),
                if (brand != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'On ${brand.name} phones',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'These phones close apps in the background. WisePlug '
                    'cannot switch these on by itself: open each page and '
                    'switch it on.',
                    style: TextStyle(color: context.muted, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  for (final (i, step) in brand.steps.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${i + 1}. $step',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final e in brand.pages.entries)
                        OutlinedButton(
                          onPressed: () => WiseplugAlarm.open(e.key),
                          child: Text(e.value),
                        ),
                      OutlinedButton(
                        onPressed: () => WiseplugAlarm.open('appInfo'),
                        child: const Text('Open app settings'),
                      ),
                    ],
                  ),
                  if (brand.note != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      brand.note!,
                      style: TextStyle(color: context.muted, fontSize: 16),
                    ),
                  ],
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _brandDone,
                    title: const Text('I did these steps'),
                    onChanged: (v) async {
                      await WiseplugAlarm.setFlag('brand_done', v == true);
                      await _refresh();
                    },
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _test,
                  icon: const Icon(Icons.alarm),
                  label: const Text('Test the alarm (15 s)'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Even with everything allowed, a phone that force-stops '
                  'WisePlug (or has no internet) cannot ring. The power is '
                  'still cut by the WisePlug itself at the end of the safe '
                  'time, with or without the phone.',
                  style: TextStyle(color: context.muted, fontSize: 14),
                ),
              ],
            ),
    );
  }
}
