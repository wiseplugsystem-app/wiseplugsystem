import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/gadget_status.dart';
import '../services/device_binding.dart';
import '../services/esp32_service.dart';

/// Pushes home Wi-Fi credentials to devices/gadget-1/wifiConfig and follows
/// the ESP32 until it is back online on the new network (or rolled back).
/// The ESP32 saves them to flash so it reconnects after reboot, then removes
/// the password from the database.
class WifiConfigScreen extends StatefulWidget {
  final Esp32Service service;
  const WifiConfigScreen({super.key, required this.service});

  @override
  State<WifiConfigScreen> createState() => _WifiConfigScreenState();
}

class _WifiConfigScreenState extends State<WifiConfigScreen> {
  final _form = GlobalKey<FormState>();
  final _ssid = TextEditingController(), _password = TextEditingController();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Map<String, dynamic> _saved = {};
  GadgetStatus? _status;
  bool _busy = false, _obscure = true;
  String? _error;

  bool get _online => _status?.isOnline(DateTime.now()) == true;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        widget.service.streamWifiConfig().listen(
          (value) {
            if (!mounted) return;
            if (_saved.isEmpty && _ssid.text.isEmpty) {
              _ssid.text = value['ssid']?.toString() ?? '';
            }
            setState(() => _saved = value);
          },
          onError: (Object _) {
            if (mounted) {
              setState(() => _error = 'Cannot read the saved Wi-Fi settings.');
            }
          },
        ),
      )
      ..add(
        widget.service.streamGadgetStatus().listen((value) {
          if (mounted) setState(() => _status = value);
        }, onError: (Object _) {}),
      );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ssid = _ssid.text;
    try {
      final result = await showDialog<WifiProvisionUpdate>(
        context: context,
        barrierDismissible: false,
        builder: (_) => WifiProvisioningDialog(
          ssid: ssid,
          updates: widget.service.provisionWifi(ssid, _password.text),
        ),
      );
      if (result?.stage == WifiProvisionStage.connected) _password.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _status?.wifiSSID;
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi Configuration')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            Text(
              'Device: ${DeviceBinding.gadgetId}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _online
                  ? 'Online${current == null ? '' : ' · connected to $current'}'
                  : 'Offline',
              style: TextStyle(color: _online ? Colors.green : Colors.grey),
            ),
            if (_status != null && !_online)
              const Card(
                margin: EdgeInsets.only(top: 12),
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    'The WisePlug is offline, so it cannot receive settings from the app. '
                    'To set up Wi-Fi from scratch, join the "WisePlug-AP" Wi-Fi network '
                    'with your phone, open 192.168.4.1 if no page appears, and choose '
                    'your home network there.',
                  ),
                ),
              ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _ssid,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Wi-Fi network name (SSID)',
                helperText: '2.4 GHz networks only',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value == null ||
                      value.trim().isEmpty ||
                      utf8.encode(value).length > 32
                  ? 'Enter a network name up to 32 bytes.'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Wi-Fi password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (value) =>
                  value != null &&
                      value.isNotEmpty &&
                      (value.length < 8 || value.length > 63)
                  ? 'Use 8 to 63 characters, or leave empty for an open network.'
                  : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Sending…' : 'Send to WisePlug'),
            ),
            const SizedBox(height: 16),
            const Text(
              'The WisePlug saves the network and reconnects to it after every reboot. '
              'If it cannot join, it goes back to its previous network within about '
              '30 seconds so you can correct the details.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Progress for one Wi-Fi change; pops the final [WifiProvisionUpdate].
class WifiProvisioningDialog extends StatelessWidget {
  final String ssid;
  final Stream<WifiProvisionUpdate> updates;
  const WifiProvisioningDialog({
    super.key,
    required this.ssid,
    required this.updates,
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<WifiProvisionUpdate>(
    stream: updates,
    builder: (context, snapshot) {
      final update = snapshot.data;
      final (
        IconData? icon,
        Color color,
        String title,
        String message,
      ) = snapshot.hasError
          ? (
              Icons.error_outline,
              Colors.red,
              'Not sent',
              snapshot.error is ArgumentError
                  ? '${(snapshot.error as ArgumentError).message}'
                  : 'Could not save the settings: ${snapshot.error}',
            )
          : switch (update?.stage) {
              null => (null, Colors.grey, 'Sending…', 'Saving the settings.'),
              WifiProvisionStage.waitingForDevice => (
                null,
                Colors.grey,
                'Waiting for WisePlug…',
                'The WisePlug checks for new settings every 10 seconds.',
              ),
              WifiProvisionStage.switching => (
                null,
                Colors.grey,
                'Connecting to $ssid…',
                'The WisePlug received the settings and is switching networks. '
                    'This can take up to a minute.',
              ),
              WifiProvisionStage.connected => (
                Icons.check_circle,
                Colors.green,
                'Connected',
                'The WisePlug is online on $ssid and will reconnect to it after every reboot.',
              ),
              WifiProvisionStage.rolledBack => (
                Icons.wifi_off,
                Colors.orange,
                'Could not join $ssid',
                'The WisePlug went back to ${update!.network ?? 'its previous network'}. '
                    'Check the network name and password (2.4 GHz only) and try again.',
              ),
              WifiProvisionStage.notReceived => (
                Icons.timer_off,
                Colors.red,
                'No response',
                'The WisePlug did not pick up the settings. It must be online to receive '
                    'them; if it is offline, set up Wi-Fi through the "WisePlug-AP" network.',
              ),
              WifiProvisionStage.noReconnect => (
                Icons.timer_off,
                Colors.red,
                'Not back online',
                'The WisePlug received the settings but has not come back online. If it '
                    'stays offline, set up Wi-Fi through the "WisePlug-AP" network.',
              ),
            };
      final done = snapshot.hasError || update?.isFinal == true;
      return PopScope(
        canPop: done,
        child: AlertDialog(
          icon: icon == null
              ? const SizedBox.square(
                  dimension: 36,
                  child: CircularProgressIndicator(),
                )
              : Icon(icon, color: color, size: 40),
          title: Text(title),
          content: Text(message),
          actions: [
            if (done)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(update),
                child: const Text('OK'),
              ),
          ],
        ),
      );
    },
  );
}
