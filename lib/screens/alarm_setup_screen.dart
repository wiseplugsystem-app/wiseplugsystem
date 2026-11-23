import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:wiseplug_alarm/wiseplug_alarm.dart';

import '../services/countdown_alarm.dart';

/// The phone brands that stop apps in the background unless Auto-start (or
/// their own name for it) is on. Android does not let an app read or change
/// it: WisePlug can only open the page, the user switches it on.
class _Brand {
  final String name;

  /// What the brand calls its Auto-start page.
  final String autostart;
  const _Brand(this.name, this.autostart);
}

_Brand? _brandFor(String manufacturer, String brand) {
  bool any(List<String> names) =>
      names.any((n) => manufacturer.contains(n) || brand.contains(n));
  if (any(['xiaomi', 'redmi', 'poco'])) {
    return const _Brand('Xiaomi, Redmi, POCO', 'Auto-start');
  }
  if (any(['oppo', 'realme', 'oneplus'])) {
    return const _Brand('Oppo, Realme, OnePlus', 'Auto launch');
  }
  if (any(['vivo', 'iqoo'])) return const _Brand('Vivo, iQOO', 'Auto-start');
  if (any(['huawei', 'honor'])) {
    return const _Brand('Huawei, Honor', 'App launch');
  }
  if (any(['infinix', 'tecno', 'itel', 'transsion'])) {
    return const _Brand('Infinix, Tecno, itel', 'Auto-start');
  }
  if (any(['asus'])) return const _Brand('Asus', 'Auto-start Manager');
  return null; // Samsung, Motorola, Nokia, Google…: no Auto-start page
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

/// [autostartDone]: the brand's Auto-start page was opened from here.
List<_Check> _checks(Map<String, Object?> s, {bool autostartDone = false}) {
  final sdk = (s['sdk'] as num?)?.toInt() ?? 0;
  final volume = (s['alarmVolume'] as num?)?.toInt() ?? 0;
  final brand = _brandFor('${s['manufacturer']}', '${s['brand']}');
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
    // Phones that close apps in the background: their Auto-start page. The
    // app cannot read it, so it counts as done once opened from here.
    if (brand != null)
      _Check(
        brand.autostart,
        ok: autostartDone,
        okText: 'Opened: make sure WisePlug is switched on there',
        offText:
            'Switch it on for WisePlug, or the alarm may not sound with the '
            'app closed',
        fixLabel: 'Open',
        fix: () async {
          await WiseplugAlarm.open('autostart');
          await WiseplugAlarm.setFlag('brand_done', true);
        },
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
  final done = await WiseplugAlarm.getFlag('brand_done');
  final off = _checks(s, autostartDone: done).where((c) => !c.ok).length;
  if (off == 0 || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  messenger?.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 12),
      content: Text(
        'Alarm permissions: $off phone setting${off == 1 ? '' : 's'} '
        'to check, so the warning sounds with the app closed.',
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

/// "Alarm permissions": what the phone must allow so the countdown alarm
/// sounds with the app closed or the phone locked, with a button for each.
class AlarmSetupScreen extends StatefulWidget {
  const AlarmSetupScreen({super.key});

  @override
  State<AlarmSetupScreen> createState() => _AlarmSetupScreenState();
}

class _AlarmSetupScreenState extends State<AlarmSetupScreen>
    with WidgetsBindingObserver {
  Map<String, Object?>? _status;
  bool _autostartDone = false;
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
      _autostartDone = done;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Alarm permissions')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : s == null
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Alarm permissions are for Android phones.'),
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
                      for (final c in _checks(s, autostartDone: _autostartDone))
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
              ],
            ),
    );
  }
}
