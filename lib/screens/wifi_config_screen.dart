import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/device_binding.dart';
import '../services/esp32_service.dart';

/// Pushes home Wi-Fi credentials to devices/gadget-1/wifiConfig. The ESP32
/// saves them to flash so it reconnects after reboot, then removes the
/// password from the database.
class WifiConfigScreen extends StatefulWidget {
  final Esp32Service service;
  const WifiConfigScreen({super.key, required this.service});

  @override
  State<WifiConfigScreen> createState() => _WifiConfigScreenState();
}

class _WifiConfigScreenState extends State<WifiConfigScreen> {
  final _form = GlobalKey<FormState>();
  final _ssid = TextEditingController(), _password = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Map<String, dynamic> _saved = {};
  bool _busy = false, _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.streamWifiConfig().listen(
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
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
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
    try {
      await widget.service.saveWifiConfig(_ssid.text, _password.text);
      _password.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wi-Fi settings sent to WisePlug.')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ArgumentError ? '${error.message}' : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final updatedAt = _saved['updatedAt'];
    final received = updatedAt != null && _saved['receivedAt'] == updatedAt;
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
            if (_saved['ssid'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Last sent network: ${_saved['ssid']} · '
                  '${received ? 'received by WisePlug' : 'waiting for WisePlug'}',
                  style: TextStyle(
                    color: received ? Colors.green : Colors.grey,
                  ),
                ),
              ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _ssid,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Wi-Fi network name (SSID)',
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
              'The WisePlug must be online to receive new settings. It saves them, '
              'switches networks, and reconnects to them after every reboot. If it '
              'cannot join the new network, it falls back to its built-in network '
              'so you can send corrected details.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
