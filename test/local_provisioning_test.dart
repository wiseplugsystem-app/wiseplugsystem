import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wiseplug/models/gadget_status.dart';
import 'package:wiseplug/screens/wifi_config_screen.dart';
import 'package:wiseplug/services/esp32_service.dart';
import 'package:wiseplug/services/local_provisioning.dart';

class OfflinePlug extends Fake implements Esp32Service {
  final status = StreamController<GadgetStatus>.broadcast();
  @override
  Stream<Map<String, dynamic>> streamWifiConfig() => Stream.value({});
  @override
  Stream<GadgetStatus> streamGadgetStatus() => status.stream;
}

/// The plug's setup server at 192.168.4.1. Unreachable until [joined].
class FakePlugServer {
  bool joined = false;
  final sent = <Map<String, String>>[];
  late final client = MockClient((request) async {
    if (!joined) throw http.ClientException('no route to host');
    switch (request.url.path) {
      case '/status':
        return http.Response('{"device":"gadget-1","mode":"setup"}', 200);
      case '/networks':
        // Real-world trap: the router's name ends with a space.
        return http.Response(
          '[{"ssid":"Freires ","rssi":-48,"secure":true},'
          '{"ssid":"Cafe","rssi":-80,"secure":false}]',
          200,
        );
      case '/save-wifi':
        sent.add(request.bodyFields);
        return http.Response('{"ok":true,"device":"gadget-1"}', 200);
    }
    return http.Response('', 404);
  });
}

void main() {
  test('lists the networks the plug can see, exact names kept', () async {
    final server = FakePlugServer()..joined = true;
    final client = SetupNetworkClient(client: server.client);
    expect(await client.isReachable(), isTrue);
    final networks = await client.nearbyNetworks();
    expect(networks.map((n) => n.ssid), ['Freires ', 'Cafe']);
    expect(networks.first.bars, 3);
    expect(networks.last.secure, isFalse);
  });

  test('not joined to wisewp: unreachable, empty list, clear error', () async {
    final client = SetupNetworkClient(client: FakePlugServer().client);
    expect(await client.isReachable(), isFalse);
    expect(await client.nearbyNetworks(), isEmpty);
    expect(
      () => client.send('Home', 'secret123'),
      throwsA(
        isA<LocalProvisioningException>().having(
          (e) => e.message,
          'message',
          contains('joined to "wisewp"'),
        ),
      ),
    );
  });

  test('reports the plug\'s own validation error', () async {
    final client = SetupNetworkClient(
      client: MockClient(
        (_) async => http.Response(
          '{"ok":false,"error":"Wi-Fi passwords are 8 to 63 characters."}',
          400,
        ),
      ),
    );
    expect(
      () => client.send('Home', 'short'),
      throwsA(
        isA<LocalProvisioningException>().having(
          (e) => e.message,
          'message',
          'Wi-Fi passwords are 8 to 63 characters.',
        ),
      ),
    );
  });

  testWidgets('nearby setup: detect the join, tap a network, connect', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final plug = OfflinePlug();
    final server = FakePlugServer();
    await tester.pumpWidget(
      MaterialApp(
        home: WifiConfigScreen(
          service: plug,
          setupClient: SetupNetworkClient(client: server.client),
        ),
      ),
    );
    plug.status.add(const GadgetStatus()); // offline: nearby setup is default
    await tester.pump();
    expect(find.text('Join the "wisewp" Wi-Fi'), findsOneWidget);
    expect(find.text('Freires '), findsNothing);

    server.joined = true; // the user joins "wisewp" in the phone's settings
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Connected to your WisePlug'), findsOneWidget);

    await tester.tap(find.text('Freires '));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'secret123');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(server.sent.single, {
      'ssid': 'Freires ', // trailing space preserved
      'password': 'secret123',
      'app': '1',
    });
    expect(find.text('Almost done'), findsOneWidget);
    plug.status.add(
      GadgetStatus(
        connectionStatus: 'Online',
        lastSeen: DateTime.now(),
        wifiSSID: 'Freires ',
      ),
    );
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox()); // stops the join polling
    await plug.status.close();
  });
}
