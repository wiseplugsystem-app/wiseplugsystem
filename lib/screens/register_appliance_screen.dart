import 'dart:async';

import 'package:flutter/material.dart';

import '../models/recognition.dart';
import '../services/recognition_service.dart';

/// What the registration screen asks the user to do next, decided from the
/// latest run on the chosen outlet.
enum RegistrationStep {
  /// Plug in or switch on the appliance.
  plugIn,

  /// It was already running before registration started: switch it off and
  /// on again, so the plug measures a fresh start.
  restart,

  /// Running; WisePlug is measuring it (Stage 2 comes about a minute in).
  measuring,

  /// Fully measured: record this run as a sample now.
  record,

  /// Recorded; switch it off or unplug it before the next plug-in.
  switchOff,

  /// That run ended before it was fully measured.
  tooShort,
}

/// The guided "plug it in 3 times" flow as a small state machine, without
/// any UI or network (unit-tested). Each run on the outlet counts once.
class RegistrationTracker {
  /// Runs that started before this (minus a little clock tolerance) were
  /// already going when the user opened registration.
  final DateTime startedAt;

  /// A run the user registers straight from a prompt counts even though it
  /// started earlier.
  final String? initialEventId;

  final _used = <String>{};
  String? _lastRecorded;
  bool _waitingForOff = false;

  RegistrationTracker({required this.startedAt, this.initialEventId});

  RegistrationStep next(OutletSession? latest) {
    if (_waitingForOff) {
      // Still the run just recorded, still running: wait for it to stop.
      if (latest != null && latest.eventId == _lastRecorded && latest.isOpen) {
        return RegistrationStep.switchOff;
      }
      _waitingForOff = false;
    }
    final s = latest;
    if (s == null || _used.contains(s.eventId)) return RegistrationStep.plugIn;
    final fresh =
        s.eventId == initialEventId ||
        !s.startedAt.isBefore(startedAt.subtract(const Duration(seconds: 5)));
    if (!fresh) {
      return s.isOpen ? RegistrationStep.restart : RegistrationStep.plugIn;
    }
    if (s.measured) return RegistrationStep.record;
    if (!s.isOpen) {
      _used.add(s.eventId);
      return RegistrationStep.tooShort;
    }
    return RegistrationStep.measuring;
  }

  /// [eventId] became a sample: wait for the appliance to be switched off.
  void recorded(String eventId) {
    _used.add(eventId);
    _lastRecorded = eventId;
    _waitingForOff = true;
  }

  /// [eventId] could not be used (the server refused it): skip it.
  void skip(String eventId) => _used.add(eventId);
}

/// Guided registration, opened from the recognition pop-up: a new appliance
/// (the user gives its type and name), or the remaining plug-ins of one
/// being registered. The safe operating time and the modes are set by the
/// system, never here.
class RegisterApplianceScreen extends StatefulWidget {
  final RecognitionService service;

  /// Continue an appliance still collecting samples; null for a new one.
  final RegisteredAppliance? appliance;

  /// The outlet ('A' / 'B') and the run that led here, if any.
  final String outlet;
  final OutletSession? fromSession;
  final String? typeName, name;
  final RecognitionSettings settings;
  final Duration pollEvery;

  const RegisterApplianceScreen({
    super.key,
    required this.service,
    this.appliance,
    this.outlet = 'A',
    this.fromSession,
    this.typeName,
    this.name,
    this.settings = const RecognitionSettings(),
    this.pollEvery = const Duration(seconds: 2),
  });

  @override
  State<RegisterApplianceScreen> createState() =>
      _RegisterApplianceScreenState();
}

class _RegisterApplianceScreenState extends State<RegisterApplianceScreen> {
  final _form = GlobalKey<FormState>();
  late final _type = TextEditingController(text: widget.typeName ?? '');
  late final _name = TextEditingController(text: widget.name ?? '');
  late String _outlet = widget.fromSession?.outletName ?? widget.outlet;
  List<String> _types = [];

  /// Set once the form is filled in: the samples are being collected.
  RegistrationTracker? _tracker;
  RegistrationStep _step = RegistrationStep.plugIn;
  String? _applianceId;
  String _applianceName = '';
  int _collected = 0;
  bool _complete = false, _busy = false;
  String? _error;
  Timer? _timer;

  bool get _newAppliance => widget.appliance == null;
  int get _required => widget.settings.registrationSamples;

  @override
  void initState() {
    super.initState();
    _applianceId = widget.appliance?.id;
    _applianceName = widget.appliance?.name ?? '';
    if (_newAppliance) {
      widget.service.types().then((t) {
        if (mounted) setState(() => _types = t);
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_type, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  void _start() {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _tracker = RegistrationTracker(
        startedAt: DateTime.now().toUtc(),
        initialEventId: widget.fromSession?.outletName == _outlet
            ? widget.fromSession?.eventId
            : null,
      );
      if (_newAppliance) _applianceName = _name.text.trim();
    });
    _poll();
    _timer = Timer.periodic(widget.pollEvery, (_) => _poll());
  }

  Future<void> _poll() async {
    final tracker = _tracker;
    if (tracker == null || _busy || _complete) return;
    _busy = true;
    try {
      final latest = await widget.service.latestSession(_outlet);
      final step = tracker.next(latest);
      if (step == RegistrationStep.record && latest != null) {
        await _record(tracker, latest);
      } else if (mounted) {
        setState(() => _step = step);
      }
    } catch (_) {
      // Offline for a moment: the next poll tries again.
    } finally {
      _busy = false;
    }
  }

  Future<void> _record(RegistrationTracker tracker, OutletSession run) async {
    try {
      final first = _applianceId == null;
      final progress = await widget.service.registerSample(
        eventId: run.eventId,
        applianceId: _applianceId,
        typeName: first ? _type.text.trim() : null,
        name: first ? _name.text.trim() : null,
      );
      tracker.recorded(run.eventId);
      if (!mounted) return;
      setState(() {
        _applianceId = progress.applianceId;
        _applianceName = progress.applianceName;
        _collected = progress.samplesCollected;
        _complete = progress.complete;
        _step = RegistrationStep.switchOff;
        _error = null;
      });
      if (_complete) _timer?.cancel();
    } catch (error) {
      tracker.skip(run.eventId);
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('Bad state: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _newAppliance ? 'Register appliance' : 'Continue registering';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: _tracker == null ? _formFields() : _progress(),
          ),
        ),
      ),
    );
  }

  List<Widget> _formFields() => [
    Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_newAppliance) ...[
            TextFormField(
              controller: _type,
              decoration: const InputDecoration(
                labelText: 'Type of appliance',
                hintText: 'e.g. Fan, Laptop charger',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Enter a type, e.g. Fan' : null,
            ),
            // The user's existing types: one tap reuses one ("Fan" for Fan 2).
            if (_types.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final t in _types)
                      ActionChip(
                        label: Text(t),
                        onPressed: () => setState(() => _type.text = t),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Bedroom fan',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v ?? '').trim().isEmpty
                  ? 'Give it a name you will recognise'
                  : null,
            ),
            const SizedBox(height: 14),
          ] else
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                widget.appliance!.name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          const SizedBox(height: 18),
          const Text('Which outlet will you use?'),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'A', label: Text('Outlet A')),
              ButtonSegment(value: 'B', label: Text('Outlet B')),
            ],
            selected: {_outlet},
            onSelectionChanged: (s) => setState(() => _outlet = s.first),
          ),
          const SizedBox(height: 18),
          Text(
            'WisePlug learns an appliance by measuring it $_required times. '
            'You will plug it in (or switch it on), let it run for about a '
            'minute, then switch it off, $_required times.',
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 18),
          FilledButton(onPressed: _start, child: const Text('Start')),
        ],
      ),
    ),
  ];

  List<Widget> _progress() {
    final name = _applianceName.isEmpty ? 'the appliance' : _applianceName;
    final sample = (_collected + 1).clamp(1, _required);
    final (icon, text) = _complete
        ? (
            Icons.check_circle,
            '$name is registered. WisePlug will recognise it from now on.',
          )
        : switch (_step) {
            RegistrationStep.plugIn => (
              Icons.power,
              'Plug in or switch on $name on Outlet $_outlet '
                  '(sample $sample of $_required).',
            ),
            RegistrationStep.restart => (
              Icons.restart_alt,
              'It is already running. Switch it off for a few seconds, then on '
                  'again, so WisePlug measures a fresh start.',
            ),
            RegistrationStep.measuring || RegistrationStep.record => (
              Icons.speed,
              'Measuring… keep it running for about a minute '
                  '(sample $sample of $_required).',
            ),
            RegistrationStep.switchOff => (
              Icons.power_off,
              'Sample $_collected of $_required saved. Now switch it off or '
                  'unplug it.',
            ),
            RegistrationStep.tooShort => (
              Icons.timer_off_outlined,
              'That run was too short. Switch it on again and keep it running '
                  'for about a minute.',
            ),
          };
    return [
      Row(
        children: [
          for (var i = 0; i < _required; i++)
            Expanded(
              child: Container(
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i < _collected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '$_collected of $_required samples',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 32),
      Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 16),
      Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 17),
      ),
      if (!_complete && _step == RegistrationStep.measuring) ...[
        const SizedBox(height: 20),
        const LinearProgressIndicator(),
      ],
      if (_error != null) ...[
        const SizedBox(height: 16),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.red),
        ),
      ],
      const SizedBox(height: 28),
      if (_complete)
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Done'),
        )
      else
        TextButton(
          onPressed: () => Navigator.pop(context, _collected > 0),
          child: Text(_collected > 0 ? 'Finish later' : 'Cancel'),
        ),
      if (!_complete && _collected > 0)
        const Text(
          'To continue later, plug it in again and choose it in the pop-up. '
          'Until all samples are saved, WisePlug cannot recognise it yet.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
    ];
  }
}
