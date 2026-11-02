import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/esp32_data.dart';
import '../models/gadget_status.dart';
import '../models/recognition.dart';
import '../services/device_binding.dart';
import '../services/esp32_service.dart';
import '../services/recognition_service.dart';
import '../widgets/wiseplug_logo.dart';
import 'activity_screen.dart';
import 'esp32_dashboard.dart';
import 'recognition_prompt.dart';
import 'registration_dialog.dart';
import 'user_profile_screen.dart';
import 'wifi_config_screen.dart';

const _blue = Color(0xFF00A4EF);
const _green = Color(0xFF00B744);
const _amber = Color(0xFFF5B800);
const _safetyNote =
    'Disabled and locked outlets are switched off by their relay. Inspect the appliance before resetting a locked outlet with Reset Safety in Power Control or its physical button.';

/// How long a run has lasted, exact to the second: "4:07" or "1:02:15".
/// The outlet card's timer, in words: "45 s", "12 min 34 s", "1 h 02 min".
String _onFor(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds; // plug and phone clocks may differ
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  if (h > 0) return '$h h ${m.toString().padLeft(2, '0')} min';
  if (m > 0) return '$m min $sec s';
  return '$sec s';
}

String _runningTime(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds; // plug and phone clocks may differ
  String two(int v) => v.toString().padLeft(2, '0');
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// "3:19 PM" today, otherwise "2 Nov, 3:19 PM" (the phone's local time).
String _clockTime(DateTime t, DateTime now) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final l = t.toLocal(), n = now.toLocal();
  final hour = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final time =
      '$hour:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
  final today = l.year == n.year && l.month == n.month && l.day == n.day;
  return today ? time : '${l.day} ${months[l.month - 1]}, $time';
}

String _duration(int? seconds) {
  if (seconds == null) return 'Not available';
  if (seconds <= 0) return '0 s';
  if (seconds < 60) return '$seconds s';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} h';
  return '${(seconds / 60).ceil()} min';
}

/// Legacy (the Firebase catalog of the old on-plug recognition, no longer used
/// by the screens; kept until that catalog is removed). Prefers firmware
/// identity: a profile ID matches whichever outlet learned it. Legacy names
/// are usable only when unambiguous on the same outlet.
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
  'Near limit' || 'Recognizing' || 'Registering' => _amber,
  'Locked out' || 'Safety warning' => Colors.red,
  _ => Colors.grey,
};

class Esp32LiveView extends StatefulWidget {
  final Esp32Service service;

  /// Rule-based recognition in Supabase (prompts, registration, appliances);
  /// null when Supabase is not configured.
  final RecognitionService? recognition;
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;
  final VoidCallback? onSignOut;
  const Esp32LiveView({
    super.key,
    required this.service,
    this.recognition,
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
  bool _readError = false, _loading = true;
  String _version = 'Loading…';
  int _tab = 0;
  Timer? _clock;
  GadgetStatus? _gadget;

  /// Rule-based recognition (Supabase): the open run on each outlet.
  Map<String, OutletSession> _sessions = {};
  RecognitionSettings _recognitionSettings = const RecognitionSettings();
  final _appliancesNamed = <String, String>{};
  final _promptedEvents = <String>{};
  bool _promptOpen = false;

  /// The Profiles tab: the user's registered appliances (Supabase).
  List<RegisteredAppliance> _appliances = [];
  bool _appliancesLoaded = false;
  String? _appliancesError;
  String _filter = 'All';
  String _sessionsKey = '';

  // Safety warnings are raised app-wide by SafetyAlertListener. A run that
  // needs the user's answer (UNKNOWN, AMBIGUOUS, SAME_TYPE_IN_USE) opens its
  // prompt once, when nothing more urgent is on screen. A provisional
  // "Looks like X" is asked on the outlet card only, never in a pop-up.
  void _checkPopups() {
    if (!mounted || _loading || _readError || _promptOpen) return;
    final now = DateTime.now();
    if (_readings.values.any((r) => r.isWarning)) return;
    for (final entry in _sessions.entries) {
      final reading = _readings[entry.key];
      final session = entry.value;
      if (session.status.needsAnswer &&
          reading != null &&
          reading.hasConnectedAppliance(now) &&
          _promptedEvents.add(session.eventId)) {
        _openPrompt(session);
        return;
      }
    }
  }

  /// Asks about the run [session] and acts on the answer.
  Future<void> _openPrompt(OutletSession session) async {
    final recognition = widget.recognition;
    if (recognition == null || _promptOpen) return;
    _promptOpen = true;
    try {
      final required = _recognitionSettings.registrationSamples;
      // Registration is a pop-up that appears only for a new appliance.
      Future<void> register({
        String? typeName,
        String? name,
        List<RegisteredAppliance> unfinished = const [],
      }) async {
        await showRegistrationDialog(
          context,
          service: recognition,
          fromSession: session,
          typeName: typeName,
          name: name,
          unfinished: unfinished,
          settings: _recognitionSettings,
        );
        _loadAppliances();
      }

      if (session.status == RecognitionStatus.unknown) {
        // A new load may be an appliance whose registration was left unfinished.
        await register(
          unfinished: [
            for (final a in _appliances)
              if (!a.isReady(required)) a,
          ],
        );
        return;
      }
      final choice = await showRecognitionPrompt(
        context,
        session,
        defaultCutoffMinutes: _recognitionSettings.defaultCutoffMinutes,
      );
      if (!mounted) return;
      switch (choice) {
        case ConfirmChoice(:final applianceId, :final name):
          try {
            await recognition.confirm(session.eventId, applianceId);
            _notify(
              'Confirmed: $name. Its own safe operating time applies now.',
            );
          } catch (error) {
            _notify('$error'.replaceFirst('Bad state: ', ''));
          }
        case RegisterChoice(:final typeName, :final name):
          await register(typeName: typeName, name: name);
        case null:
          break;
      }
    } finally {
      _promptOpen = false;
    }
  }

  /// Re-reads the registered appliances (Profiles tab, unfinished registrations).
  Future<void> _loadAppliances() async {
    final recognition = widget.recognition;
    if (recognition == null) return;
    try {
      _appliances = await recognition.appliances();
      _appliancesError = null;
      for (final a in _appliances) {
        _appliancesNamed[a.id] = a.name;
      }
    } catch (error) {
      _appliancesError = '$error';
    }
    _appliancesLoaded = true;
    _refresh();
  }

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
          if (!_loading && !_readError) {
            for (final entry in value.entries) {
              final old = _readings[entry.key];
              final next = entry.value;
              if (old != null &&
                  next.isFresh(DateTime.now()) &&
                  old.currentState != next.currentState) {
                _notify(
                  'Outlet ${entry.key}: ${_status(next, DateTime.now())}',
                );
              }
            }
          }
          _readings = value;
          _readError = false;
          _loading = false;
          _refresh();
        },
        onError: (Object error) {
          _readError = true;
          debugPrint('WisePlug readings unavailable: $error'); // for developers
          _loading = false;
          _refresh();
        },
      ),
    );
    final recognition = widget.recognition;
    if (recognition != null) {
      _subscriptions.add(
        recognition.openSessions().listen(
          (value) {
            _sessions = value;
            for (final s in value.values) {
              if (s.applianceId != null && s.applianceName != null) {
                _appliancesNamed[s.applianceId!] = s.applianceName!;
              }
            }
            // A run started, ended or was decided: the profiles change too.
            final key = value.values
                .map((s) => '${s.eventId}/${s.status.wire}/${s.applianceId}')
                .join(',');
            if (key != _sessionsKey) {
              _sessionsKey = key;
              _loadAppliances();
            }
            _refresh();
          },
          // Offline for a moment: keep the last known runs; the next poll retries.
          onError: (Object _) {},
        ),
      );
      recognition.settings().then((s) {
        _recognitionSettings = s;
        _refresh();
      }, onError: (Object _) {});
      _loadAppliances();
    }
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
                  if (_tab == 0 && _loading) const LinearProgressIndicator(),
                  if (_tab == 0 && _readError)
                    _Panel(
                      child: Text(
                        'Can\'t load your WisePlug\'s readings right now. '
                        'Check your phone\'s internet connection.',
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
            'No readings from your WisePlug yet. Make sure it is plugged in '
            'and connected to Wi-Fi.',
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

  /// Display name for the appliance running on an outlet, or null when none.
  /// The plug publishes the name Supabase recognised ("Fan 1"), or "Unknown
  /// appliance" / "Recognizing appliance" until then.
  String? _applianceName(OutletReading? reading, DateTime now) {
    if (_readError || reading?.hasConnectedAppliance(now) != true) return null;
    final session = _sessions[reading!.outlet];
    final matched =
        session != null &&
        (session.status == RecognitionStatus.provisional ||
            session.status == RecognitionStatus.confirmed);
    return matched
        ? session.applianceName ?? reading.appliance
        : reading.appliance;
  }

  /// The recognition badge of a running outlet: what WisePlug knows about it
  /// and, when the user has to answer, a button that opens the prompt.
  Widget? _recognitionBadge(OutletSession? session, bool connected) {
    if (!connected || session == null) return null;
    // Provisional: ask plainly, with a big button. One tap confirms, so the
    // appliance gets its own limit and the run counts as a usage session.
    if (session.status == RecognitionStatus.provisional &&
        widget.recognition != null &&
        session.applianceId != null) {
      final name = session.applianceName ?? 'this appliance';
      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _amber.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _amber),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Is this $name?',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 4),
            const Text(
              'Confirm it so WisePlug uses its own safety limit and counts this use.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _green,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () => _confirmProvisional(session),
              icon: const Icon(Icons.check_circle),
              label: Text('Yes, it is $name'),
            ),
            TextButton(
              onPressed: () => _openPrompt(session),
              child: const Text('No, it is something else'),
            ),
          ],
        ),
      );
    }
    // A question waiting for the user: a clear button that opens it.
    if (session.status.needsAnswer && widget.recognition != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: _amber),
          onPressed: () => _openPrompt(session),
          icon: const Icon(Icons.help_outline),
          label: const Text('Needs your answer'),
        ),
      );
    }
    final (text, color) = switch (session.status) {
      RecognitionStatus.confirmed => ('Confirmed', _green),
      RecognitionStatus.recognizing => ('Recognizing…', Colors.grey),
      _ => ('Provisional', _amber),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /// "Yes, it is Fan" on a provisional label: confirms it in one tap.
  Future<void> _confirmProvisional(OutletSession session) async {
    try {
      await widget.recognition!.confirm(session.eventId, session.applianceId!);
      _notify(
        'Confirmed: ${session.applianceName}. Its own safety limit applies now.',
      );
    } catch (error) {
      _notify('$error'.replaceFirst('Bad state: ', ''));
    }
  }

  Widget _summary(String key, DateTime now) {
    final reading = _readings[key];
    final connected =
        !_readError && reading?.hasConnectedAppliance(now) == true;
    final session = connected ? _sessions[key] : null;
    final status = _readError ? 'Offline' : _status(reading, now);
    final color = _statusColor(status);
    final fresh = !_readError && reading?.isFresh(now) == true;
    final seconds = fresh && reading!.isActive && reading.safetyDeadline != null
        ? reading.safetyDeadline!.difference(now).inSeconds.clamp(0, 604800)
        : null;
    final overridden = fresh && reading!.isActive && reading.overridden;
    // The cutoff of this run (the safe default until the appliance is
    // confirmed); after an override, the 20% buffer it granted.
    final cutoff = session?.cutoffSeconds;
    final limit = overridden && cutoff != null
        ? overrideBufferSeconds(cutoff)
        : cutoff;
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
          Text(status, style: TextStyle(color: color)),
          // How long the appliance has been on: a timer that counts up every
          // second (the screen refreshes each second).
          if (start != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _blue.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer_outlined, color: _blue, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'On for ${_onFor(now.difference(start))}',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: _blue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ?_recognitionBadge(session, connected),
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
                ? 'Last updated: unknown'
                : 'Last updated: ${_clockTime(reading.lastUpdated!, now)}'
                      '${fresh ? '' : ' · may be out of date'}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          _Pair(
            'Start',
            start == null
                ? '—'
                : '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}',
          ),
          _Pair(
            'Safety limit',
            cutoff == null
                ? '—'
                : session!.status == RecognitionStatus.confirmed
                ? _duration(cutoff)
                : '${_duration(cutoff)} (safe default)',
          ),
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

  /// " · 12:34" while the run on [outlet] has a start time, else "".
  String _runningFor(String outlet, DateTime now) {
    final reading = _readings[outlet];
    final start = reading != null && reading.hasConnectedAppliance(now)
        ? reading.startTime
        : null;
    return start == null ? '' : ' · ${_runningTime(now.difference(start))}';
  }

  /// The outlet ('A' / 'B') [a] is running on now, or null. A run whose end
  /// was never reported is not shown while the outlet's live reading is idle.
  String? _outletOf(RegisteredAppliance a) {
    if (a.runningOn == null) return null;
    final outlet = outletLetter(a.runningOn!);
    return _status(_readings[outlet], DateTime.now()) == 'Idle' ? null : outlet;
  }

  /// Status shown for a profile: the live status of the outlet it is on,
  /// "Registering" until its plug-ins are done, else "Idle".
  String _applianceStatus(RegisteredAppliance a, DateTime now) {
    if (!a.isReady(_recognitionSettings.registrationSamples)) {
      return 'Registering';
    }
    final outlet = _outletOf(a);
    if (outlet == null) return 'Idle';
    return _readError ? 'Offline' : _status(_readings[outlet], now);
  }

  String _registrationText(RegisteredAppliance a) {
    final required = _recognitionSettings.registrationSamples;
    final done = a.modes.isEmpty
        ? 0
        : a.modes.map((m) => m.sampleCount).reduce((x, y) => x < y ? x : y);
    return 'Registering · $done of $required plug-ins. Plug it in again to continue.';
  }

  /// As in the 19th commit: the learned limit once the typical use is known,
  /// "Learning · n of 7 uses" until then (the type's limit still applies).
  String _limitText(RegisteredAppliance a) => a.isLearned
      ? _duration(a.cutoffMinutes * 60)
      : 'Learning · ${_sessionsText(a)} (max ${_duration(a.cutoffMinutes * 60)})';

  /// Usage sessions counted by the 7-use learning: "2 of 7 uses", then
  /// "Learned from 7 uses".
  String _sessionsText(RegisteredAppliance a) {
    final total = _recognitionSettings.learningUses;
    return a.isLearned
        ? 'Learned from $total uses'
        : '${a.useCount.clamp(0, total)} of $total uses';
  }

  /// "Not plugged in · last used on Outlet A" (or never used yet).
  String _whereText(RegisteredAppliance a) => a.lastOutlet == null
      ? 'Not plugged in'
      : 'Not plugged in · last used on Outlet ${outletLetter(a.lastOutlet!)}';

  String _usageText(RegisteredAppliance a) {
    if (!a.isReady(_recognitionSettings.registrationSamples)) {
      return _registrationText(a);
    }
    if (a.isLearned && a.baselineRuntimeSeconds != null) {
      return 'Typical use ${_duration(a.baselineRuntimeSeconds)}';
    }
    final left = (_recognitionSettings.learningUses - a.useCount).clamp(0, 99);
    return 'Learning · $left more ${left == 1 ? 'use' : 'uses'} to learn';
  }

  List<Widget> _profileList(DateTime now) {
    // A small phone: the status badge moves under the appliance's name.
    final narrow = MediaQuery.sizeOf(context).width < 480;
    if (widget.recognition == null) {
      return const [
        _Panel(
          child: Text(
            'Appliance profiles are not available in this version of the app.',
          ),
        ),
      ];
    }
    final profiles = _appliances.where((a) {
      final status = _applianceStatus(a, now);
      return _filter == 'All' ||
          (_filter == 'Active'
              ? [
                  'Active',
                  'Near limit',
                  'Safety warning',
                  'Recognizing',
                ].contains(status)
              : status == 'Idle' || status == 'Registering');
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
      if (!_appliancesLoaded) const LinearProgressIndicator(),
      if (_appliancesError != null)
        _Panel(
          child: Text(
            'Can\'t load your appliances right now. Check your phone\'s '
            'internet connection.',
          ),
        ),
      if (profiles.isEmpty && _appliancesLoaded && _appliancesError == null)
        _Panel(
          child: Text(
            _appliances.isEmpty
                ? 'No appliances registered yet. Plug one in: WisePlug will ask you to register it.'
                : 'No appliances match this filter.',
          ),
        ),
      if (profiles.isNotEmpty)
        _Panel(
          padding: 0,
          child: Column(
            children: [
              for (final a in profiles) ...[
                if (a != profiles.first)
                  const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: _ApplianceIcon(
                    type: '${a.typeName} ${a.name}',
                    compact: true,
                    color: _statusColor(_applianceStatus(a, now)),
                  ),
                  title: Text(
                    a.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  // Appliances are portable: one profile for both outlets.
                  // On a narrow phone the status badge goes under the name,
                  // so the text keeps its width.
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_outletOf(a) == null) ...[
                        Text(_usageText(a)),
                        Text(
                          _whereText(a),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ] else
                        Text(
                          'Running on Outlet ${_outletOf(a)}'
                          '${_runningFor(_outletOf(a)!, now)}',
                        ),
                      if (narrow) ...[
                        const SizedBox(height: 6),
                        _Badge(_applianceStatus(a, now)),
                      ],
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_outletOf(a) == null)
                        IconButton(
                          tooltip: 'Delete appliance',
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          onPressed: () => _deleteAppliance(context, a),
                        ),
                      if (!narrow) _Badge(_applianceStatus(a, now)),
                      const Icon(Icons.chevron_right, color: Colors.grey),
                    ],
                  ),
                  onTap: () => _showProfile(a),
                ),
              ],
            ],
          ),
        ),
    ];
  }

  /// The appliance detail screen (a full page): what it is, where it is, its
  /// safety limit and how WisePlug recognises it, with Edit and Delete. It
  /// follows live changes; usage history is kept in the database, not shown.
  void _showProfile(RegisteredAppliance selected) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimatedBuilder(
          animation: _updates,
          builder: (context, _) {
            final match = _appliances.where((a) => a.id == selected.id);
            return Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.chevron_left, color: _blue),
                ),
                title: const Text(
                  'Appliance Profile',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                centerTitle: true,
              ),
              body: match.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'This appliance was removed.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : _profileDetails(context, match.single),
            );
          },
        ),
      ),
    );
  }

  /// The signature shown on the profile: the registered "Normal" mode, else
  /// the first complete one, else the one still being registered.
  ApplianceMode? _mainMode(RegisteredAppliance a) {
    final required = _recognitionSettings.registrationSamples;
    for (final m in a.modes) {
      if (m.name == 'Normal' && m.sampleCount >= required) return m;
    }
    for (final m in a.modes) {
      if (m.sampleCount >= required) return m;
    }
    return a.modes.isEmpty ? null : a.modes.first;
  }

  Widget _profileDetails(BuildContext context, RegisteredAppliance a) {
    final now = DateTime.now();
    final outlet = _outletOf(a);
    final ready = a.isReady(_recognitionSettings.registrationSamples);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _Panel(
              child: Row(
                children: [
                  _ApplianceIcon(type: '${a.typeName} ${a.name}'),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.name,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Type of Appliance: ${a.typeName}',
                          style: const TextStyle(color: Colors.grey),
                        ),
                        // Under the name, so a long name keeps its width.
                        const SizedBox(height: 10),
                        _Badge(_applianceStatus(a, now)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Panel(
              child: _PairLayout(
                labelWidth: 150,
                child: Column(
                  children: [
                    _Pair('Saved name', a.name, color: _blue),
                    _Pair(
                      'Plugged into',
                      outlet == null ? 'Not plugged in' : 'Outlet $outlet',
                    ),
                    if (a.lastOutlet != null)
                      _Pair(
                        'Last used on',
                        'Outlet ${outletLetter(a.lastOutlet!)}',
                      ),
                    // Set by WisePlug: the type's default, then the learned
                    // typical use x 1.5.
                    _Pair('Safety limit', _limitText(a), color: _green),
                    // The 7-use learning: uses recorded so far.
                    _Pair('Usage sessions', _sessionsText(a)),
                    if (a.isLearned && a.baselineRuntimeSeconds != null)
                      _Pair('Typical use', _duration(a.baselineRuntimeSeconds)),
                    _Pair('Status', _applianceStatus(a, now)),
                    // Confirmed uses (the count the 7-use learning keeps).
                    _Pair('Total sessions', '${a.useCount}'),
                    // The power signature WisePlug recognises. Only the main
                    // one: extra modes WisePlug adds by itself ("Mode 2", e.g.
                    // another fan speed) still count for recognition, unshown.
                    if (_mainMode(a) case final m?)
                      _Pair(
                        'Power use',
                        m.sampleCount < _recognitionSettings.registrationSamples
                            ? 'Still learning (${m.sampleCount} of ${_recognitionSettings.registrationSamples} plug-ins)'
                            : m.meanPowerW == null
                            ? 'Not known yet'
                            : 'About ${m.meanPowerW!.round()} W',
                      ),
                  ],
                ),
              ),
            ),
            if (!ready)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _registrationText(a),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 16),
            _Panel(
              border: _amber,
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: _amber),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'WisePlug sets the safety limit itself and learns this '
                      'appliance\'s typical use. $_safetyNote',
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
                    onPressed: outlet == null
                        ? () => _deleteAppliance(context, a)
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
                    onPressed: () => _renameAppliance(context, a),
                    child: const Text('Edit'),
                  ),
                ),
              ],
            ),
            if (outlet != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Switch off or unplug this appliance to delete it.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Edit: the name only (the safety limit and modes are set by WisePlug).
  Future<void> _renameAppliance(
    BuildContext dialogContext,
    RegisteredAppliance a,
  ) async {
    final name = await showDialog<String>(
      context: dialogContext,
      builder: (_) => _RenameDialog(initial: a.name),
    );
    if (name == null || name.isEmpty || name == a.name || !mounted) return;
    if (_appliances.any(
      (x) => x.id != a.id && x.name.toLowerCase() == name.toLowerCase(),
    )) {
      _notify(
        'An appliance with this name already exists. Please choose a unique name.',
      );
      return;
    }
    try {
      await widget.recognition!.rename(a.id, name);
      _notify('Saved as $name.');
    } catch (error) {
      _notify('$error'.replaceFirst('Bad state: ', ''));
    }
    await _loadAppliances();
  }

  Future<void> _deleteAppliance(
    BuildContext dialogContext,
    RegisteredAppliance a,
  ) async {
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Delete appliance?'),
        content: Text(
          'Remove ${a.name} from your account? WisePlug forgets its power '
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
      await widget.recognition!.deleteAppliance(a.id);
      if (dialogContext != context && dialogContext.mounted) {
        Navigator.pop(dialogContext);
      }
      _notify('Appliance deleted.');
    } catch (error) {
      _notify('$error'.replaceFirst('Bad state: ', ''));
    }
    await _loadAppliances();
  }

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

  // Live alerts are raised app-wide by SafetyAlertListener; the bell opens
  // the persistent history.
  void _openActivity() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ActivityScreen(
        service: widget.service,
        // Appliance IDs in the history are Supabase appliance IDs.
        nameFor: (id) => _appliancesNamed[id],
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

/// "Edit Appliance Profile": the name only. Owns its text controller, so it
/// is disposed after the dialog's closing animation, not during it.
class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit Appliance Profile'),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(
        labelText: 'Appliance Name',
        border: OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _name.text.trim()),
        child: const Text('Save Profile'),
      ),
    ],
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
            'Your WisePlug isn\'t connected right now. Wait until it shows '
            'live readings, then try again.',
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
          const SnackBar(content: Text('Done. Your WisePlug did it.')),
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

  /// Unlocks a locked outlet after the user confirms the appliance is safe.
  Future<void> _reset() async {
    final reading = widget.reading;
    if (_busy || reading == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset safety?'),
        content: Text(
          'Outlet ${widget.outlet} was switched off for safety. Check the '
          'appliance first: unplug it if it is hot, smells of burning or '
          'looks damaged. Resetting switches the outlet back on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset Safety'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.service.resetSafety(reading);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Outlet ${widget.outlet} is back on.')),
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
                              ? 'Waiting for your WisePlug…'
                              : r == null || !r.isFresh(widget.now)
                              ? 'Unavailable'
                              : r.isLockedOut
                              ? 'Locked · switched off for safety'
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
          if (r != null && r.isLockedOut)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, size: 18, color: Colors.red),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Inspect the appliance, then reset to switch it back on.',
                      style: TextStyle(fontSize: 12, height: 1.35),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                    // Needs live data from the plug: it checks the reset
                    // against its current session.
                    onPressed:
                        !_busy &&
                            r.isFresh(widget.now) &&
                            r.sessionID.isNotEmpty
                        ? _reset
                        : null,
                    child: const Text('Reset Safety'),
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
