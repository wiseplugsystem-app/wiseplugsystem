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
  Future<void> _send(String type, bool Function(OutletReading) test) async {
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
          await widget.service.command(reading, type);
        }
      }
      await widget.onSilence();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.updates,
    builder: (context, _) {
      final status = widget.status();
      final now = DateTime.now();
      final triggered = widget
          .readings()
          .values
          .where((r) => r.isWarning || r.isLockedOut)
          .toList();
      final warning = triggered.any((r) => r.isWarning);
      return AlertDialog(
        scrollable: true, // short screens: content scrolls, buttons stay visible
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.warning, color: Colors.white, size: 30),
                    Text(
                      'WARNING',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 23,
                      ),
                    ),
                    Text(
                      'Safety Limit Exceeded!',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _Countdown(
                seconds: warning
                    ? triggered
                          .where((r) => r.isWarning)
                          .map((r) => r.secondsRemaining(now))
                          .reduce((a, b) => a < b ? a : b)
                    : null,
                locked: triggered.isNotEmpty && !warning,
              ),
              const SizedBox(height: 16),
              for (final r in triggered)
                Text(
                  'Outlet ${r.outlet} · ${r.appliance} — '
                  '${r.isWarning ? '${r.secondsRemaining(now)} s until lockout' : 'Locked out'}',
                  textAlign: TextAlign.center,
                ),
              if (triggered.isEmpty) const Text('Waiting for outlet details…'),
              const SizedBox(height: 8),
              Text(
                'Power draw: ${status?.powerDraw.toStringAsFixed(1) ?? '—'} W',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              const Text(
                'Inspect the appliance before resetting. Reset switches the outlet back on; Turn Off Now cuts its power.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              if (_busy) const Text('Waiting for ESP32 confirmation…'),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
        actions: [
          if (warning)
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _send('TURN_OFF', (r) => r.isWarning),
              child: const Text('Turn Off Now'),
            ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: _busy
                ? null
                : () => _send(
                    'RESET_SAFETY',
                    (r) => r.isWarning || r.isLockedOut,
                  ),
            child: const Text('Reset Safety'),
          ),
          TextButton(
            onPressed: _busy ? null : widget.onDismiss,
            child: const Text('Dismiss'),
          ),
        ],
      );
    },
  );
}

/// Large 60-second ring before the outlet is switched off automatically.
class _Countdown extends StatelessWidget {
  final int? seconds;
  final bool locked;
  const _Countdown({required this.seconds, required this.locked});

  @override
  Widget build(BuildContext context) {
    final s = seconds;
    return SizedBox.square(
      dimension: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: s == null ? 0 : s / 60),
              duration: const Duration(milliseconds: 900),
              builder: (context, value, _) => CircularProgressIndicator(
                value: value,
                strokeWidth: 10,
                color: Colors.red,
                backgroundColor: Colors.red.withValues(alpha: .12),
              ),
            ),
          ),
          if (s != null)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$s',
                  style: const TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    color: Colors.red,
                    height: 1,
                  ),
                ),
                const Text('seconds', style: TextStyle(color: Colors.grey)),
              ],
            )
          else
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  locked ? Icons.power_off : Icons.hourglass_empty,
                  size: 40,
                  color: Colors.red,
                ),
                Text(
                  locked ? 'Power cut' : '—',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
