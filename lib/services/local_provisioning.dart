import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'device_binding.dart';

/// Binding only when near: asks the WisePlug for its one-time pairing code
/// over the local network (its "wisewp" setup Wi-Fi, or the same home Wi-Fi).
/// The plug answers a UDP message on [port]; a phone far away never hears it.
class NearbyPairing {
  static const port = 47269;
  static const request = 'WISEPLUG-PAIR';

  /// The plug's pairing code, or null when no WisePlug answered.
  static Future<String?> requestCode({
    Duration wait = const Duration(seconds: 3),
    int tries = 3,
  }) async {
    for (var i = 0; i < tries; i++) {
      RawDatagramSocket? socket;
      try {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        socket.broadcastEnabled = true;
        final reply = Completer<String?>();
        final s = socket;
        s.listen((event) {
          if (event != RawSocketEvent.read) return;
          final d = s.receive();
          if (d == null || reply.isCompleted) return;
          try {
            final body = jsonDecode(utf8.decode(d.data));
            if (body is Map &&
                body['device'] == DeviceBinding.gadgetId &&
                body['code'] is String) {
              reply.complete(body['code'] as String);
            }
          } catch (_) {}
        });
        final message = utf8.encode('$request ${DeviceBinding.gadgetId}');
        for (final to in [
          InternetAddress('255.255.255.255'),
          InternetAddress('192.168.4.1'),
        ]) {
          try {
            s.send(message, to, port);
          } catch (_) {}
        }
        final code = await reply.future.timeout(wait, onTimeout: () => null);
        if (code != null) return code;
      } catch (_) {
        // No network: try again, then give up.
      } finally {
        socket?.close();
      }
    }
    return null;
  }
}

/// The WisePlug's own open setup Wi-Fi, up while it cannot reach a router.
class SetupNetwork {
  static const ssid = 'wisewp';
  static final address = Uri.parse('http://192.168.4.1');
}

class LocalProvisioningException implements Exception {
  final String message;
  const LocalProvisioningException(this.message);
  @override
  String toString() => message;
}

/// A Wi-Fi network the plug can hear (always 2.4 GHz).
class NearbyNetwork {
  final String ssid; // exact, including any spaces
  final int rssi;
  final bool secure;
  const NearbyNetwork(this.ssid, {this.rssi = -70, this.secure = true});

  /// 1 (weak) to 3 (strong) bars.
  int get bars => rssi > -60
      ? 3
      : rssi > -75
      ? 2
      : 1;
}

/// Talks to the plug at http://192.168.4.1 while this device is joined to
/// "wisewp". Works with no internet.
class SetupNetworkClient {
  final http.Client? client;
  const SetupNetworkClient({this.client});

  Future<T> _use<T>(Future<T> Function(http.Client client) body) async {
    final http_ = client ?? http.Client();
    try {
      return await body(http_);
    } finally {
      if (client == null) http_.close();
    }
  }

  /// True when this device can reach the plug, i.e. it is joined to "wisewp".
  Future<bool> isReachable() async {
    try {
      return await _use((client) async {
        final response = await client
            .get(SetupNetwork.address.resolve('/status'))
            .timeout(const Duration(seconds: 2));
        final body = jsonDecode(response.body);
        return body is Map && body['mode'] == 'setup';
      });
    } catch (_) {
      return false;
    }
  }

  /// Networks the plug can see, strongest first.
  Future<List<NearbyNetwork>> nearbyNetworks({bool refresh = false}) async {
    try {
      return await _use((client) async {
        final response = await client
            .get(
              SetupNetwork.address.resolve(
                refresh ? '/networks?refresh=1' : '/networks',
              ),
            )
            .timeout(const Duration(seconds: 12)); // a scan takes a few seconds
        return [
          for (final n in jsonDecode(response.body) as List)
            if (n is Map && n['ssid'] is String)
              NearbyNetwork(
                n['ssid'] as String,
                rssi: (n['rssi'] as num?)?.toInt() ?? -70,
                secure: n['secure'] != false,
              ),
        ];
      });
    } catch (_) {
      return const [];
    }
  }

  /// Sends the home Wi-Fi to the plug (`POST /save-wifi`).
  Future<void> send(String ssid, String password) async {
    final Map<String, dynamic> reply;
    try {
      reply = await _use((client) async {
        final response = await client
            .post(
              SetupNetwork.address.resolve('/save-wifi'),
              // Form encoding keeps this a "simple" request: no CORS preflight.
              body: {'ssid': ssid, 'password': password, 'app': '1'},
            )
            .timeout(const Duration(seconds: 10));
        return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      });
    } catch (_) {
      throw const LocalProvisioningException(
        'Lost the connection to the WisePlug. Make sure this device is still '
        'joined to "${SetupNetwork.ssid}" and try again.',
      );
    }
    if (reply['ok'] != true) {
      throw LocalProvisioningException(
        reply['error']?.toString() ?? 'The WisePlug rejected the details.',
      );
    }
  }
}
