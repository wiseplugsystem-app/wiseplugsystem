import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/gadget_status.dart';
import 'package:wiseplug/screens/wifi_config_screen.dart';
import 'package:wiseplug/services/wifi_provisioning.dart';

const updatedAt = 1792060000000, ackAt = 1792060008000;

GadgetStatus online(int lastSeen, String ssid) => GadgetStatus(
  connectionStatus: 'Online',
  lastSeen: DateTime.fromMillisecondsSinceEpoch(lastSeen, isUtc: true),
  wifiSSID: ssid,
);

Future<List<WifiProvisionStage>> run({
  required List<Map<String, dynamic>> config,
  required List<GadgetStatus> status,
}) => trackWifiProvisioning(
  config: Stream.fromIterable(config),
  status: Stream.fromIterable(status),
  ssid: 'HomeNet',
  receiptTimeout: const Duration(milliseconds: 50),
  reconnectTimeout: const Duration(milliseconds: 50),
).map((u) => u.stage).toList();

const sent = {'ssid': 'HomeNet', 'updatedAt': updatedAt};
const acked = {
  'ssid': 'HomeNet',
  'updatedAt': updatedAt,
  'receivedAt': updatedAt,
  'ackAt': ackAt,
};

void main() {
  test('confirms only once back online on the requested network', () async {
    expect(
      await run(
        config: [sent, acked],
        // A status from before the switch (old network) must be ignored.
        status: [
          online(ackAt - 500, 'OldNet'),
          online(ackAt + 9000, 'HomeNet'),
        ],
      ),
      [
        WifiProvisionStage.waitingForDevice,
        WifiProvisionStage.switching,
        WifiProvisionStage.connected,
      ],
    );
  });

  test('reports a rollback to the previous network', () async {
    final updates = await trackWifiProvisioning(
      config: Stream.fromIterable([acked]),
      status: Stream.fromIterable([online(ackAt + 25000, 'OldNet')]),
      ssid: 'HomeNet',
    ).toList();
    expect(updates.last.stage, WifiProvisionStage.rolledBack);
    expect(updates.last.network, 'OldNet');
  });

  test('times out when the device never picks the settings up', () async {
    final config = StreamController<Map<String, dynamic>>();
    config.add(sent); // no acknowledgement: device offline
    final stages = await trackWifiProvisioning(
      config: config.stream,
      status: const Stream.empty(),
      ssid: 'HomeNet',
      receiptTimeout: const Duration(milliseconds: 50),
    ).map((u) => u.stage).toList();
    expect(stages.last, WifiProvisionStage.notReceived);
    await config.close();
  });

  test('times out when the device does not come back online', () async {
    final status = StreamController<GadgetStatus>();
    status.add(online(ackAt - 500, 'OldNet')); // only the pre-switch status
    final stages = await trackWifiProvisioning(
      config: Stream.fromIterable([acked]),
      status: status.stream,
      ssid: 'HomeNet',
      reconnectTimeout: const Duration(milliseconds: 50),
    ).map((u) => u.stage).toList();
    expect(stages.last, WifiProvisionStage.noReconnect);
    await status.close();
  });

  testWidgets('dialog shows progress, then a success confirmation', (
    tester,
  ) async {
    final updates = StreamController<WifiProvisionUpdate>.broadcast();
    WifiProvisionUpdate? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog(
              context: context,
              builder: (_) => WifiProvisioningDialog(
                ssid: 'HomeNet',
                updates: updates.stream,
              ),
            ),
            child: const Text('send'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('send'));
    await tester.pump();
    updates.add(const WifiProvisionUpdate(WifiProvisionStage.switching));
    await tester.pump();
    expect(find.text('Connecting to HomeNet…'), findsOneWidget);
    expect(find.text('OK'), findsNothing);
    updates.add(
      const WifiProvisionUpdate(
        WifiProvisionStage.connected,
        network: 'HomeNet',
      ),
    );
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(result?.stage, WifiProvisionStage.connected);
    await updates.close();
  });
}
