import 'esp32_live_view.dart';

import 'package:flutter/material.dart';

import '../models/esp32_data.dart';
import '../services/esp32_service.dart';

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
  @override
  Widget build(BuildContext context) => Esp32LiveView(
    service: _service,
    darkMode: widget.darkMode,
    onDarkModeChanged: widget.onDarkModeChanged,
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
                  'LOCKED OUT — inspect the appliance, then press its physical button to reset.',
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
  const Esp32ProfileEditor({
    super.key,
    required this.service,
    required this.reading,
    required this.profile,
    this.registration = false,
  });
  @override
  State<Esp32ProfileEditor> createState() => Esp32ProfileEditorState();
}

class Esp32ProfileEditorState extends State<Esp32ProfileEditor> {
  late final _name = TextEditingController(text: widget.registration ? '' : widget.profile.name);
  static const types = ['Rice cooker', 'Flat iron / hair straightener', 'Electric fan', 'Other'];
  late String _type = types.contains(widget.profile.applianceType) ? widget.profile.applianceType! : 'Other';
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

  Future<void> _save() async {
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
      await widget.service.registerProfile(widget.profile, _name.text, _type);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.registration ? 'Appliance Registration' : 'Edit Appliance Profile'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Outlet ${widget.profile.outlet} · detected signature'),
          SelectableText(widget.profile.profileID, style: const TextStyle(color: Colors.blue)),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Appliance Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: _type,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Type of Appliance', border: OutlineInputBorder()),
            items: [for (final type in types) DropdownMenuItem(value: type, child: Text(type))],
            onChanged: _busy ? null : (value) => setState(() => _type = value!),
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