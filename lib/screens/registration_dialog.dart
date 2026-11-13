import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

import '../models/appliance_icons.dart';
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

  /// WisePlug recognized this run as a setting the appliance already has
  /// (e.g. the same fan speed again): it is not saved; use another setting.
  alreadyDone,
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

  /// The appliance being registered, once known (after its first sample):
  /// a run WisePlug recognizes as one of its saved settings is a repeat.
  String? applianceId;

  RegistrationTracker({
    required this.startedAt,
    this.initialEventId,
    this.applianceId,
  });

  /// [s] matched a setting [applianceId] already has (alone, or as one of the
  /// appliances it could be).
  bool isRepeat(OutletSession s) =>
      applianceId != null &&
      (s.applianceId == applianceId ||
          s.candidates.any((c) => c.applianceId == applianceId));

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
    // The same setting again (e.g. a fan speed already done): never saved.
    if (isRepeat(s)) {
      if (!s.isOpen) {
        _used.add(s.eventId);
        return RegistrationStep.plugIn;
      }
      return RegistrationStep.alreadyDone;
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

  /// "Other" was picked: the type is typed in.
  late bool _otherType =
      (widget.typeName ?? '').isNotEmpty &&
      !applianceKinds.any(
        (k) => k.label.toLowerCase() == widget.typeName!.toLowerCase(),
      );
  String? _typeError;

  /// The appliance being continued (from the widget, or chosen here).
  late RegisteredAppliance? _appliance = widget.appliance;

  /// Set once Register is pressed: the samples are being collected.
  RegistrationTracker? _tracker;
  RegistrationStep _step = RegistrationStep.plugIn;

  /// When the run being measured started (shown as "On for 35 s").
  DateTime? _measuringSince;
  String? _applianceId;
  String _applianceName = '';
  int _collected = 0;
  bool _complete = false, _busy = false;
  String? _error;
  Timer? _timer;

  /// The saved setting the current run repeats (RegistrationStep.alreadyDone).
  String? _repeatMode;

  /// A fan's number of speeds (1 to 4).
  int _speeds = 3;

  /// An "Other" appliance's own settings, after its first one.
  final _extraLevels = <String>[];

  /// The setting the next sample is for (null: the old 3-sample way).
  String? _level;

  bool get _newAppliance => _appliance == null;
  int get _legacy => widget.settings.registrationSamples;

  /// What is being added, from the picture chosen or the words typed.
  ApplianceKind get _kind => kindForType(_type.text.trim());

  /// The settings to sample, in order: the type's ("Speed 1", "Speed 2"…),
  /// or, for one being finished, the ones it was registered with.
  List<String> get _levels => _newAppliance
      ? [...levelsFor(_kind, speeds: _speeds), ..._extraLevels]
      : [for (final m in _appliance!.levels) m.name];

  /// Samples in all: one for each setting (samples_per_level); a charger
  /// samples_per_charger, since its power changes with the battery.
  int get _required => _newAppliance
      ? _levels.length *
            (_isCharger(_kind)
                ? widget.settings.samplesPerCharger
                : widget.settings.samplesPerLevel)
      : _appliance!.samplesNeeded(_legacy);

  static bool _isCharger(ApplianceKind k) =>
      k.key == 'laptop_charger' || k.key == 'phone_charger';

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
    if (_newAppliance) {
      final noType = _type.text.trim().isEmpty;
      // "Other" typed as an aircon is refused too.
      final tooBig = unsupportedKinds.contains(kindForType(_type.text).key);
      setState(
        () => _typeError = noType
            ? 'Choose what you are adding.'
            : tooBig
            ? 'WisePlug cannot power this: it needs more than '
                  '$maxApplianceText.'
            : null,
      );
      if (!_form.currentState!.validate() || noType || tooBig) return;
    }
    setState(() {
      _applianceId = _appliance?.id;
      _applianceName = _appliance?.name ?? _name.text.trim();
      _collected = _appliance == null ? 0 : _appliance!.samplesDone(_legacy);
      _level = _newAppliance ? _levels.first : _appliance!.nextLevel;
      _tracker = RegistrationTracker(
        startedAt: DateTime.now().toUtc(),
        initialEventId: widget.fromSession?.eventId,
        applianceId: _appliance?.id,
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
        setState(() {
          _step = step;
          _repeatMode = step == RegistrationStep.alreadyDone
              ? latest?.modeName
              : null;
          _measuringSince = step == RegistrationStep.measuring
              ? latest?.startedAt
              : null;
        });
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
        // Its type's icon (lib/models/appliance_icons.dart).
        iconKey: first ? kindForType(_type.text.trim()).key : null,
        levels: first ? _levels : null,
        level: _level,
      );
      tracker.recorded(run.eventId);
      tracker.applianceId = progress.applianceId;
      if (!mounted) return;
      setState(() {
        _applianceId = progress.applianceId;
        _applianceName = progress.applianceName;
        _collected = progress.samplesCollected;
        _complete = progress.complete;
        _level = progress.nextLevel;
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
        ? 'Something new$outlet'
        : 'Finish adding ${_appliance!.name}';
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        // The form scrolls; Not now / Register stay in view at the bottom.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        // A new load: a question mark; continuing: what it is.
                        ApplianceIcon(
                          _newAppliance ? unknownKind : _appliance!.kind,
                          size: 24,
                          label: title,
                        ),
                        const SizedBox(width: 12),
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
            if (_tracker == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
                child: _formActions(),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _formFields() => [
    if (_newAppliance) ...[
      const Text('Tell WisePlug what it is, so it knows it next time.'),
      // The new load may be an appliance whose registration was left unfinished.
      for (final a in widget.unfinished)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            onPressed: () => setState(() => _appliance = a),
            child: Text(
              'It is ${a.name}: continue '
              '(${a.samplesDone(_legacy)} of ${a.samplesNeeded(_legacy)} done)',
            ),
          ),
        ),
      const SizedBox(height: 16),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'What are you adding?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            // The hardware's limit, before the user picks.
            Text(
              'Up to $maxApplianceText: check the label on the appliance.',
              style: TextStyle(fontSize: 16, color: context.muted),
            ),
            const SizedBox(height: 10),
            // Every standard appliance, then the user's own types, then
            // Other: cards of one size, in even columns.
            _typeGrid([
              for (final k in applianceKinds)
                if (canAdd(k)) _typeTile(k.label, k),
              for (final t in _types)
                if (!applianceKinds.any(
                  (k) => k.label.toLowerCase() == t.toLowerCase(),
                ))
                  _typeTile(t, kindForType(t)),
              _typeTile(otherKind.label, otherKind, other: true),
            ]),
            if (_typeError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _typeError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_otherType) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _type,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'What is it?',
                  hintText: 'e.g. Electric grill',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'Write what it is, e.g. Electric grill'
                    : null,
              ),
            ],
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
            ..._levelsSection(),
          ],
        ),
      ),
    ] else
      Text(
        'Turn ${_appliance!.name} on and off '
        '${_required - _appliance!.samplesDone(_legacy)} more '
        '${_required - _appliance!.samplesDone(_legacy) == 1 ? 'time' : 'times'}, '
        'so WisePlug knows it.',
      ),
    const SizedBox(height: 14),
    ..._howItWorks(),
  ];

  /// The whole job in three short steps, the same for everyone.
  List<Widget> _howItWorks() {
    Widget step(int n, IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
            child: Text(
              '$n',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 16))),
        ],
      ),
    );
    return [
      const Text(
        'How it works:',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      step(1, Icons.power, 'Turn it on.'),
      step(
        2,
        Icons.timer_outlined,
        'Leave it on for about 1 minute. Don\'t touch the buttons.',
      ),
      step(3, Icons.power_off, 'Turn it off.'),
      const SizedBox(height: 10),
      Text(
        _required == 1
            ? 'Do this 1 time.'
            : _levels.length > 1
            ? _levels.every(_isSpeed)
                  ? 'Do this $_required times, a different speed each time '
                        '(any order).'
                  : 'Do this $_required times, one time for each setting:'
            : 'Do this $_required times.',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      if (_levels.length > 1 && !_levels.every(_isSpeed)) ...[
        const SizedBox(height: 4),
        Text(_levels.join('  →  '), style: const TextStyle(fontSize: 16)),
      ],
      const SizedBox(height: 4),
      Text(
        'Outlet A or B, both work.',
        style: TextStyle(color: context.muted, fontSize: 16),
      ),
      const SizedBox(height: 6),
      Text(
        'Until then, WisePlug turns it off after '
        '${widget.settings.defaultCutoffMinutes} minutes to keep you safe.',
        style: TextStyle(color: context.muted, fontSize: 16),
      ),
    ];
  }

  // Side by side when they fit, stacked on a narrow phone.
  Widget _formActions() => OverflowBar(
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
  );

  /// One choice of the "What are you adding?" grid: its icon (48 dp) with
  /// its name under it.
  Widget _typeTile(String label, ApplianceKind kind, {bool other = false}) {
    final selected = other
        ? _otherType
        : !_otherType && _type.text.trim().toLowerCase() == label.toLowerCase();
    final scheme = Theme.of(context).colorScheme;
    // Its usual power, so the user can compare it with the limit.
    final watts = other ? null : wattRangeText(kind.key);
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() {
          _typeError = null;
          _otherType = other;
          _type.text = other ? '' : label;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : Colors.grey.withValues(alpha: .35),
              width: selected ? 2.5 : 1,
            ),
          ),
          // The same room on every card: two lines for the name, one for
          // the power, so all cards line up.
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ApplianceIcon(kind, size: 48, label: label),
              const SizedBox(height: 6),
              SizedBox(
                height: _lines(context, 16, 2),
                child: Center(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: _lines(context, 14, 1),
                child: Text(
                  watts ?? (other ? 'Write its name' : ''),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.2,
                    color: context.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Height of [count] lines of [size] text at the phone's text size.
  static double _lines(BuildContext context, double size, int count) =>
      MediaQuery.textScalerOf(context).scale(size) * 1.2 * count + 2;

  /// The cards in even columns (2 on a phone, 3 on a wider screen), every
  /// card the same width, and each row as tall as its tallest card.
  Widget _typeGrid(List<Widget> cards) => LayoutBuilder(
    builder: (context, box) {
      // 2 on a phone (room for "1,000–1,500 W"), 3 on a wider screen.
      final columns = box.maxWidth >= 420 ? 3 : 2;
      return Column(
        children: [
          for (var i = 0; i < cards.length; i += columns)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = i; j < i + columns; j++) ...[
                      if (j > i) const SizedBox(width: 8),
                      Expanded(
                        child: j < cards.length
                            ? cards[j]
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  /// A fan's speeds are saved as "Level 1", "Level 2"…, but users may not
  /// know which button is which: they do them in any order, a different
  /// speed each time (the samples all belong to the same fan).
  static bool _isSpeed(String? level) => level?.startsWith('Level ') ?? false;

  /// What to do for sample [sample] at [level]. A charger draws more on a
  /// low battery and less when nearly full, so each of its samples asks for
  /// a different battery level and WisePlug learns all its speeds.
  String _levelHint(String? level, int sample) => switch (level) {
    null || 'Normal' => '',
    _ when _isSpeed(level) =>
      sample == 1 ? 'Use any speed. ' : 'Use a speed you have NOT done yet. ',
    // One sample (samples_per_charger = 1): just charge with it.
    'Charging' when widget.settings.samplesPerCharger <= 1 =>
      'Charge a laptop or phone with it. ',
    'Charging' => switch (sample) {
      1 => 'Charge a phone or laptop whose battery is LOW (under 30%). ',
      2 => 'Charge it when the battery is about HALF full (40–60%). ',
      3 => 'Charge it when the battery is NEARLY FULL (over 80%). ',
      _ => 'Charge a phone or laptop with it (any battery level). ',
    },
    'Heating' => 'Set the dial to any setting and let it heat up. ',
    _ => 'Set it to $level. ',
  };

  /// The settings WisePlug will take a sample of: a fan's number of speeds
  /// can be chosen, and an "Other" appliance can get more settings.
  List<Widget> _levelsSection() {
    if (_type.text.trim().isEmpty && !_otherType) return const [];
    final kind = _kind;
    final fan = kind.key == 'fan';
    final charger = kind.key == 'laptop_charger' || kind.key == 'phone_charger';
    final canAddMore = kind == otherKind && _levels.length < maxLevels;
    return [
      const SizedBox(height: 16),
      Text(
        fan ? 'How many speeds does your fan have?' : 'Its settings:',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      if (fan)
        Wrap(
          spacing: 8,
          children: [
            for (var n = 1; n <= 4; n++)
              ChoiceChip(
                label: Text('$n'),
                selected: _speeds == n,
                onSelected: (_) => setState(() => _speeds = n),
              ),
          ],
        ),
      if (fan)
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          child: Text(
            'Count its speed buttons. You will turn it on once at each '
            'speed, in any order.',
            style: TextStyle(color: context.muted, fontSize: 16),
          ),
        ),
      // A fan's speeds are just counted above (no "Level 1/2/3" to match).
      if (!fan)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final l in _levels)
              Chip(
                label: Text(l),
                onDeleted: _extraLevels.contains(l)
                    ? () => setState(() => _extraLevels.remove(l))
                    : null,
              ),
          ],
        ),
      if (charger && widget.settings.samplesPerCharger > 1)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'A charger uses more power when the battery is low and less when '
            'it is nearly full, so WisePlug takes '
            '${widget.settings.samplesPerCharger} samples: one with the '
            'battery low, one about half full, and one nearly full.',
            style: TextStyle(color: context.muted, fontSize: 16),
          ),
        ),
      if (canAddMore)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addLevel,
            icon: const Icon(Icons.add),
            label: const Text('Add another setting'),
          ),
        ),
    ];
  }

  /// "Other": the user names one more setting (e.g. High).
  Future<void> _addLevel() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _AddLevelDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;
    if (_levels.any((l) => l.toLowerCase() == name.toLowerCase())) return;
    setState(() => _extraLevels.add(name));
  }

  /// After a step, what the next one is: "Then turn it on at a different
  /// speed." / "Then turn it on again: set it to Keep warm."
  String _nextHint(String? next, int sample) => switch (next) {
    null => '',
    _ when _isSpeed(next) => 'Then turn it on at a DIFFERENT speed. ',
    'Normal' || 'Heating' => 'Then turn it on again. ',
    'Charging' => 'Then charge again: ${_levelHint(next, sample)}',
    _ => 'Then turn it on again and set it to $next. ',
  };

  /// " (about 33 W)": the power of the saved setting this run repeated, when
  /// the app has it (an appliance being continued); else nothing.
  String _repeatWatts() {
    final mode = _repeatMode;
    final w = mode == null
        ? null
        : _appliance?.modes
              .where((m) => m.name == mode)
              .firstOrNull
              ?.meanPowerW;
    return w == null ? '' : ' (about ${w.round()} W)';
  }

  /// "the fan" -> "The fan", at the start of a sentence.
  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  List<Widget> _progress() {
    final name = _applianceName.isEmpty ? 'the appliance' : _applianceName;
    final sample = (_collected + 1).clamp(1, _required);
    final (icon, text) = _complete
        ? (Icons.check_circle, 'All done! WisePlug knows $name now.')
        : switch (_step) {
            RegistrationStep.plugIn => (
              Icons.power,
              'Step $sample of $_required: Turn $name on. '
                  '${_levelHint(_level, sample)}',
            ),
            RegistrationStep.restart => (
              Icons.restart_alt,
              '${_cap(name)} is already on. Turn it off, count to 5, then turn '
                  'it on again${_isSpeed(_level) ? ' at a speed you have NOT done yet' : ''}.',
            ),
            RegistrationStep.measuring => (
              Icons.hourglass_top,
              'Please wait about 1 minute. Leave it on and don\'t touch its '
                  'buttons. WisePlug is learning it (step $sample of '
                  '$_required).',
            ),
            RegistrationStep.record => (
              Icons.save_outlined,
              'Saving… please wait a few seconds.',
            ),
            RegistrationStep.switchOff => (
              Icons.power_off,
              'Step $_collected of $_required done! Now turn $name off and '
                  'wait 5 seconds. ${_nextHint(_level, _collected + 1)}'
                  'You will wait about 1 minute again.',
            ),
            RegistrationStep.alreadyDone => (
              Icons.replay,
              'That ${_isSpeed(_level) ? 'speed' : 'setting'} is already '
                  'saved${_repeatWatts()}. It will not be saved again. Turn '
                  '$name off, wait 5 seconds, then turn it on at a DIFFERENT '
                  '${_isSpeed(_level) ? 'speed' : 'setting'}.',
            ),
            RegistrationStep.tooShort => (
              Icons.timer_off_outlined,
              'That was too short. Turn it on again and leave it on for '
                  'about 1 minute.',
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
        '$_collected of $_required done',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.muted),
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
        if (_measuringSince case final since?) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final s = DateTime.now()
                  .difference(since)
                  .inSeconds
                  .clamp(0, 9999);
              return Text(
                // Over 2 minutes: the measurement is not getting through.
                s > 120
                    ? 'On for ${s ~/ 60} min ${s % 60} s. This is taking '
                          'longer than usual: check that the WisePlug is '
                          'online.'
                    : 'On for $s s of about 60 s',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: context.muted),
              );
            },
          ),
        ],
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.readable(Colors.red)),
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
        Text(
          'You can finish later. Just turn it on again and WisePlug will ask '
          'you. WisePlug knows it only after all $_required.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: context.muted),
        ),
    ];
  }
}

/// Asks for the name of one more setting. It owns its text field, so the
/// field lives until the dialog has finished closing.
class _AddLevelDialog extends StatefulWidget {
  const _AddLevelDialog();
  @override
  State<_AddLevelDialog> createState() => _AddLevelDialogState();
}

class _AddLevelDialogState extends State<_AddLevelDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Another setting'),
    content: TextField(
      controller: _text,
      autofocus: true,
      maxLength: 40,
      decoration: const InputDecoration(
        labelText: 'Its name',
        hintText: 'e.g. High',
        border: OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text.trim()),
        child: const Text('Add'),
      ),
    ],
  );
}
