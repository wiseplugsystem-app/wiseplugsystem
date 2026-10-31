import 'dart:async';

import 'package:flutter/material.dart';

import '../models/recognition.dart';
import '../services/recognition_service.dart';

/// What the registration pop-up asks the user to do next, decided from the
/// newest run on either outlet.
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

  /// [s] started after registration began (or is the run from the pop-up).
  bool isFresh(OutletSession s) =>
      s.eventId == initialEventId ||
      !s.startedAt.isBefore(startedAt.subtract(const Duration(seconds: 5)));

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
    if (!isFresh(s)) {
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

/// Shows the registration pop-up for the run [fromSession]: WisePlug detected
/// a new appliance. Registration only ever starts here. Returns true when at
/// least one sample was saved.
Future<bool?> showRegistrationDialog(
  BuildContext context, {
  required RecognitionService service,
  OutletSession? fromSession,
  RegisteredAppliance? appliance,
  String? typeName,
  String? name,
  List<RegisteredAppliance> unfinished = const [],
  RecognitionSettings settings = const RecognitionSettings(),
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => RegistrationDialog(
    service: service,
    fromSession: fromSession,
    appliance: appliance,
    typeName: typeName,
    name: name,
    unfinished: unfinished,
    settings: settings,
  ),
);

/// The registration pop-up: "New appliance detected", the type and name
/// (both required), then the guided plug-ins (3 in all; the run that opened
/// the pop-up is the first). It can also continue an appliance whose
/// registration was left unfinished. The safe operating time and the modes
/// are set by the system, never here.
class RegistrationDialog extends StatefulWidget {
  final RecognitionService service;

  /// Continue this appliance (still collecting samples); null for a new one.
  final RegisteredAppliance? appliance;

  /// The run that opened the pop-up, if any. Either outlet can be used:
  /// appliances are portable, so registration watches both.
  final OutletSession? fromSession;
  final String? typeName, name;

  /// Appliances whose registration is unfinished: the new load may be one.
  final List<RegisteredAppliance> unfinished;
  final RecognitionSettings settings;
  final Duration pollEvery;

  const RegistrationDialog({
    super.key,
    required this.service,
    this.appliance,
    this.fromSession,
    this.typeName,
    this.name,
    this.unfinished = const [],
    this.settings = const RecognitionSettings(),
    this.pollEvery = const Duration(seconds: 2),
  });

  @override
  State<RegistrationDialog> createState() => _RegistrationDialogState();
}

class _RegistrationDialogState extends State<RegistrationDialog> {
  final _form = GlobalKey<FormState>();
  late final _type = TextEditingController(text: widget.typeName ?? '');
  late final _name = TextEditingController(text: widget.name ?? '');
  List<String> _types = [];

  /// The appliance being continued (from the widget, or chosen here).
  late RegisteredAppliance? _appliance = widget.appliance;

  /// Set once Register is pressed: the samples are being collected.
  RegistrationTracker? _tracker;
  RegistrationStep _step = RegistrationStep.plugIn;
  String? _applianceId;
  String _applianceName = '';
  int _collected = 0;
  bool _complete = false, _busy = false;
  String? _error;
  Timer? _timer;

  bool get _newAppliance => _appliance == null;
  int get _required => widget.settings.registrationSamples;

  @override
  void initState() {
    super.initState();
    widget.service.types().then((t) {
      if (mounted) setState(() => _types = t);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _type.dispose();
    _name.dispose();
    super.dispose();
  }

  void _start() {
    if (_newAppliance && !_form.currentState!.validate()) return;
    setState(() {
      _applianceId = _appliance?.id;
      _applianceName = _appliance?.name ?? _name.text.trim();
      _collected = _appliance == null
          ? 0
          : _appliance!.modes
                .map((m) => m.sampleCount)
                .fold(_required, (a, b) => a < b ? a : b);
      _tracker = RegistrationTracker(
        startedAt: DateTime.now().toUtc(),
        initialEventId: widget.fromSession?.eventId,
      );
    });
    _poll();
    _timer = Timer.periodic(widget.pollEvery, (_) => _poll());
  }

  Future<void> _poll() async {
    final tracker = _tracker;
    if (tracker == null || _busy || _complete) return;
    _busy = true;
    try {
      // Both outlets: the newest run that started after Register (runs
      // already going on the other outlet belong to other appliances).
      final runs = await Future.wait([
        widget.service.latestSession('A'),
        widget.service.latestSession('B'),
      ]);
      final fresh = [
        for (final r in runs)
          if (r != null && tracker.isFresh(r)) r,
      ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      final latest = fresh.isEmpty ? null : fresh.first;
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
    final outlet = widget.fromSession == null
        ? ''
        : ' on Outlet ${widget.fromSession!.outletName}';
    final title = _newAppliance
        ? 'New appliance detected$outlet'
        : 'Continue registering ${_appliance!.name}';
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.new_releases_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...(_tracker == null ? _formFields() : _progress()),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _formFields() => [
    if (_newAppliance) ...[
      const Text('Register it so WisePlug recognises it next time.'),
      // The new load may be an appliance whose registration was left unfinished.
      for (final a in widget.unfinished)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            onPressed: () => setState(() => _appliance = a),
            child: Text(
              'It is ${a.name}: continue registering '
              '(${a.modes.map((m) => m.sampleCount).fold(_required, (x, y) => x < y ? x : y)} of $_required)',
            ),
          ),
        ),
      const SizedBox(height: 16),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
          ],
        ),
      ),
    ] else
      Text(
        '${_appliance!.name} still needs '
        '${_required - _appliance!.modes.map((m) => m.sampleCount).fold(_required, (x, y) => x < y ? x : y)} '
        'more plug-ins before WisePlug can recognise it.',
      ),
    const SizedBox(height: 14),
    Text(
      'WisePlug learns an appliance by measuring it $_required times: '
      'this run, then you switch it off and on again (either outlet). '
      'Until then it runs on the '
      '${widget.settings.defaultCutoffMinutes}-minute safety limit.',
      style: const TextStyle(color: Colors.grey, fontSize: 13),
    ),
    const SizedBox(height: 18),
    // Side by side when they fit, stacked on a narrow phone.
    OverflowBar(
      alignment: MainAxisAlignment.end,
      overflowAlignment: OverflowBarAlignment.end,
      spacing: 8,
      children: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: _start,
          child: Text(_newAppliance ? 'Register' : 'Continue'),
        ),
      ],
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
              'Plug $name into Outlet A or B, or switch it on. If it is '
                  'already running, switch it off and on again '
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
      const SizedBox(height: 24),
      Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 12),
      Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 16),
      ),
      if (!_complete && _step == RegistrationStep.measuring) ...[
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.red),
        ),
      ],
      const SizedBox(height: 20),
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
          'To continue later, plug it in again: the pop-up will offer it. '
          'Until all samples are saved, WisePlug cannot recognise it yet.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
    ];
  }
}
