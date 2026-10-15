import 'dart:async';

import '../models/gadget_status.dart';

enum WifiProvisionStage {
  /// Saved to Firebase; waiting for the ESP32 to pick it up (it checks every 10 s).
  waitingForDevice,

  /// The ESP32 has the credentials and is switching networks.
  switching,

  /// Back online on the requested network.
  connected,

  /// Could not join the requested network; back on [WifiProvisionUpdate.network].
  rolledBack,

  /// The ESP32 never picked up the credentials (usually: it is offline).
  notReceived,

  /// The ESP32 took the credentials but did not come back online.
  noReconnect,
}

class WifiProvisionUpdate {
  final WifiProvisionStage stage;

  /// Network the ESP32 reported once back online.
  final String? network;
  const WifiProvisionUpdate(this.stage, {this.network});

  bool get isFinal =>
      stage != WifiProvisionStage.waitingForDevice &&
      stage != WifiProvisionStage.switching;
}

/// Follows a Wi-Fi change written to devices/gadget-1/wifiConfig.
///
/// The firmware acknowledges with `receivedAt == updatedAt` plus a server
/// `ackAt` time, then switches networks (rolling back after 20 s if the new
/// one fails). The first status published after `ackAt` therefore comes from
/// the new attempt, and its `wifiSSID` tells whether it succeeded.
Stream<WifiProvisionUpdate> trackWifiProvisioning({
  required Stream<Map<String, dynamic>> config,
  required Stream<GadgetStatus> status,
  required String ssid,
  Duration receiptTimeout = const Duration(seconds: 45),
  Duration reconnectTimeout = const Duration(seconds: 75),
}) async* {
  yield const WifiProvisionUpdate(WifiProvisionStage.waitingForDevice);
  final num ackAt;
  try {
    final acked = await config
        .firstWhere((c) {
          final updatedAt = c['updatedAt'];
          return updatedAt is num &&
              c['receivedAt'] == updatedAt &&
              c['ackAt'] is num;
        })
        .timeout(receiptTimeout);
    ackAt = acked['ackAt'] as num;
  } on TimeoutException {
    yield const WifiProvisionUpdate(WifiProvisionStage.notReceived);
    return;
  }
  yield const WifiProvisionUpdate(WifiProvisionStage.switching);
  try {
    final back = await status
        .firstWhere(
          (s) =>
              s.connectionStatus == 'Online' &&
              (s.lastSeen?.millisecondsSinceEpoch ?? 0) > ackAt,
        )
        .timeout(reconnectTimeout);
    yield WifiProvisionUpdate(
      back.wifiSSID == ssid
          ? WifiProvisionStage.connected
          : WifiProvisionStage.rolledBack,
      network: back.wifiSSID,
    );
  } on TimeoutException {
    yield const WifiProvisionUpdate(WifiProvisionStage.noReconnect);
  }
}
