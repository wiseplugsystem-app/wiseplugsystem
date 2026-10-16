import 'dart:async';

import 'package:flutter/material.dart';

import '../models/esp32_data.dart';
import '../models/gadget_status.dart';
import '../services/esp32_service.dart';
import '../services/safety_alarm_manager.dart';

/// App-wide safety watchdog. Place it below the Navigator (e.g. around the
/// signed-in home screen) so its dialog covers every tab and pushed screen.
///
/// The dialog and looping alarm start automatically only when the gadget
/// reports `safetyTriggered == true` or `remainingLimit <= 0`. Dismissing
/// silences that event; a new event (the condition clears, then recurs)
/// raises it again. The dialog closes itself when the condition clears.
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
          onSilence: _alarm.stopAlarm,
          onDismiss: () {
            _dismissed = true;
            _close();
          },
        ),
      ),
    );
    unawaited(_alarm.playSafetyAlarm());
    await navigator.push(route);
    if (identical(_route, route)) _close();
  }

  /// Closes the dialog exactly once and silences the alarm.
  void _close() {
    final route = _route;
    if (route == null) return;
    _route = null;
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
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Keeps the appliance running: the ESP32 extends the session by 15 min.
  static Map<String, Object?> _override(OutletReading r) => {
    'alertID': r.alertID,
    'extensionDuration': 900,
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
      final outlets = triggered.map((r) => 'Outlet ${r.outlet}').join(' & ');
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
                const _Header(),
                const SizedBox(height: 28),
                if (warning) ...[
                  // The countdown is the focus: big, centered, alone.
                  Text(
                    '$seconds',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 96,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: seconds <= 10 ? Colors.red : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Seconds Remaining',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 26),
                  const Text(
                    'Are you still using the Appliance?',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                ] else ...[
                  const Icon(Icons.power_off, size: 84, color: Colors.red),
                  const SizedBox(height: 8),
                  const Text(
                    'Power cut',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'The outlet was switched off for safety. Inspect the '
                    'appliance, then reset to switch it back on.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, height: 1.4),
                  ),
                ],
                if (outlets.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    outlets,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
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
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 24),
                Row(
                  children: warning
                      ? [
                          _choice(
                            'Turn Off Now',
                            () => _send('TURN_OFF', (r) => r.isWarning),
                          ),
                          const SizedBox(width: 14),
                          _choice(
                            'Yes, Override',
                            () => _send(
                              'SMART_OVERRIDE',
                              (r) => r.isWarning,
                              fields: _override,
                            ),
                          ),
                        ]
                      : [
                          _choice('Dismiss', widget.onDismiss),
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
                if (warning)
                  TextButton(
                    onPressed: _busy ? null : widget.onDismiss,
                    child: const Text('Dismiss'),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

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

class _Header extends StatelessWidget {
  const _Header();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
    decoration: BoxDecoration(
      color: const Color(0xFFFF1A1A),
      borderRadius: BorderRadius.circular(16),
    ),
    child: const Column(
      children: [
        Icon(Icons.warning_rounded, color: Colors.white, size: 44),
        SizedBox(height: 4),
        FittedBox(
          child: Text(
            'WARNING',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 30,
            ),
          ),
        ),
        FittedBox(
          child: Text(
            'Safety Limit Exceeded!',
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}
