import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/esp32_data.dart';
import '../services/esp32_service.dart';
import 'esp32_dashboard.dart';

const _blue = Color(0xFF00A4EF);
const _green = Color(0xFF00B744);
const _amber = Color(0xFFF5B800);
const _safetyNote =
    'Software monitoring only. Disabled and locked states do not disconnect electrical power. Unplug an unsafe appliance; a locked outlet requires its physical button to reset.';

String _duration(int? seconds) {
  if (seconds == null) return 'Not available';
  if (seconds <= 0) return '0 s';
  if (seconds < 60) return '$seconds s';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} h';
  return '${(seconds / 60).ceil()} min';
}

/// Prefer firmware identity. Legacy names are usable only when unambiguous.
LearnedAppliance? connectedProfile(
  OutletReading? reading,
  List<LearnedAppliance> profiles,
) {
  if (reading == null) return null;
  final matches = profiles.where(
    (p) =>
        p.outlet == reading.outlet &&
        (reading.profileID.isNotEmpty
            ? p.profileID == reading.profileID
            : p.firmwareName == reading.appliance ||
                  p.profileID == reading.appliance ||
                  p.name == reading.appliance),
  );
  return matches.length == 1 ? matches.single : null;
}

String profileStatus(
  LearnedAppliance profile,
  OutletReading? reading,
  List<LearnedAppliance> profiles,
  DateTime now,
) {
  if (reading == null || !reading.isFresh(now)) return 'Offline';
  if (reading.sensorValid == false) return 'Unavailable';
  if (!reading.hasConnectedAppliance(now)) return _status(reading, now);
  if (connectedProfile(reading, profiles)?.profileID != profile.profileID) {
    if (reading.profileID.isEmpty &&
        reading.isActive &&
        connectedProfile(reading, profiles) == null) {
      return 'Unknown';
    }
    return 'Idle';
  }
  return _status(reading, now);
}

String _status(OutletReading? reading, DateTime now) {
  if (reading == null) return 'Waiting';
  if (!reading.isFresh(now)) return 'Offline';
  if (reading.isLockedOut) return 'Locked out';
  if (reading.isWarning) return 'Safety warning';
  if (reading.sensorValid == false) return 'Unavailable';
  if (reading.currentState == 'DISABLED') return 'Disabled';
  if (reading.currentState == 'SAMPLING') return 'Recognizing';
  if (reading.runtimeWarning) return 'Near limit';
  return reading.isActive ? 'Active' : 'Idle';
}

Color _statusColor(String status) => switch (status) {
  'Active' => _green,
  'Near limit' || 'Recognizing' => _amber,
  'Locked out' || 'Safety warning' => Colors.red,
  _ => Colors.grey,
};

class Esp32LiveView extends StatefulWidget {
  final Esp32Service service;
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;
  const Esp32LiveView({
    super.key,
    required this.service,
    required this.darkMode,
    required this.onDarkModeChanged,
  });
  @override
  State<Esp32LiveView> createState() => _Esp32LiveViewState();
}

class _Esp32LiveViewState extends State<Esp32LiveView> {
  final _updates = ValueNotifier<int>(0);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Map<String, OutletReading> _readings = {};
  List<LearnedAppliance> _profiles = [];
  Map<String, dynamic> _preferences = {};
  bool _readError = false,
      _profileError = false,
      _loading = true,
      _profilesLoading = true;
  bool _preferencesReady = false, _saving = false;
  String? _settingsError;
  String? _telemetryFailure, _catalogFailure;
  String _version = 'Loading…';
  int _tab = 0;
  String _filter = 'All';
  Timer? _clock;
  final _promptedUses = <String>{};
  final _shownWarnings = <String>{};
  bool _registrationOpen = false, _warningOpen = false;

  String _useKey(OutletReading r) =>
      '${r.outlet}/${r.sessionID}/${r.profileID}/${r.startTime?.millisecondsSinceEpoch}';

  void _checkPopups() {
    if (!mounted || _loading || _readError) return;
    final now = DateTime.now();
    for (final r in _readings.values) {
      final key = '${r.outlet}/${r.alertID}';
      if (!_warningOpen &&
          r.isFresh(now) &&
          r.isWarning &&
          r.alertID.isNotEmpty &&
          !_shownWarnings.contains(key)) {
        _shownWarnings.add(key);
        _showWarning(r);
        return;
      }
    }
    if (_warningOpen ||
        _registrationOpen ||
        _profilesLoading ||
        _profileError) {
      return;
    }
    for (final r in _readings.values) {
      final p = connectedProfile(r, _profiles);
      if (r.hasConnectedAppliance(now) &&
          !r.isWarning &&
          p != null &&
          p.needsRegistration &&
          _promptedUses.add(_useKey(r))) {
        _register(r, p);
        return;
      }
    }
  }

  Future<void> _register(
    OutletReading reading,
    LearnedAppliance profile,
  ) async {
    if (_registrationOpen) return;
    _registrationOpen = true;
    try {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'New Appliance Detected',
                  style: TextStyle(color: Colors.redAccent, fontSize: 19),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Do you want to register this appliance?'),
                const SizedBox(height: 8),
                Text('Detected on Outlet ${reading.outlet}'),
                if (!profile.registrationMetadataAvailable)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Saved registration could not be checked. If saving fails, check your connection and Firebase registration permissions.',
                    ),
                  ),
                const SizedBox(height: 20),
                _Panel(
                  child: Column(
                    children: [
                      _Pair('Outlet', reading.outlet),
                      _Pair(
                        'Power draw',
                        measurement(reading.activePower, 'W'),
                      ),
                      _Pair('Signature', profile.profileID, color: _blue),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No, Disregard'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes, Register'),
            ),
          ],
        ),
      );
      if (yes == true && mounted) {
        final saved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => Esp32ProfileEditor(
            service: widget.service,
            reading: reading,
            profile: profile,
            registration: true,
          ),
        );
        if (saved == true && mounted) {
          setState(() => _tab = 1);
        }
      }
    } finally {
      _registrationOpen = false;
    }
  }

  Future<void> _showWarning(OutletReading initial) async {
    _warningOpen = true;
    var busy = false;
    String? error;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AnimatedBuilder(
            animation: _updates,
            builder: (context, _) {
              final r = _readings[initial.outlet];
              final now = DateTime.now();
              final current =
                  !_readError &&
                  r != null &&
                  r.isFresh(now) &&
                  r.alertID == initial.alertID;
              final warning = current && r.isWarning;
              return AlertDialog(
                content: SizedBox(
                  width: 340,
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
                      const SizedBox(height: 16),
                      Text(
                        'Outlet ${initial.outlet} · ${connectedProfile(initial, _profiles)?.name ?? initial.appliance}',
                      ),
                      Text(
                        current
                            ? '${warning ? r.secondsRemaining(now) : 0}'
                            : '—',
                        style: const TextStyle(fontSize: 58),
                      ),
                      const Text('Seconds Remaining'),
                      const SizedBox(height: 16),
                      Text(
                        !current
                            ? 'Live device state unavailable.'
                            : warning
                            ? 'Are you still using the Appliance?'
                            : r.isLockedOut
                            ? 'Outlet locked. Use its physical reset button.'
                            : 'This warning has ended.',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        _safetyNote,
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      if (error != null)
                        Text(error!, style: const TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
                actions: [
                  if (warning) ...[
                    FilledButton(
                      onPressed: busy || !r.canCommand(now)
                          ? null
                          : () async {
                              update(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                await widget.service.command(r, 'TURN_OFF');
                              } catch (e) {
                                if (dialogContext.mounted) {
                                  update(() => error = '$e');
                                }
                              } finally {
                                if (dialogContext.mounted) {
                                  update(() => busy = false);
                                }
                              }
                            },
                      child: Text(busy ? 'Waiting…' : 'Turn Off Now'),
                    ),
                    const Tooltip(
                      message: 'Average-usage override is not implemented yet.',
                      child: FilledButton(
                        onPressed: null,
                        child: Text('Yes, Override'),
                      ),
                    ),
                  ],
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(dialogContext),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          ),
        ),
      );
    } finally {
      _warningOpen = false;
    }
  }

  bool _enabled(String key) => _preferences[key] != false;

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    _updates.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPopups());
  }

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      widget.service.streamOutlets().listen(
        (value) {
          // Legacy firmware may reuse the same name and omit session/start time.
          // A confirmed idle reading ends that use so reconnection can prompt.
          for (final r in value.values) {
            if (r.isFresh(DateTime.now()) &&
                r.sensorValid != false &&
                (r.currentState == 'IDLE' ||
                    (r.currentState.isEmpty &&
                        r.status.toLowerCase() == 'idle'))) {
              _promptedUses.removeWhere(
                (key) => key.startsWith('${r.outlet}/'),
              );
            }
          }
          if (!_loading &&
              !_readError &&
              _preferencesReady &&
              _enabled('deviceAlerts')) {
            for (final entry in value.entries) {
              final old = _readings[entry.key];
              final next = entry.value;
              if (old != null &&
                  next.isFresh(DateTime.now()) &&
                  old.currentState != next.currentState) {
                final safety = next.isWarning || next.isLockedOut;
                if (_enabled(safety ? 'safetyWarnings' : 'statusChanges')) {
                  _notify(
                    'Outlet ${entry.key}: ${_status(next, DateTime.now())}',
                  );
                }
              }
            }
          }
          _readings = value;
          _readError = false;
          _telemetryFailure = null;
          _loading = false;
          _refresh();
        },
        onError: (Object error) {
          _readError = true;
          _telemetryFailure = error.toString();
          _loading = false;
          _refresh();
        },
      ),
    );
    _subscriptions.add(
      widget.service.streamProfiles().listen(
        (value) {
          if (!_profilesLoading &&
              !_profileError &&
              _preferencesReady &&
              _enabled('deviceAlerts') &&
              _enabled('newDevices')) {
            final previous = _profiles
                .map((p) => '${p.outlet}/${p.profileID}')
                .toSet();
            for (final p in value) {
              if (!previous.contains('${p.outlet}/${p.profileID}')) {
                _notify('New appliance: ${p.name}');
              }
            }
          }
          _profiles = value;
          _profileError = false;
          _catalogFailure = null;
          _profilesLoading = false;
          _refresh();
        },
        onError: (Object error) {
          _profileError = true;
          _catalogFailure = error.toString();
          _profilesLoading = false;
          _refresh();
        },
      ),
    );
    _subscriptions.add(
      widget.service.streamPreferences().listen(
        (value) {
          _preferences = value;
          _preferencesReady = true;
          _settingsError = null;
          _refresh();
        },
        onError: (Object error) {
          _preferencesReady = false;
          _settingsError = 'Cannot load alert settings. Check your connection and account permissions.';
          _refresh();
        },
      ),
    );
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final manifest = await rootBundle.loadString('pubspec.yaml');
      _version =
          RegExp(
            r'^version:\s*(\S+)',
            multiLine: true,
          ).firstMatch(manifest)?.group(1) ??
          'Not available';
    } catch (_) {
      _version = 'Not available';
    }
    _refresh();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save(Map<String, bool> values) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.service.savePreferences(values);
      _preferences = {..._preferences, ...values};
      _settingsError = null;
    } catch (_) {
      _settingsError = 'Settings were not saved. Check your connection and account permissions.';
    } finally {
      _saving = false;
      _refresh();
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _updates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(primary: _blue),
        cardTheme: CardThemeData(
          elevation: 0,
          color: widget.darkMode ? const Color(0xFF20252C) : Colors.white,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: widget.darkMode ? Colors.white12 : const Color(0xFFE4E6E8),
            ),
          ),
        ),
      ),
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: ListView(
                padding: const EdgeInsets.all(22),
                children: [
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _tab == 0
                            ? const Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(text: 'Wise'),
                                    TextSpan(
                                      text: 'Plug',
                                      style: TextStyle(color: _blue),
                                    ),
                                  ],
                                ),
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w900,
                                ),
                              )
                            : Text(
                                _tab == 1 ? 'Appliance Profiles' : 'Settings',
                                style: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                      ),
                      if (_tab == 0) ...[
                        IconButton(
                          tooltip: 'Device alerts',
                          icon: const Icon(Icons.notifications_none),
                          onPressed: _showAlerts,
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: () => setState(() => _tab = 2),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 28),
                  if (_tab != 2 && (_loading || _profilesLoading))
                    const LinearProgressIndicator(),
                  if (_tab != 2 && _readError)
                    _Panel(
                      child: Text(
                        'Cannot load ESP32 readings (telemetry_logs). $_telemetryFailure',
                      ),
                    ),
                  if (_tab != 2 && _profileError)
                    _Panel(
                      child: Text(
                        'Cannot load appliance profiles (appliance_profiles). $_catalogFailure',
                      ),
                    ),
                  if (_tab != 2 &&
                      _profiles.any((p) => !p.registrationMetadataAvailable))
                    const _Panel(
                      child: Text(
                        'Registration data is unavailable. Showing the ESP32 catalog. Check the connection and deploy the updated Firebase rules to load saved names and register appliances.',
                      ),
                    ),
                  if (_tab == 0) ..._home(now),
                  if (_tab == 1) ..._profileList(now),
                  if (_tab == 2) ..._settings(now),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          indicatorColor: _blue.withValues(alpha: .16),
          onDestinationSelected: (value) => setState(() => _tab = value),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: _blue),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person, color: _blue),
              label: 'Profiles',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings, color: _blue),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _home(DateTime now) {
    final complete =
        !_readError &&
        ['A', 'B'].every(
          (key) =>
              _readings[key]?.isFresh(now) == true &&
              _readings[key]?.sensorValid != false &&
              _readings[key]?.activePower != null,
        );
    final total = complete
        ? _readings['A']!.activePower! + _readings['B']!.activePower!
        : null;
    return [
      if (!_loading && !_readError && _readings.isEmpty)
        const _Panel(
          child: Text(
            'No outlet readings found. The ESP32 must publish telemetry_logs/outlet_A and outlet_B to this app’s database.',
          ),
        ),
      Text(
        complete
            ? 'CURRENTLY CONNECTED — DUAL OUTLET'
            : 'WAITING FOR LIVE OUTLET READINGS',
        style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 20),
      LayoutBuilder(
        builder: (context, constraints) {
          final cards = [
            for (final key in ['A', 'B']) _summary(key, now),
          ];
          return constraints.maxWidth >= 340
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 16),
                    Expanded(child: cards[1]),
                  ],
                )
              : Column(
                  children: [cards[0], const SizedBox(height: 16), cards[1]],
                );
        },
      ),
      const SizedBox(height: 24),
      Row(
        children: [
          Expanded(child: _metric(measurement(total, 'W', 0), 'Total draw')),
          const SizedBox(width: 16),
          Expanded(
            child: _metric(
              complete
                  ? '${_readings.values.where((r) => r.isActive).length} / 2'
                  : '— / 2',
              'Outlets active',
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Power Control',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            for (final key in ['A', 'B'])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PowerControl(
                  service: widget.service,
                  reading: _readError ? null : _readings[key],
                  outlet: key,
                  now: now,
                ),
              ),
            const Text(
              _safetyNote,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _summary(String key, DateTime now) {
    final reading = _readings[key];
    final connected =
        !_readError && reading?.hasConnectedAppliance(now) == true;
    final profile = _profileError || !connected
        ? null
        : connectedProfile(reading, _profiles);
    final status = _readError ? 'Offline' : _status(reading, now);
    final color = _statusColor(status);
    final fresh = !_readError && reading?.isFresh(now) == true;
    final seconds = fresh && reading!.isActive && reading.safetyDeadline != null
        ? reading.safetyDeadline!.difference(now).inSeconds.clamp(0, 604800)
        : null;
    final limit = profile?.hasSafetyLimit == true
        ? profile!.safetyCeilingDuration
        : null;
    final start = connected ? reading?.startTime?.toLocal() : null;
    return _Panel(
      border: color,
      padding: 15,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Outlet $key',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Icon(Icons.circle, size: 9, color: color),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            connected
                ? profile?.name ?? reading!.appliance
                : fresh
                ? 'No appliance detected'
                : 'Waiting for device',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            profile?.applianceType ?? status,
            style: TextStyle(color: color),
          ),
          const SizedBox(height: 20),
          _Pair(
            'Power draw',
            measurement(
              fresh && reading?.sensorValid != false
                  ? reading?.activePower
                  : null,
              'W',
            ),
          ),
          Text(
            reading == null
                ? 'No reading received for this outlet.'
                : reading.lastUpdated == null
                ? 'Received a reading without a valid device timestamp.'
                : 'Device updated: ${reading.lastUpdated!.toLocal()}${fresh ? '' : ' · stale or clock mismatch'}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          _Pair(
            'Start',
            start == null
                ? '—'
                : '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}',
          ),
          _Pair('Safety limit', limit == null ? '—' : _duration(limit)),
          _Pair(
            'Remaining',
            seconds == null ? '—' : _duration(seconds),
            color: color,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: seconds != null && limit != null
                ? (1 - seconds / limit).clamp(0.0, 1.0)
                : 0,
            color: color,
            backgroundColor: Colors.grey.withValues(alpha: .15),
          ),
          if (!fresh)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Live data unavailable',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }

  Widget _metric(String value, String label) => _Panel(
    child: Column(
      children: [
        FittedBox(
          child: Text(
            value,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.grey)),
      ],
    ),
  );

  List<Widget> _profileList(DateTime now) {
    final profiles = _profiles.where((p) {
      final status = _readError
          ? 'Offline'
          : profileStatus(p, _readings[p.outlet], _profiles, now);
      return _filter == 'All' ||
          (_filter == 'Active'
              ? ['Active', 'Near limit', 'Safety warning'].contains(status)
              : status == 'Idle');
    }).toList();
    return [
      Wrap(
        spacing: 12,
        children: [
          for (final filter in ['All', 'Active', 'Idle'])
            ChoiceChip(
              label: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: Text(filter),
              ),
              selected: _filter == filter,
              selectedColor: _blue,
              labelStyle: TextStyle(
                color: _filter == filter ? Colors.white : null,
                fontWeight: FontWeight.bold,
              ),
              showCheckmark: false,
              onSelected: (_) => setState(() => _filter = filter),
            ),
        ],
      ),
      const SizedBox(height: 20),
      if (profiles.isEmpty && !_profilesLoading && !_profileError)
        _Panel(
          child: Text(
            _profiles.isEmpty
                ? 'No appliance signatures received yet. Turn on an appliance to detect and register it.'
                : 'No appliances match this filter.',
          ),
        ),
      if (profiles.isNotEmpty)
        _Panel(
          padding: 0,
          child: Column(
            children: [
              for (final profile in profiles) ...[
                if (profile != profiles.first)
                  const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: Icon(
                    Icons.circle,
                    size: 9,
                    color: _statusColor(
                      profileStatus(
                        profile,
                        _readings[profile.outlet],
                        _profiles,
                        now,
                      ),
                    ),
                  ),
                  title: Text(
                    profile.needsRegistration
                        ? 'Unregistered appliance'
                        : profile.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '${profile.applianceType ?? 'Appliance'} · Outlet ${profile.outlet}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Badge(
                        profile.needsRegistration
                            ? 'Register'
                            : _readError
                            ? 'Offline'
                            : profileStatus(
                                profile,
                                _readings[profile.outlet],
                                _profiles,
                                now,
                              ),
                      ),
                      const Icon(Icons.chevron_right, color: Colors.grey),
                    ],
                  ),
                  onTap: !profile.registrationMetadataAvailable
                      ? null
                      : () {
                          final reading = _readings[profile.outlet];
                          if (profile.needsRegistration && reading != null) {
                            _register(reading, profile);
                          } else {
                            _showProfile(profile);
                          }
                        },
                ),
              ],
            ],
          ),
        ),
    ];
  }

  void _showProfile(LearnedAppliance selected) {
    showDialog<void>(
      context: context,
      builder: (_) => AnimatedBuilder(
        animation: _updates,
        builder: (context, _) {
          final candidates = _profiles.where(
            (p) =>
                p.outlet == selected.outlet &&
                p.profileID == selected.profileID,
          );
          if (candidates.isEmpty) {
            return AlertDialog(
              title: const Text('Profile removed'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            );
          }
          final p = candidates.single;
          final reading = _readings[p.outlet];
          final now = DateTime.now();
          final enabled =
              !_readError && !_profileError && reading?.canCommand(now) == true;
          final connected =
              !_readError &&
              reading?.hasConnectedAppliance(now) == true &&
              connectedProfile(reading, _profiles)?.profileID == p.profileID;
          final canDelete =
              enabled && ['IDLE', 'DISABLED'].contains(reading!.currentState);
          void edit() => showDialog<void>(
            context: context,
            builder: (_) => Esp32ProfileEditor(
              service: widget.service,
              reading: reading!,
              profile: p,
            ),
          );
          return Dialog(
            insetPadding: const EdgeInsets.all(20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.chevron_left, color: _blue),
                        ),
                        const Expanded(
                          child: Text(
                            'Appliance\nProfile',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: enabled && !reading!.isWarning
                              ? edit
                              : null,
                          child: const Text('Edit'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _Panel(
                      child: Row(
                        children: [
                          _ApplianceIcon(type: p.applianceType),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.name,
                                  style: const TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Type of Appliance: ${p.applianceType ?? 'Not available'}',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _Panel(
                      child: Column(
                        children: [
                          _Pair('Signature ID', p.profileID, color: _blue),
                          _Pair('Outlet', p.outlet),
                          _Pair(
                            'Safety limit',
                            p.hasSafetyLimit
                                ? _duration(p.safetyCeilingDuration)
                                : 'Not available',
                            color: _green,
                          ),
                          _Pair(
                            'Status',
                            _readError
                                ? 'Offline'
                                : profileStatus(p, reading, _profiles, now),
                          ),
                          _Pair(
                            'Total sessions',
                            p.totalSessions?.toString() ?? 'Not available',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _PowerControl(
                      service: widget.service,
                      outlet: p.outlet,
                      reading: connected && enabled ? reading : null,
                      now: now,
                    ),
                    if (!connected)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Controls are available for the appliance currently recognized on this outlet.',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 18),
                    _Panel(
                      border: _amber,
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.shield_outlined, color: _amber),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _safetyNote,
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: canDelete
                                ? () => _deleteProfile(context, p, reading)
                                : null,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                            child: const Text('Delete'),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: FilledButton(
                            onPressed: enabled && !reading!.isWarning
                                ? edit
                                : null,
                            child: const Text('Edit'),
                          ),
                        ),
                      ],
                    ),
                    if (!canDelete)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Deletion requires an idle or disabled outlet.',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _deleteProfile(
    BuildContext dialogContext,
    LearnedAppliance profile,
    OutletReading reading,
  ) async {
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Delete appliance profile?'),
        content: Text(
          'Remove ${profile.name} from the ESP32 learned profiles?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.service.command(
        reading,
        'REMOVE_PROFILE',
        fields: {'profileID': profile.profileID},
      );
      if (dialogContext.mounted) Navigator.pop(dialogContext);
      _notify('ESP32 confirmed profile deletion.');
    } catch (error) {
      _notify('$error');
    }
  }

  List<Widget> _settings(DateTime now) {
    final connected =
        !_readError &&
        ['A', 'B'].every((key) => _readings[key]?.isFresh(now) == true);
    return [
      Card(
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('Dark Mode'),
              subtitle: const Text('Reduce eye strain during night use'),
              value: widget.darkMode,
              onChanged: widget.onDarkModeChanged,
            ),
            const Divider(height: 1),
            SwitchListTile(
              title: const Text('Device Alerts'),
              subtitle: const Text('Get notified about device changes'),
              value: _enabled('deviceAlerts'),
              onChanged: _preferencesReady && !_saving
                  ? (value) => _save({'deviceAlerts': value})
                  : null,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Alert Types'),
              subtitle: Text(
                [
                  if (_enabled('statusChanges')) 'Device changes',
                  if (_enabled('newDevices')) 'New devices',
                  if (_enabled('safetyWarnings')) 'Safety warnings',
                ].join(', '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _preferencesReady && !_saving ? _alertTypes : null,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.wifi),
              title: const Text('Connected Device'),
              subtitle: Text(
                connected
                    ? 'WisePlug Dual Outlet'
                    : 'Waiting for ESP32 connection',
              ),
              trailing: Icon(
                connected ? Icons.check_circle : Icons.wifi_off,
                color: connected ? _green : Colors.grey,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('App Version'),
              subtitle: Text(_version),
            ),
          ],
        ),
      ),
      if (_saving) const LinearProgressIndicator(),
      if (_settingsError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _settingsError!,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Text(
          'Device changes and newly learned appliances appear while the app is open. Safety push notifications require mobile notification permission.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      ),
    ];
  }

  Future<void> _alertTypes() async {
    final selection = {
      for (final key in ['statusChanges', 'newDevices', 'safetyWarnings'])
        key: _enabled(key),
    };
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Alert Types'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in [
                  (
                    'statusChanges',
                    'Device status changes',
                    'When a device changes state',
                  ),
                  (
                    'newDevices',
                    'New devices',
                    'When a new device is detected',
                  ),
                  (
                    'safetyWarnings',
                    'Safety warnings',
                    'When a device approaches its limit',
                  ),
                ])
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(item.$2),
                    subtitle: Text(item.$3),
                    value: selection[item.$1],
                    onChanged: (value) =>
                        update(() => selection[item.$1] = value!),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, selection),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) await _save(result);
  }

  void _showAlerts() => showDialog<void>(
    context: context,
    builder: (_) => AnimatedBuilder(
      animation: _updates,
      builder: (context, _) {
        final warnings = _readings.values
            .where((r) => r.isWarning || r.isLockedOut || r.runtimeWarning)
            .toList();
        return AlertDialog(
          title: const Text('Device alerts'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_readError) const DatabaseReadError(),
                  if (warnings.isEmpty)
                    Text(
                      _loading
                          ? 'Waiting for device data.'
                          : 'No safety alerts in the latest received readings.',
                    ),
                  for (final reading in warnings)
                    ListTile(
                      title: Text(
                        'Outlet ${reading.outlet} · ${reading.appliance}',
                      ),
                      subtitle: Text(
                        '${_status(reading, DateTime.now())}${reading.isWarning ? ' · ${reading.secondsRemaining(DateTime.now())} s until lockout' : ''}',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}

class _Panel extends StatelessWidget {
  final Widget child;
  final Color? border;
  final double padding;
  const _Panel({required this.child, this.border, this.padding = 20});
  @override
  Widget build(BuildContext context) => Card(
    shape: border == null
        ? null
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: border!, width: 1.5),
          ),
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}

class _Pair extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _Pair(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 4,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w700, color: color),
        ),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  final String status;
  const _Badge(this.status);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
    decoration: BoxDecoration(
      color: _statusColor(status).withValues(alpha: .16),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Text(
      status,
      style: TextStyle(
        color: _statusColor(status),
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

class _ApplianceIcon extends StatelessWidget {
  final String? type;
  const _ApplianceIcon({this.type});
  @override
  Widget build(BuildContext context) {
    final normalized = type?.toLowerCase() ?? '';
    final icon = normalized.contains('fan')
        ? Icons.air
        : normalized.contains('iron')
        ? Icons.iron
        : normalized.contains('cooker')
        ? Icons.rice_bowl
        : Icons.power;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: _blue.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Icon(icon, color: _blue, size: 27),
    );
  }
}

class _PowerControl extends StatefulWidget {
  final Esp32Service service;
  final OutletReading? reading;
  final String outlet;
  final DateTime now;
  const _PowerControl({
    required this.service,
    required this.reading,
    required this.outlet,
    required this.now,
  });
  @override
  State<_PowerControl> createState() => _PowerControlState();
}

class _PowerControlState extends State<_PowerControl> {
  bool _busy = false;
  Future<void> _send(String type) async {
    final reading = widget.reading;
    if (_busy) return;
    if (reading == null ||
        !reading.isFresh(widget.now) ||
        reading.sessionID.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Connect the ESP32 and wait for live device data before turning an outlet on or off.',
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.service.command(
        reading,
        type,
        fields: type == 'SMART_OVERRIDE'
            ? {'alertID': reading.alertID, 'extensionDuration': 900}
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
    final r = widget.reading;
    final enabled =
        !_busy &&
        r?.canCommand(widget.now) == true &&
        [
          'ACTIVE',
          'IDLE',
          'SAMPLING',
          'DISABLED',
          'WARNING',
        ].contains(r?.currentState);
    final on =
        r != null && !['DISABLED', 'LOCKED_OUT', ''].contains(r.currentState);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _ApplianceIcon(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Outlet ${widget.outlet}${r?.hasConnectedAppliance(widget.now) == true ? ' — ${r!.appliance}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _busy
                          ? 'Waiting for ESP32…'
                          : r == null || !r.isFresh(widget.now)
                          ? 'Unavailable'
                          : r.isLockedOut
                          ? 'Locked · physical reset required'
                          : on
                          ? 'On · monitoring enabled'
                          : 'Off · monitoring disabled',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Switch(
                value: on,
                onChanged:
                    !_busy && r?.isLockedOut != true && r?.isWarning != true
                    ? (value) => _send(value ? 'TURN_ON' : 'TURN_OFF')
                    : null,
              ),
            ],
          ),
          if (r?.isWarning == true)
            Wrap(
              spacing: 8,
              children: [
                Text('${r!.secondsRemaining(widget.now)} s until lockout'),
                TextButton(
                  onPressed: null,
                  child: const Text('Override unavailable'),
                ),
                TextButton(
                  onPressed: enabled ? () => _send('TURN_OFF') : null,
                  child: const Text('Lock now'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
