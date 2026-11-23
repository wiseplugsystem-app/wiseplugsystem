import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

import '../models/appliance_icons.dart';
import '../models/esp32_data.dart';
import '../models/gadget_status.dart';
import '../screens/alarm_setup_screen.dart';
import '../services/countdown_alarm.dart';
import '../services/esp32_service.dart';
import '../services/safety_alarm_manager.dart';
import '../services/supabase_backend.dart';

/// The appliance each safe-time warning was about, by the plug's alert id.
final _warningNames = <String, String>{};

/// App-wide safety watchdog. Place it below the Navigator (e.g. around the
/// signed-in home screen) so its dialog covers every tab and pushed screen.
///
/// The dialog and its warning sound start automatically only when the gadget
/// reports `safetyTriggered == true` or `remainingLimit <= 0` AND an outlet's
/// safe time is up (its alertType is SAFETY_CEILING_EXCEEDED): the pop-up is
/// for the safe time only. A meter that stops answering, too much power or a
/// fault show on the outlet card and as a phone notification. Dismissing
/// silences that event; a new event (the condition clears, then recurs)
/// raises it again. The dialog closes itself when the condition clears.
///
/// Sound (SafetyAlarmManager): during a warning, two short beeps that come
/// faster in the last 10 s; when the power is cut (also an electrical trip),
/// one long beep. There is no mute: the sound stops when the warning is over.
class SafetyAlertListener extends StatefulWidget {
  final Esp32Service service;
  final SafetyAlarmManager? alarm;
  final Widget child;
  const SafetyAlertListener({
    super.key,
    required this.service,
    required this.child,
    this.alarm,
  });

  @override
  State<SafetyAlertListener> createState() => _SafetyAlertListenerState();
}

class _SafetyAlertListenerState extends State<SafetyAlertListener> {
  late final SafetyAlarmManager _alarm = widget.alarm ?? SafetyAlarmManager();
  final _updates = ValueNotifier<int>(0);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  GadgetStatus? _status;
  Map<String, OutletReading> _readings = {};
  DialogRoute<void>? _route;
  bool _dismissed = false;
  bool _warningSounding = false; // the warning pattern is playing
  bool _wasCleared = false; // the plug's safety flag went off since the alert

  /// The outlets whose safe time is up: warning, or turned off by it.
  // isCurrentForAlert: fresh, or a lock-out / running countdown that the
  // plug has not updated within 30 s (or its clock is not synced): the
  // pop-up must not disappear then.
  Iterable<OutletReading> get _safeTime => _readings.values.where(
    (r) =>
        r.isCurrentForAlert(DateTime.now()) &&
        (r.isWarning || r.isLockedOut) &&
        r.isSafeTimeAlert,
  );

  /// Time left until the soonest cutoff among the outlets in warning.
  Duration? _untilCutoff() {
    final now = DateTime.now();
    final seconds = _safeTime
        .where((r) => r.isWarning)
        .map((r) => r.secondsRemaining(now));
    return seconds.isEmpty
        ? null
        : Duration(seconds: seconds.reduce((a, b) => a < b ? a : b));
  }

  /// The warning ended with the power cut: one long beep.
  void _checkCutoff() {
    if (_route == null || !_warningSounding) return;
    final values = _safeTime;
    if (values.any((r) => r.isWarning) || !values.any((r) => r.isLockedOut)) {
      return;
    }
    _warningSounding = false;
    unawaited(_alarm.playCutoff());
  }

  Future<void> _silence() {
    _warningSounding = false;
    return _alarm.stopAlarm();
  }

  bool get _alertActive {
    final status = _status;
    final now = DateTime.now();
    final readings = _safeTime;
    final lockedOut = readings.any((r) => r.isLockedOut);
    final warning = readings.any((r) => r.isWarning);
    return status != null &&
        status.isOnline(now) &&
        (lockedOut || (status.needsSafetyAlert && warning));
  }

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        widget.service.streamGadgetStatus().listen((status) {
          // A new event: the plug cleared its safety flag, then raised it
          // again. A pop-up closed for the previous event opens again.
          final before = _status?.needsSafetyAlert ?? false;
          if (status.needsSafetyAlert && !before && _wasCleared) {
            _dismissed = false;
          }
          if (!status.needsSafetyAlert) _wasCleared = true;
          if (status.needsSafetyAlert && !before) _wasCleared = false;
          _status = status;
          _evaluate();
        }, onError: (Object _) {}),
      )
      ..add(
        widget.service.streamOutlets().listen((readings) {
          _readings = readings;
          _rememberNames(readings);
          _checkCutoff();
          _evaluate();
          // Android: an outlet that goes into warning while the pop-up is
          // open rings too, and each running appliance keeps a backup alarm
          // at its deadline (for when the warning push does not arrive).
          if (_route != null && _warningSounding) {
            unawaited(
              CountdownAlarm.ringNewWarnings(
                _safeTime.where((r) => r.isWarning),
              ),
            );
          }
          unawaited(CountdownAlarm.syncBackups(readings));
        }, onError: (Object _) {}),
      );
    // Android: reminds once per start if a setting the alarm needs is off.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(remindAlarmSetup(context));
    });
  }

  /// Safety-log lookups already asked for (each warning once).
  final _looked = <String>{};

  /// The appliance each warning was about (by the plug's alert id, which
  /// stays the same after the cut-off): while the plug names it, and else
  /// from the safety log (the plug sends the name with the warning and the
  /// cut-off, just before it ends the run and forgets it).
  void _rememberNames(Map<String, OutletReading> readings) {
    for (final r in readings.values) {
      if (r.alertID.isEmpty || !r.isSafeTimeAlert) continue;
      if (_SafetyAlertDialogState._known(r) && (r.isWarning || r.isLockedOut)) {
        _warningNames[r.alertID] = r.appliance;
      } else if (r.isLockedOut &&
          !_warningNames.containsKey(r.alertID) &&
          _looked.add(r.alertID) &&
          SupabaseBackend.configured) {
        unawaited(_lookUpName(r.alertID));
      }
    }
  }

  Future<void> _lookUpName(String alertID) async {
    try {
      final name = await SupabaseBackend().applianceNameOfAlert(alertID);
      if (name == null || !mounted) return;
      _warningNames[alertID] = name;
      _updates.value++; // the open pop-up shows it
    } catch (_) {
      // Offline: "Unknown appliance" stays; asked again on the next start.
    }
  }

  void _evaluate() {
    if (!mounted) return;
    _updates.value++;
    if (!_alertActive) {
      if (!_readings.values.any((r) => r.isLockedOut)) _dismissed = false;
      _close();
      return;
    }
    if (!_dismissed && _route == null) _show();
  }

  Future<void> _show() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = _route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (_) => PopScope(
        canPop: false,
        child: _SafetyAlertDialog(
          updates: _updates,
          status: () => _status,
          readings: () => _readings,
          service: widget.service,
          onSilence: _silence,
          onDismiss: () {
            _dismissed = true;
            _close();
          },
        ),
      ),
    );
    if (_safeTime.any((r) => r.isWarning)) {
      _warningSounding = true;
      unawaited(
        _alarm.playSafetyAlarm(
          remaining: _untilCutoff,
          // The Android countdown alarm rings each outlet in warning.
          warnings: () => _safeTime.where((r) => r.isWarning),
        ),
      );
    } else {
      unawaited(_alarm.playCutoff()); // cut at once, e.g. an electrical trip
    }
    await navigator.push(route);
    if (identical(_route, route)) _close();
  }

  /// Closes the dialog exactly once and silences the alarm.
  void _close() {
    final route = _route;
    if (route == null) return;
    _route = null;
    _warningSounding = false;
    _alarm.stopAlarm();
    if (!route.isActive) return;
    if (route.isCurrent) {
      route.navigator!.pop();
    } else {
      route.navigator!.removeRoute(route);
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _close();
    _updates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SafetyAlertDialog extends StatefulWidget {
  final ValueNotifier<int> updates;
  final GadgetStatus? Function() status;
  final Map<String, OutletReading> Function() readings;
  final Esp32Service service;
  final Future<void> Function() onSilence;
  final VoidCallback onDismiss;
  const _SafetyAlertDialog({
    required this.updates,
    required this.status,
    required this.readings,
    required this.service,
    required this.onSilence,
    required this.onDismiss,
  });

  @override
  State<_SafetyAlertDialog> createState() => _SafetyAlertDialogState();
}

class _SafetyAlertDialogState extends State<_SafetyAlertDialog> {
  bool _busy = false;
  String? _error;
  // Repaints the countdown every second between device updates.
  late final Timer _tick = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  /// Sends [type] to every outlet matching [test] and waits for the ESP32.
  Future<void> _send(
    String type,
    bool Function(OutletReading) test, {
    Map<String, Object?> Function(OutletReading)? fields,
  }) async {
    final targets = widget.readings().values.where(test).toList();
    if (targets.isEmpty) {
      setState(() => _error = 'Live outlet data is unavailable. Try again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      for (final reading in targets) {
        if (type == 'RESET_SAFETY') {
          await widget.service.resetSafety(reading);
        } else {
          await widget.service.command(
            reading,
            type,
            fields: fields?.call(reading) ?? const {},
          );
        }
      }
      await widget.onSilence();
      // Accepted: close the 60-second window now, unless another outlet is
      // still waiting for an answer (then the pop-up stays for that one).
      final othersWaiting = widget
          .readings()
          .values
          .where((r) => r.isWarning && r.isSafeTimeAlert)
          .any((r) => !targets.any((t) => t.outlet == r.outlet));
      if (type == 'SMART_OVERRIDE' && !othersWaiting) {
        widget.onDismiss();
        messenger?.showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 8),
            content: Text(
              'OK, it stays on a little longer. WisePlug will ask you again.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Keeps the appliance running on a 20% safety buffer. Sent for firmware
  /// that reads it; newer firmware computes the same value itself.
  static Map<String, Object?> _override(OutletReading r) => {
    'alertID': r.alertID,
    'extensionDuration': r.overrideSeconds(DateTime.now()),
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.updates,
    builder: (context, _) {
      final now = DateTime.now();
      final triggered = widget
          .readings()
          .values
          .where(
            (r) =>
                r.isCurrentForAlert(now) &&
                (r.isWarning || r.isLockedOut) &&
                r.isSafeTimeAlert,
          )
          .toList();
      final warnings = triggered.where((r) => r.isWarning).toList();
      final warning = warnings.isNotEmpty;
      final single = triggered.length == 1;
      final seconds = warning
          ? warnings
                .map((r) => r.secondsRemaining(now))
                .reduce((a, b) => a < b ? a : b)
          : 0;
      return Dialog(
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          // Scrolls on short screens so the buttons stay reachable.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(warning: warning),
                const SizedBox(height: 24),
                if (single && warning) ...[
                  Text(
                    'Still using the ${_nameOf(triggered.single)}?',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 18),
                  // The countdown is the focus: big, centered, alone. At 0
                  // the plug is turning it off: say so instead of a stuck 0.
                  if (seconds > 0) ...[
                    Text(
                      '$seconds',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 96,
                        fontWeight: FontWeight.w800,
                        height: 1,
                        color: seconds <= 10
                            ? context.readable(Colors.red)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'seconds until it turns off',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                    // The 60-second answer window, emptying with the
                    // countdown above (the same seconds, every second).
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        key: const ValueKey('safety-countdown-bar'),
                        value: (seconds / 60).clamp(0.0, 1.0),
                        minHeight: 10,
                        color: seconds <= 10 ? Colors.red : Colors.orange,
                        backgroundColor: Colors.grey.withValues(alpha: .2),
                      ),
                    ),
                    // Override limit: how many "Keep it on" are left.
                    const SizedBox(height: 10),
                    Text(
                      _overrideNote(triggered.single),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: triggered.single.canOverride
                            ? FontWeight.w500
                            : FontWeight.w700,
                        color: triggered.single.canOverride
                            ? context.muted
                            : context.readable(Colors.red),
                      ),
                    ),
                  ] else
                    const Text(
                      'No answer: WisePlug is turning it off now…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ] else if (single) ...[
                  // After the cutoff: what happened, in one plain sentence.
                  Text(
                    _offSentence(triggered.single),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Check the appliance first. After Reset Safety it stays '
                    'off until you turn it on again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.muted, height: 1.4),
                  ),
                ] else ...[
                  // Two outlets at once: one row each, with its own state.
                  Text(
                    warning
                        ? 'Two appliances reached their safe time.'
                        : 'Both appliances reached their safe time, so '
                              'WisePlug turned them off.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                    ),
                  ),
                  for (final r in triggered) _row(r, now),
                ],
                // Which appliance, with its icon and name, on which outlet.
                if (single) ...[
                  const SizedBox(height: 10),
                  _applianceLine(triggered.single),
                ],
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Waiting for the WisePlug…',
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.readable(Colors.red)),
                    ),
                  ),
                const SizedBox(height: 24),
                if (single || !warning)
                  Row(
                    children: warning
                        ? [
                            _choice(
                              'Turn off now',
                              () => _send('TURN_OFF', (r) => r.isWarning),
                            ),
                            // At the override limit: only "Turn off now".
                            if (triggered.single.canOverride) ...[
                              const SizedBox(width: 14),
                              _choice(
                                'Keep it on',
                                () => _send(
                                  'SMART_OVERRIDE',
                                  (r) => r.isWarning,
                                  fields: _override,
                                ),
                              ),
                            ],
                          ]
                        : [
                            _choice('Close', widget.onDismiss),
                            const SizedBox(width: 14),
                            _choice(
                              single ? 'Reset Safety' : 'Reset both',
                              () => _send(
                                'RESET_SAFETY',
                                (r) => r.isLockedOut && r.isSafeTimeAlert,
                              ),
                              danger: true,
                            ),
                          ],
                  ),
                // No Close during the countdown: the warning (and its
                // sound) ends only with Turn off now, Keep it on or the
                // cutoff.
              ],
            ),
          ),
        ),
      );
    },
  );

  /// Under the countdown: the "Keep it on" left, or that they are used up.
  static String _overrideNote(OutletReading r) {
    final left = r.overridesLeft;
    if (left == null) return 'Tap "Keep it on" for extra time.';
    if (left <= 0) {
      return 'No more extra time for this use. It turns off at 0.';
    }
    return left == 1
        ? 'Last time you can tap "Keep it on" for this use.'
        : 'You can tap "Keep it on" $left more times for this use.';
  }

  /// "The efan on Outlet B reached its safe time, so WisePlug turned it off."
  static String _offSentence(OutletReading r) =>
      'The ${_nameOf(r)} on Outlet ${r.outlet} reached its safe time, so '
      'WisePlug turned it off.';

  Widget _applianceLine(OutletReading r) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      ApplianceIcon(_kindOf(r), size: 24, label: _nameOf(r)),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          '${_nameOf(r)} · Outlet ${r.outlet}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );

  /// One outlet when two are in the pop-up: its appliance, its own countdown
  /// (or that it was turned off), and buttons for that outlet only.
  Widget _row(OutletReading r, DateTime now) {
    final left = r.secondsRemaining(now);
    bool here(OutletReading x) => x.outlet == r.outlet;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: r.isWarning ? Colors.red : context.muted.withValues(alpha: .4),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _applianceLine(r),
          const SizedBox(height: 6),
          Text(
            r.isWarning
                ? left > 0
                      ? 'Turns off in $left s'
                      : 'Turning off now…'
                : 'Reached its safe time: turned off',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: r.isWarning && left <= 10
                  ? context.readable(Colors.red)
                  : null,
            ),
          ),
          if (r.isWarning && left > 0) ...[
            const SizedBox(height: 4),
            Text(
              _overrideNote(r),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: r.canOverride ? FontWeight.w500 : FontWeight.w700,
                color: r.canOverride
                    ? context.muted
                    : context.readable(Colors.red),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: r.isWarning
                ? [
                    _choice(
                      'Turn off',
                      () => _send('TURN_OFF', (x) => here(x) && x.isWarning),
                    ),
                    // At the override limit: only "Turn off".
                    if (r.canOverride) ...[
                      const SizedBox(width: 10),
                      _choice(
                        'Keep it on',
                        () => _send(
                          'SMART_OVERRIDE',
                          (x) => here(x) && x.isWarning,
                          fields: _override,
                        ),
                      ),
                    ],
                  ]
                : [
                    _choice(
                      'Reset Safety',
                      () => _send(
                        'RESET_SAFETY',
                        (x) => here(x) && x.isLockedOut,
                      ),
                      danger: true,
                    ),
                  ],
          ),
        ],
      ),
    );
  }

  /// The plug names the appliance it recognised; until then it says it does
  /// not know it, which shows the question-mark icon.
  static bool _known(OutletReading r) => !const {
    '',
    'None',
    'Unknown appliance',
    'Recognizing appliance',
  }.contains(r.appliance);
  static ApplianceKind _kindOf(OutletReading r) {
    if (_known(r)) return kindForType(r.appliance);
    final name = _warningNames[r.alertID];
    return name == null ? unknownKind : kindForType(name);
  }

  /// After the cut-off the plug has ended the run and no longer names it:
  /// the name the warning had (remembered, or from the safety log).
  static String _nameOf(OutletReading r) =>
      _known(r) ? r.appliance : _warningNames[r.alertID] ?? 'Unknown appliance';

  Widget _choice(
    String label,
    VoidCallback onPressed, {
    bool danger = false,
  }) => Expanded(
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: danger ? Colors.red : const Color(0xFFC9DDFB),
        foregroundColor: danger ? Colors.white : Colors.black87,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      onPressed: _busy ? null : onPressed,
      child: FittedBox(child: Text(label)),
    ),
  );
}

/// One red bar with one line: what happened, in plain words.
class _Header extends StatelessWidget {
  final bool warning;
  const _Header({required this.warning});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
    decoration: BoxDecoration(
      color: const Color(0xFFFF1A1A),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Icon(
          warning ? Icons.warning_rounded : Icons.power_off,
          color: Colors.white,
          size: 44,
        ),
        const SizedBox(height: 4),
        FittedBox(
          child: Text(
            warning ? 'Safe time is up' : 'Turned off for safety',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 26,
            ),
          ),
        ),
      ],
    ),
  );
}
