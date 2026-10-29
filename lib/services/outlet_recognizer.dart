import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';
import 'esp32_service.dart';
import 'supabase_backend.dart';

/// Identifies the appliance on each outlet with the Supabase match-signature
/// function, independently for outlet_1 and outlet_2.
///
/// It listens to the RTDB live telemetry of both outlets and, once a run has
/// been steady for [settleReadings] readings (ACTIVE: past the plug's inrush
/// and sampling window), sends that reading once. Profiles are shared by the
/// device, so an appliance learned on one outlet is recognized on the other.
///
/// ```dart
/// final recognizer = OutletRecognizer(Esp32Service(), SupabaseBackend())..start();
/// recognizer.matches.listen((m) {
///   if (m.recognized) {
///     print('${m.outlet!.label}: ${m.applianceName} (${m.confidence}%)');
///   } else if (m.isUnrecognized) {
///     print('${m.outlet!.label}: new appliance, start registration');
///   }
/// });
/// ```
class OutletRecognizer {
  final Esp32Service live;
  final SupabaseBackend backend;
  final int settleReadings;

  final _matches = StreamController<SignatureMatch>.broadcast();
  final _latest = <OutletChannel, SignatureMatch>{};
  final _steady = <OutletChannel, int>{};
  final _asked = <OutletChannel>{};
  StreamSubscription<OutletTelemetry>? _subscription;

  OutletRecognizer(this.live, this.backend, {this.settleReadings = 2});

  /// One result per outlet per run.
  Stream<SignatureMatch> get matches => _matches.stream;

  /// The latest result of [outlet] during its current run, if any.
  SignatureMatch? current(OutletChannel outlet) => _latest[outlet];

  void start() {
    _subscription ??= live.streamAllLiveTelemetry().listen(
      (both) => both.readings.values.forEach(handle),
      onError: (Object error) => debugPrint('Live telemetry: $error'),
    );
  }

  /// Advances one outlet; the other outlet is never touched.
  @visibleForTesting
  void handle(TelemetryReading r) {
    final outlet = r.channel;
    final steady =
        r.isValid && r.state == 'ACTIVE' && r.isFresh(DateTime.now().toUtc());
    if (!r.isRunning) {
      // Run over: forget it, so the next appliance is identified afresh.
      _steady.remove(outlet);
      _asked.remove(outlet);
      _latest.remove(outlet);
      return;
    }
    if (!steady || _asked.contains(outlet)) return;
    final count = (_steady[outlet] ?? 0) + 1;
    _steady[outlet] = count;
    if (count < settleReadings) return;
    _asked.add(outlet);
    unawaited(_identify(r));
  }

  Future<void> _identify(TelemetryReading r) async {
    try {
      final match = await backend.matchSignature(r);
      if (!_asked.contains(r.channel)) return; // the run ended meanwhile
      _latest[r.channel] = match;
      _matches.add(match);
    } catch (error) {
      _asked.remove(r.channel); // retry on the next steady reading
      _steady.remove(r.channel);
      debugPrint('match-signature (${r.channel.key}): $error');
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _matches.close();
  }
}
