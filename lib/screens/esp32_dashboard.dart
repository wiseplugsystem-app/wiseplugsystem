import 'esp32_live_view.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/device_binding.dart';

import '../models/esp32_data.dart';
import '../services/esp32_service.dart';
import '../services/local_provisioning.dart';
import '../services/recognition_service.dart';
import '../services/session_service.dart';
import '../services/supabase_backend.dart';
import '../widgets/safety_alert_listener.dart';

String measurement(double? value, String unit, [int digits = 1]) =>
    value == null
    ? '—'
    : '${value.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}';

class Esp32Dashboard extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;
  final Esp32Service? service;
  final RecognitionService? recognition;
  const Esp32Dashboard({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
    this.service,
    this.recognition,
  });
  @override
  State<Esp32Dashboard> createState() => _Esp32DashboardState();
}

class _Esp32DashboardState extends State<Esp32Dashboard> {
  late final Esp32Service _service = widget.service ?? Esp32Service();
  // Appliance recognition lives in Supabase (rule-based, recognize-appliance).
  late final RecognitionService? _recognition =
      widget.recognition ??
      (SupabaseBackend.configured ? RecognitionService() : null);
  // Claim before any listener starts: the database rules only let the
  // owner read the device, and a denied listener does not retry.
  late Future<bool> _claim = _service.claimDevice();

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _claim,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.data == true) {
        return SafetyAlertListener(
          service: _service,
          child: Esp32LiveView(
            service: _service,
            recognition: _recognition,
            darkMode: widget.darkMode,
            onDarkModeChanged: widget.onDarkModeChanged,
            onSignOut: () => SessionService.standard().signOut(),
          ),
        );
      }
      return _ClaimProblem(
        ownedByOther: snapshot.data == false,
        onRetry: () => setState(() => _claim = _service.claimDevice()),
        // Binding only when near: pair, then open the WisePlug.
        pairing: snapshot.data == false
            ? _NearPairing(
                service: _service,
                onPaired: () => setState(() => _claim = _service.claimDevice()),
              )
            : null,
      );
    },
  );
}

class _ClaimProblem extends StatelessWidget {
  final bool ownedByOther;
  final VoidCallback onRetry;
  final Widget? pairing;
  const _ClaimProblem({
    required this.ownedByOther,
    required this.onRetry,
    this.pairing,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ownedByOther ? Icons.lock_outline : Icons.wifi_off,
                size: 48,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              if (pairing != null) ...[pairing!, const SizedBox(height: 20)],
              Text(
                ownedByOther
                    ? 'This WisePlug (${DeviceBinding.unitCode}) is already linked to another account. Sign in with that account, or delete it from its User Profile to release the device.'
                    : 'Could not link this WisePlug to your account. Check your internet connection and try again.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (!ownedByOther)
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              TextButton(
                onPressed: () => SessionService.standard().signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Binding only when near: the plug gives its one-time code only to a phone
/// on its local network ("wisewp" or the same home Wi-Fi); with it, this
/// account may claim a plug that has no owner.
class _NearPairing extends StatefulWidget {
  final Esp32Service service;
  final VoidCallback onPaired;
  const _NearPairing({required this.service, required this.onPaired});
  @override
  State<_NearPairing> createState() => _NearPairingState();
}

class _NearPairingState extends State<_NearPairing> {
  bool _busy = false;
  String? _note;

  Future<void> _pair() async {
    if (kIsWeb) {
      setState(() => _note = 'Pair from the WisePlug app on your phone.');
      return;
    }
    setState(() {
      _busy = true;
      _note = 'Looking for your WisePlug nearby…';
    });
    final code = await NearbyPairing.requestCode();
    if (!mounted) return;
    if (code == null) {
      setState(() {
        _busy = false;
        _note =
            'No WisePlug answered. Stand near it and connect this phone to the '
            'same Wi-Fi as the WisePlug (or to "wisewp"), then tap Pair again.';
      });
      return;
    }
    setState(
      () => _note =
          'WisePlug found. Linking… If this phone is on "wisewp", switch it '
          'back to your home Wi-Fi now.',
    );
    // The plug stores the code once it is online; keep trying for its 10 min.
    final until = DateTime.now().add(const Duration(minutes: 10));
    while (mounted && DateTime.now().isBefore(until)) {
      try {
        final ok = await widget.service
            .claimDevice(pairCode: code)
            .timeout(const Duration(seconds: 10));
        if (ok) {
          if (SupabaseBackend.configured) {
            try {
              await SupabaseBackend().linkAccount();
            } catch (_) {}
          }
          if (mounted) widget.onPaired();
          return;
        }
      } catch (_) {
        // Offline for a moment (switching Wi-Fi): try again.
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _note = 'Linking took too long. Tap Pair again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text(
        'To link a WisePlug, you must be near it.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Connect this phone to the same Wi-Fi as the WisePlug (or to '
        '"wisewp"), stand near it, then tap Pair.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _busy ? null : _pair,
        icon: const Icon(Icons.link),
        label: const Text('Pair'),
      ),
      if (_note != null) ...[
        const SizedBox(height: 10),
        Text(_note!, textAlign: TextAlign.center),
      ],
    ],
  );
}

class DatabaseReadError extends StatelessWidget {
  const DatabaseReadError({super.key});
  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'Cannot read device data. Check your internet connection and Firebase Realtime Database read permissions.',
      ),
    ),
  );
}

class Esp32OutletCard extends StatelessWidget {
  final String outlet;
  final OutletReading? reading;
  final DateTime now;
  final Esp32Service? service;
  const Esp32OutletCard({
    super.key,
    required this.outlet,
    required this.reading,
    required this.now,
    this.service,
  });
  @override
  Widget build(BuildContext context) {
    final data = reading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Outlet $outlet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (data == null)
              const Text('Waiting for ESP32 data…')
            else ...[
              Text(
                data.hasConnectedAppliance(now)
                    ? '${data.appliance} · ${data.status}'
                    : data.isFresh(now)
                    ? 'No appliance detected'
                    : 'Live data unavailable',
              ),
              if (data.isLockedOut)
                const Text(
                  'LOCKED OUT — inspect the appliance, then press Reset Safety in the app.',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              if (data.isWarning)
                Text(
                  'Safety limit exceeded. ${data.secondsRemaining(now)} seconds until it turns off.',
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              if (data.runtimeWarning && !data.isWarning && !data.isLockedOut)
                const Text('Recommended runtime exceeded.'),
              if (service != null)
                _OutletControls(service: service!, reading: data, now: now),
              if (data.sensorValid == false) const Text('Sensor unavailable'),
              if (!data.isFresh(now))
                const Text('Reading is stale or its timestamp is unavailable'),
              const SizedBox(height: 12),
              const SizedBox(height: 12),
              if (data.isActive && data.startTime != null)
                Text('Started: ${data.startTime!.toLocal()}'),
              Text(
                'Updated: ${data.lastUpdated?.toLocal().toString() ?? 'Unknown'}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OutletControls extends StatefulWidget {
  final Esp32Service service;
  final OutletReading reading;
  final DateTime now;
  const _OutletControls({
    required this.service,
    required this.reading,
    required this.now,
  });
  @override
  State<_OutletControls> createState() => _OutletControlsState();
}

class _OutletControlsState extends State<_OutletControls> {
  bool _busy = false;
  Future<void> _send(String type) async {
    setState(() => _busy = true);
    try {
      await widget.service.command(
        widget.reading,
        type,
        fields: type == 'SMART_OVERRIDE'
            ? {
                'alertID': widget.reading.alertID,
                'extensionDuration': widget.reading.overrideSeconds(widget.now),
              }
            : {},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ESP32 confirmed the command.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.reading;
    final enabled = !_busy && data.canCommand(widget.now);
    return Wrap(
      spacing: 12,
      children: [
        if (data.isWarning) ...[
          FilledButton(
            onPressed: enabled && data.secondsRemaining(widget.now) > 0
                ? () => _send('SMART_OVERRIDE')
                : null,
            child: const Text('Continue for 15 minutes'),
          ),
          OutlinedButton(
            onPressed: enabled ? () => _send('TURN_OFF') : null,
            child: const Text('Lock now'),
          ),
        ] else
          OutlinedButton(
            onPressed: enabled
                ? () => _send(
                    data.currentState == 'DISABLED' ? 'TURN_ON' : 'TURN_OFF',
                  )
                : null,
            child: Text(
              data.currentState == 'DISABLED'
                  ? 'Enable monitoring'
                  : 'Disable socket state',
            ),
          ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Waiting for ESP32 confirmation…'),
          ),
      ],
    );
  }
}
