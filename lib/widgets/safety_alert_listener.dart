import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

import '../models/appliance_icons.dart';
import '../models/esp32_data.dart';
import '../models/gadget_status.dart';
import '../services/esp32_service.dart';
import '../services/safety_alarm_manager.dart';

/// App-wide safety watchdog. Place it below the Navigator (e.g. around the
/// signed-in home screen) so its dialog covers every tab and pushed screen.
///
/// The dialog and its warning sound start automatically only when the gadget
/// reports `safetyTriggered == true` or `remainingLimit <= 0`. Dismissing
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

  /// Time left until the soonest cutoff among the outlets in warning.
  Duration? _untilCutoff() {
    final now = DateTime.now();
    final seconds = _readings.values
        .where((r) => r.isWarning)
        .map((r) => r.secondsRemaining(now));
    return seconds.isEmpty
        ? null
        : Duration(seconds: seconds.reduce((a, b) => a < b ? a : b));
  }

  /// The warning ended with the power cut: one long beep.
  void _checkCutoff() {
    if (_route == null || !_warningSounding) return;
    final values = _readings.values;
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
    return status != null &&
        status.isOnline(DateTime.now()) &&
        status.needsSafetyAlert;
  }

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        widget.service.streamGadgetStatus().listen((status) {
          _status = status;
          _evaluate();
        }, onError: (Object _) {}),
      )
      ..add(
        widget.service.streamOutlets().listen((readings) {
          _readings = readings;
          _updates.value++;
          _checkCutoff();
        }, onError: (Object _) {}),
      );
  }

  void _evaluate() {
    if (!mounted) return;
    _updates.value++;
    if (!_alertActive) {
      _dismissed = false;
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
    if (_readings.values.any((r) => r.isWarning)) {
      _warningSounding = true;
      unawaited(_alarm.playSafetyAlarm(remaining: _untilCutoff));
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
      if (type == 'SMART_OVERRIDE') {
        // Accepted: close the 60-second window now instead of waiting for
        // the next status update.
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
          .where((r) => r.isWarning || r.isLockedOut)
          .toList();
      final warnings = triggered.where((r) => r.isWarning).toList();
      final warning = warnings.isNotEmpty;
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
                if (warning) ...[
                  Text(
                    triggered.length == 1
                        ? 'Still using the ${_nameOf(triggered.single)}?'
                        : 'Still using them?',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 18),
                  // The countdown is the focus: big, centered, alone.
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
                ] else ...[
                  Text(
                    'Check the appliance first. After Reset Safety it stays '
                    'off until you turn it on again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.muted, height: 1.4),
                  ),
                ],
                // Which appliance, with its icon and name, on which outlet.
                for (final r in triggered) ...[
                  const SizedBox(height: 10),
                  Row(
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
                  ),
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
                Row(
                  children: warning
                      ? [
                          _choice(
                            'Turn off now',
                            () => _send('TURN_OFF', (r) => r.isWarning),
                          ),
                          const SizedBox(width: 14),
                          _choice(
                            'Keep it on',
                            () => _send(
                              'SMART_OVERRIDE',
                              (r) => r.isWarning,
                              fields: _override,
                            ),
                          ),
                        ]
                      : [
                          _choice('Close', widget.onDismiss),
                          const SizedBox(width: 14),
                          _choice(
                            'Reset Safety',
                            () => _send(
                              'RESET_SAFETY',
                              (r) => r.isWarning || r.isLockedOut,
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

  /// The plug names the appliance it recognised; until then it says it does
  /// not know it, which shows the question-mark icon.
  static bool _known(OutletReading r) => !const {
    '',
    'None',
    'Unknown appliance',
    'Recognizing appliance',
  }.contains(r.appliance);
  static ApplianceKind _kindOf(OutletReading r) =>
      _known(r) ? kindForType(r.appliance) : unknownKind;
  static String _nameOf(OutletReading r) =>
      _known(r) ? r.appliance : 'Unknown appliance';

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
