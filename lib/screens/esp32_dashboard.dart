import 'esp32_live_view.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/esp32_data.dart';
import '../services/device_binding.dart';
import '../services/esp32_service.dart';
import '../widgets/safety_alert_listener.dart';

String measurement(double? value, String unit, [int digits = 1]) =>
    value == null
    ? '—'
    : '${value.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}';

class Esp32Dashboard extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;
  final Esp32Service? service;
  const Esp32Dashboard({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
    this.service,
  });
  @override
  State<Esp32Dashboard> createState() => _Esp32DashboardState();
}

class _Esp32DashboardState extends State<Esp32Dashboard> {
  late final Esp32Service _service = widget.service ?? Esp32Service();
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
            darkMode: widget.darkMode,
            onDarkModeChanged: widget.onDarkModeChanged,
            onSignOut: () => FirebaseAuth.instance.signOut(),
          ),
        );
      }
      return _ClaimProblem(
        ownedByOther: snapshot.data == false,
        onRetry: () => setState(() => _claim = _service.claimDevice()),
      );
    },
  );
}

class _ClaimProblem extends StatelessWidget {
  final bool ownedByOther;
  final VoidCallback onRetry;
  const _ClaimProblem({required this.ownedByOther, required this.onRetry});

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
              Text(
                ownedByOther
                    ? 'This WisePlug (${DeviceBinding.gadgetId}) is already linked to another account. Sign in with that account, or delete it from its User Profile to release the device.'
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
                onPressed: () => FirebaseAuth.instance.signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    ),
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
                  'LOCKED OUT — inspect the appliance, then reset it with its physical button or the safety alert.',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              if (data.isWarning)
                Text(
                  'Safety limit exceeded. ${data.secondsRemaining(now)} seconds until physical lockout.',
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
            ? {'alertID': widget.reading.alertID, 'extensionDuration': 900}
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

class Esp32ProfileEditor extends StatefulWidget {
  final bool registration;
  final Esp32Service service;
  final OutletReading reading;
  final LearnedAppliance profile;

  /// Lower-cased names of the user's other appliances; reused names are refused.
  final Set<String> takenNames;
  const Esp32ProfileEditor({
    super.key,
    required this.service,
    required this.reading,
    required this.profile,
    this.registration = false,
    this.takenNames = const {},
  });
  @override
  State<Esp32ProfileEditor> createState() => Esp32ProfileEditorState();
}

class Esp32ProfileEditorState extends State<Esp32ProfileEditor> {
  late final _name = TextEditingController(
    text: widget.registration ? '' : widget.profile.name,
  );
  late final _runtime = TextEditingController(
    text: widget.profile.hasRuntimeLimit ? '${widget.profile.maxRunTime}' : '',
  );
  late final _ceiling = TextEditingController(
    text: widget.profile.hasSafetyLimit
        ? '${widget.profile.safetyCeilingDuration}'
        : '',
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _runtime.dispose();
    _ceiling.dispose();
    super.dispose();
  }

  /// Closes this editor even if a safety alert was pushed above it; a plain
  /// pop would dismiss that alert instead.
  void _closeSelf(bool result) {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.pop(context, result);
    } else {
      Navigator.removeRoute(context, route, result);
    }
  }

  Future<void> _save() async {
    if (widget.takenNames.contains(_name.text.trim().toLowerCase())) {
      setState(
        () => _error =
            'An appliance with this name already exists. Please choose a unique name.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!widget.registration) {
        await widget.service.editProfile(
          widget.reading,
          widget.profile,
          _name.text,
          int.tryParse(_runtime.text) ?? 0,
          int.tryParse(_ceiling.text) ?? 0,
        );
      }
      await widget.service.registerProfile(widget.profile, _name.text);
      if (mounted) _closeSelf(true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.registration ? 'Appliance Registration' : 'Edit Appliance Profile',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Outlet ${widget.profile.outlet} · detected signature'),
          SelectableText(
            widget.profile.profileID,
            style: const TextStyle(color: Colors.blue),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Appliance Name',
              border: OutlineInputBorder(),
            ),
          ),
          if (!widget.registration) ...[
            TextField(
              controller: _runtime,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Runtime warning (seconds)',
              ),
            ),
            TextField(
              controller: _ceiling,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Safety ceiling (seconds)',
              ),
            ),
          ],
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? 'Saving…' : 'Save Profile'),
      ),
    ],
  );
}
