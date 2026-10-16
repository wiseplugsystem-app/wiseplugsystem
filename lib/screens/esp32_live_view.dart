import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/esp32_data.dart';
import '../models/gadget_status.dart';
import '../services/device_binding.dart';
import '../services/esp32_service.dart';
import '../widgets/wiseplug_logo.dart';
import 'activity_screen.dart';
import 'esp32_dashboard.dart';
import 'user_profile_screen.dart';
import 'wifi_config_screen.dart';

const _blue = Color(0xFF00A4EF);
const _green = Color(0xFF00B744);
const _amber = Color(0xFFF5B800);
const _safetyNote =
    'Disabled and locked outlets are switched off by their relay. Inspect the appliance before resetting a locked outlet with its physical button or Reset Safety in the safety alert.';

String _duration(int? seconds) {
  if (seconds == null) return 'Not available';
  if (seconds <= 0) return '0 s';
  if (seconds < 60) return '$seconds s';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} h';
  return '${(seconds / 60).ceil()} min';
}

/// Prefer firmware identity. Appliances are portable: the firmware recognizes
/// them on either outlet, so a profile ID matches whichever outlet learned it.
/// Legacy names are usable only when unambiguous on the same outlet.
LearnedAppliance? connectedProfile(
  OutletReading? reading,
  List<LearnedAppliance> profiles,
) {
  if (reading == null) return null;
  final matches = profiles.where(
    (p) => reading.profileID.isNotEmpty
        ? p.profileID == reading.profileID
        : p.outlet == reading.outlet &&
              (p.firmwareName == reading.appliance ||
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

/// While learning there is no warning, only the backstop; afterwards the
/// learned limit (typical use x 1.5) applies.
String _limitText(LearnedAppliance p) => p.isLearningComplete
    ? _duration(p.effectiveLimit)
    : 'Learning · ${p.sessionCount} of ${LearnedAppliance.learningSessions} uses';

String _usageText(LearnedAppliance p) => p.isLearningComplete
    ? 'Typical use ${_duration(p.baselineAverage?.round())}'
    : 'Learning · ${p.learningUsesLeft} more '
          '${p.learningUsesLeft == 1 ? 'use' : 'uses'} to learn';

String _status(OutletReading? reading, DateTime now) {
  if (reading == null) return 'Waiting';
  if (!reading.isFresh(now)) return 'Offline';
  if (reading.isLockedOut) return 'Locked out';
  if (reading.isWarning) return 'Safety warning';
  if (reading.sensorValid == false) return 'Unavailable';
  if (reading.currentState == 'DISABLED') return 'Disabled';
  if (reading.currentState == 'SAMPLING') return 'Recognizing';
  if (reading.runtimeWarning || (reading.isActive && reading.overridden)) {
    return 'Near limit';
  }
  return reading.isActive ? 'Active' : 'Idle';
}

/// Shown on the outlet card after "Yes, Override": the appliance keeps
/// running on a 20% safety buffer past its limit.
const _overrideNote =
    'Override active: past its safety limit, now running on a 20% safety '
    'buffer. You will be asked again when Remaining reaches 0.';

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
  final VoidCallback? onSignOut;
  const Esp32LiveView({
    super.key,
    required this.service,
    required this.darkMode,
    required this.onDarkModeChanged,
    this.onSignOut,
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
  bool _registrationOpen = false;
  GadgetStatus? _gadget;

  String _useKey(OutletReading r) =>
      '${r.outlet}/${r.sessionID}/${r.profileID}/${r.startTime?.millisecondsSinceEpoch}';

  // Safety warnings are raised app-wide by SafetyAlertListener.
  void _checkPopups() {
    if (!mounted || _loading || _readError) return;
    final now = DateTime.now();
    if (_readings.values.any((r) => r.isWarning) ||
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  child: _PairLayout(
                    labelWidth: 110,
                    child: Column(
                      children: [
                        _Pair('Outlet', reading.outlet),
                        _Pair(
                          'Power draw',
                          measurement(reading.activePower, 'W'),
                        ),
                      ],
                    ),
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
            takenNames: _takenNames(except: profile),
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
    _subscriptions.add(
      widget.service.streamGadgetStatus().listen(
        (value) {
          _gadget = value;
          _refresh();
        },
        onError: (Object error) {
          _gadget = null;
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
                            ? const Align(
                                alignment: Alignment.centerLeft,
                                child: WisePlugLogo(fontSize: 34),
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
                          tooltip: 'Activity',
                          icon: const Icon(Icons.notifications_none),
                          onPressed: _openActivity,
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
    // Device-level metrics come from devices/gadget-1/status.
    final gadget = _gadget?.isOnline(now) == true ? _gadget : null;
    return [
      if (!_loading && !_readError && _readings.isEmpty)
        const _Panel(
          child: Text(
            'No outlet readings found. The ESP32 must publish telemetry_logs/outlet_A and outlet_B to this app’s database.',
          ),
        ),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _StatusChip(online: gadget != null),
          Text(
            '${DeviceBinding.gadgetId} · Dual outlet',
            style: const TextStyle(
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      // Only once a status has arrived, so the banner never flashes at start.
      if (_gadget != null && gadget == null) ...[
        const SizedBox(height: 16),
        _WifiHelpBanner(onOpenSetup: _openWifiSetup),
      ],
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
          Expanded(
            child: _metric(
              measurement(gadget?.powerDraw, 'W', 0),
              'Total draw',
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _metric(
              // Outlets running an appliance, not outlets whose relay is on.
              gadget != null && !_readError
                  ? '${_readings.values.where((r) => r.hasConnectedAppliance(now)).length} / 2'
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
                  on: gadget?.outlet(key),
                  applianceName: _applianceName(_readings[key], now),
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

  /// Display name for the appliance running on an outlet, or null when none:
  /// the registered name, "Unregistered appliance" for a new signature, or
  /// the firmware's live label (e.g. while it is still recognizing).
  String? _applianceName(OutletReading? reading, DateTime now) {
    if (_readError || reading?.hasConnectedAppliance(now) != true) return null;
    final profile = _profileError ? null : connectedProfile(reading, _profiles);
    if (profile == null) return reading!.appliance;
    return profile.needsRegistration ? 'Unregistered appliance' : profile.name;
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
    final overridden = fresh && reading!.isActive && reading.overridden;
    // The limit the plug enforces: learning backstop, then the learned one;
    // after an override, the 20% buffer it granted.
    final limit = overridden && profile != null
        ? overrideBufferSeconds(profile.effectiveLimit)
        : profile?.effectiveLimit;
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
                ? _applianceName(reading, now)!
                : fresh && reading?.sensorValid == false
                ? 'Meter not responding'
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
          _Pair('Safety limit', profile == null ? '—' : _limitText(profile)),
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
          if (overridden)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _amber.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: _amber,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _overrideNote,
                      style: const TextStyle(fontSize: 12, height: 1.35),
                    ),
                  ),
                ],
              ),
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
          : profileStatus(p, _readingFor(p, now), _profiles, now);
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
                  leading: _ApplianceIcon(
                    type: profile.applianceType ?? profile.name,
                    compact: true,
                    color: _statusColor(
                      profileStatus(
                        profile,
                        _readingFor(profile, now),
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
                  // Appliances are portable: show an outlet only while running.
                  subtitle: Text(
                    _runningOn(profile, now) == null
                        ? _usageText(profile)
                        : 'Running on Outlet ${_runningOn(profile, now)!.outlet}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_deletableReading(profile, now) case final reading?)
                        IconButton(
                          tooltip: 'Delete appliance',
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          onPressed: () =>
                              _deleteProfile(context, profile, reading),
                        ),
                      _Badge(
                        profile.needsRegistration
                            ? 'Register'
                            : _readError
                            ? 'Offline'
                            : profileStatus(
                                profile,
                                _readingFor(profile, now),
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
                          final reading = _readingFor(profile, now);
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
          final now = DateTime.now();
          final reading = _readingFor(p, now);
          final enabled =
              !_readError && !_profileError && reading?.canCommand(now) == true;
          final connected =
              !_readError &&
              reading?.hasConnectedAppliance(now) == true &&
              connectedProfile(reading, _profiles)?.profileID == p.profileID;
          // Any appliance that is not running right now can be deleted.
          final canDelete = enabled && !connected;
          void edit() => showDialog<void>(
            context: context,
            builder: (_) => Esp32ProfileEditor(
              service: widget.service,
              reading: reading!,
              profile: p,
              takenNames: _takenNames(except: p),
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        // Balances the back button so the title stays centred;
                        // Edit lives next to Delete at the bottom.
                        const SizedBox(width: 48),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _Panel(
                      child: Row(
                        children: [
                          _ApplianceIcon(type: p.applianceType ?? p.name),
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
                                if (p.applianceType != null)
                                  Text(
                                    'Type of Appliance: ${p.applianceType}',
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
                      child: _PairLayout(
                        labelWidth: 150,
                        child: Column(
                          children: [
                            _Pair(
                              'Saved name',
                              p.needsRegistration
                                  ? 'Not registered yet'
                                  : p.name,
                              color: _blue,
                            ),
                            _Pair(
                              'Plugged into',
                              connected
                                  ? 'Outlet ${reading!.outlet}'
                                  : 'Not running',
                            ),
                            _Pair('Safety limit', _limitText(p), color: _green),
                            if (p.isLearningComplete &&
                                p.baselineAverage != null)
                              _Pair(
                                'Typical use',
                                _duration(p.baselineAverage!.round()),
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
                            // The steady-power window the WisePlug matches on.
                            _Pair(
                              'Recognition range',
                              p.powerMin == null || p.powerMax == null
                                  ? 'Not available'
                                  : '${p.powerMin!.clamp(0, double.infinity).toStringAsFixed(1)}–${p.powerMax!.toStringAsFixed(1)} W',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _PowerControl(
                      service: widget.service,
                      outlet: reading?.outlet ?? p.outlet,
                      reading: connected && enabled ? reading : null,
                      now: now,
                      applianceName: p.needsRegistration
                          ? 'Unregistered appliance'
                          : p.name,
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
                                ? () => _deleteProfile(context, p, reading!)
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
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          connected
                              ? 'Switch off or unplug this appliance to delete it.'
                              : 'The WisePlug must be online to delete appliances.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
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
    final name = profile.needsRegistration
        ? 'this unregistered appliance'
        : profile.name;
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Delete appliance?'),
        content: Text(
          'Remove $name from your account? The WisePlug forgets its power '
          'signature and will treat it as a new appliance if it is plugged in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.service.deleteProfile(reading, profile);
      if (dialogContext != context && dialogContext.mounted) {
        Navigator.pop(dialogContext);
      }
      _notify('Appliance deleted.');
    } catch (error) {
      _notify('$error');
    }
  }

  /// The reading of whichever outlet [profile] is running on right now.
  OutletReading? _runningOn(LearnedAppliance profile, DateTime now) {
    if (_readError) return null;
    for (final reading in _readings.values) {
      if (reading.hasConnectedAppliance(now) &&
          connectedProfile(reading, _profiles)?.profileID ==
              profile.profileID) {
        return reading;
      }
    }
    return null;
  }

  /// Where [profile] runs, or else the outlet that learned it.
  OutletReading? _readingFor(LearnedAppliance profile, DateTime now) =>
      _runningOn(profile, now) ?? _readings[profile.outlet];

  /// A reading to send REMOVE_PROFILE through (the firmware searches both
  /// outlets), when [profile] is idle; null when it cannot be deleted now.
  OutletReading? _deletableReading(LearnedAppliance profile, DateTime now) {
    if (_readError || _profileError || _runningOn(profile, now) != null) {
      return null;
    }
    for (final reading in [?_readings[profile.outlet], ..._readings.values]) {
      if (reading.canCommand(now)) return reading;
    }
    return null;
  }

  /// Lower-cased names of registered appliances, for duplicate checks.
  Set<String> _takenNames({LearnedAppliance? except}) => {
    for (final p in _profiles)
      if (!p.needsRegistration &&
          !(p.outlet == except?.outlet && p.profileID == except?.profileID))
        p.name.trim().toLowerCase(),
  };

  List<Widget> _settings(DateTime now) {
    final connected = _gadget?.isOnline(now) == true;
    return [
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('User Profile'),
              subtitle: const Text('Account, bound device, delete account'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => UserProfileScreen(service: widget.service),
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.router_outlined),
              title: const Text('Wi-Fi Configuration'),
              subtitle: const Text('Send home Wi-Fi details to the WisePlug'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WifiConfigScreen(service: widget.service),
                ),
              ),
            ),
            const Divider(height: 1),
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
                    ? 'WisePlug Dual Outlet · ${DeviceBinding.gadgetId} · Online'
                    : '${DeviceBinding.gadgetId} · Offline',
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
      const SizedBox(height: 24),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.red,
          side: const BorderSide(color: Colors.red),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onPressed: widget.onSignOut,
        icon: const Icon(Icons.logout),
        label: const Text('Sign out'),
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

  // Live alerts are raised app-wide by SafetyAlertListener; the bell opens
  // the persistent history.
  void _openActivity() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ActivityScreen(
        service: widget.service,
        nameFor: (id) {
          for (final p in _profiles) {
            if (p.profileID == id) {
              return p.needsRegistration ? 'Unregistered appliance' : p.name;
            }
          }
          return null;
        },
      ),
    ),
  );

  void _openWifiSetup() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => WifiConfigScreen(service: widget.service),
    ),
  );
}

class _StatusChip extends StatelessWidget {
  final bool online;
  const _StatusChip({required this.online});
  @override
  Widget build(BuildContext context) {
    final color = online ? _green : Colors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Text(
            online ? 'Online' : 'Offline',
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

/// Shown while the WisePlug is offline: a powered-on plug that is offline
/// almost always has no working Wi-Fi.
class _WifiHelpBanner extends StatelessWidget {
  final VoidCallback onOpenSetup;
  const _WifiHelpBanner({required this.onOpenSetup});
  @override
  Widget build(BuildContext context) => _Panel(
    border: _amber,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.wifi_off, color: _amber),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your WisePlug is offline',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'If it is plugged in, connect it to Wi-Fi in two steps:\n'
          '1. On your phone, join the Wi-Fi "wisewp" (no password).\n'
          '2. Tap your home network on the page that opens, or tap "Wi-Fi setup" below.',
          style: TextStyle(height: 1.5),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: onOpenSetup,
            icon: const Icon(Icons.router_outlined),
            label: const Text('Wi-Fi setup'),
          ),
        ),
      ],
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

/// Lays out the [_Pair]s below it as a left-aligned table: labels in one
/// column of [labelWidth], values lined up next to them.
class _PairLayout extends InheritedWidget {
  final double labelWidth;
  const _PairLayout({required this.labelWidth, required super.child});

  static double? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PairLayout>()?.labelWidth;

  @override
  bool updateShouldNotify(_PairLayout old) => old.labelWidth != labelWidth;
}

class _Pair extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _Pair(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) {
    final labelText = Text(label, style: const TextStyle(color: Colors.grey));
    final valueText = Text(
      value,
      style: TextStyle(fontWeight: FontWeight.w700, color: color),
    );
    final labelWidth = _PairLayout.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: labelWidth == null
          ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [labelText, valueText],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: labelWidth, child: labelText),
                Expanded(child: valueText),
              ],
            ),
    );
  }
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
  /// Type or name; the icon is guessed from keywords in it.
  final String? type;
  final Color color;
  final bool compact;
  const _ApplianceIcon({this.type, this.color = _blue, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final normalized = type?.toLowerCase() ?? '';
    final icon = normalized.contains('fan')
        ? Icons.air
        : normalized.contains('iron')
        ? Icons.iron
        : normalized.contains('cooker') || normalized.contains('rice')
        ? Icons.rice_bowl
        : normalized.contains('kettle')
        ? Icons.coffee_maker_outlined
        : normalized.contains('lamp') || normalized.contains('light')
        ? Icons.lightbulb_outline
        : Icons.power;
    return Container(
      padding: EdgeInsets.all(compact ? 9 : 13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(compact ? 14 : 18),
      ),
      child: Icon(icon, color: color, size: compact ? 22 : 27),
    );
  }
}

class _PowerControl extends StatefulWidget {
  final Esp32Service service;
  final OutletReading? reading;
  final String outlet;
  final DateTime now;

  /// Live switch state from devices/gadget-1/status; falls back to telemetry.
  final bool? on;

  /// Registered or recognized appliance on this outlet; null when empty.
  final String? applianceName;
  const _PowerControl({
    required this.service,
    required this.reading,
    required this.outlet,
    required this.now,
    this.on,
    this.applianceName,
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
    // Interlock: never send a switch command for an empty outlet.
    final empty = !reading.hasConnectedAppliance(widget.now);
    if (type == 'TURN_OFF' && empty && !reading.isWarning) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No appliance is plugged into Outlet ${widget.outlet}.',
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
            ? {
                'alertID': reading.alertID,
                'extensionDuration': reading.overrideSeconds(widget.now),
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
        widget.on ??
        (r != null && !['DISABLED', 'LOCKED_OUT', ''].contains(r.currentState));
    final appliance = r?.hasConnectedAppliance(widget.now) == true;
    // Only the switch shows the state: green = power on (live relay state).
    final lit = r != null && r.isFresh(widget.now) && !r.isLockedOut && on;
    final canToggle =
        !_busy &&
        r?.isLockedOut != true &&
        r?.isWarning != true &&
        (!on || appliance);
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
              _ApplianceIcon(type: widget.applianceName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.applianceName ?? 'Outlet ${widget.outlet}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      (widget.applianceName == null
                              ? ''
                              : 'Outlet ${widget.outlet} · ') +
                          (_busy
                              ? 'Waiting for ESP32…'
                              : r == null || !r.isFresh(widget.now)
                              ? 'Unavailable'
                              : r.isLockedOut
                              ? 'Locked · reset with button or safety alert'
                              : on && !appliance
                              ? 'On · no appliance detected'
                              : on
                              ? 'On · monitoring enabled'
                              : 'Off · monitoring disabled'),
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Switch(
                value: on,
                // Green when on; dimmed whenever the switch is disabled.
                trackColor: WidgetStateProperty.resolveWith((states) {
                  final disabled = states.contains(WidgetState.disabled);
                  if (states.contains(WidgetState.selected) && lit) {
                    return _green.withValues(alpha: disabled ? .3 : 1);
                  }
                  return Colors.grey.withValues(alpha: disabled ? .12 : .25);
                }),
                thumbColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.disabled)
                      ? Colors.grey.shade300
                      : Colors.white,
                ),
                trackOutlineColor: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.selected) &&
                          lit &&
                          !states.contains(WidgetState.disabled)
                      ? _green
                      : Colors.grey.withValues(alpha: .35),
                ),
                // With nothing plugged in there is nothing to switch off. An
                // outlet that is off stays switchable: with its relay open no
                // appliance can ever be detected on it.
                onChanged: canToggle
                    ? (value) {
                        HapticFeedback.selectionClick();
                        _send(value ? 'TURN_ON' : 'TURN_OFF');
                      }
                    : null,
              ),
            ],
          ),
          if (lit && !appliance && !_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8, left: 4),
              child: Row(
                children: [
                  Icon(Icons.power_off_outlined, size: 16, color: Colors.grey),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Plug in an appliance to use this switch.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
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
