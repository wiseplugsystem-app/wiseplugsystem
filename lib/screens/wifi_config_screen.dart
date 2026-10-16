import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/gadget_status.dart';
import '../services/device_binding.dart';
import '../services/esp32_service.dart';
import '../services/local_provisioning.dart';

/// Sets the WisePlug's home Wi-Fi:
/// - Plug online: over the internet (devices/gadget-1/wifiConfig), followed
///   until the plug is back online on the new network.
/// - Plug offline or new: nearby setup. This device joins the plug's open
///   "wisewp" network; the app notices by itself, lists the networks the plug
///   can see, and sends the chosen one to http://192.168.4.1.
class WifiConfigScreen extends StatefulWidget {
  final Esp32Service service;
  final SetupNetworkClient setupClient;
  const WifiConfigScreen({
    super.key,
    required this.service,
    this.setupClient = const SetupNetworkClient(),
  });

  @override
  State<WifiConfigScreen> createState() => _WifiConfigScreenState();
}

class _WifiConfigScreenState extends State<WifiConfigScreen> {
  final _form = GlobalKey<FormState>();
  final _ssid = TextEditingController(), _password = TextEditingController();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  GadgetStatus? _status;
  bool _busy = false, _obscure = true, _prefilled = false;
  bool? _nearbyChoice;

  bool get _online => _status?.isOnline(DateTime.now()) == true;

  /// Nearby setup unless the user picked otherwise; the default follows the
  /// plug: online -> over the internet, offline -> nearby.
  bool get _nearby => _nearbyChoice ?? (_status != null && !_online);

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        widget.service.streamWifiConfig().listen((value) {
          if (!mounted || _prefilled) return;
          _prefilled = true;
          if (_ssid.text.isEmpty) _ssid.text = value['ssid']?.toString() ?? '';
        }, onError: (Object _) {}),
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
    setState(() => _busy = true);
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
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Text(
            _online
                ? '${DeviceBinding.gadgetId} is online${current == null ? '' : ' on "$current"'}'
                : '${DeviceBinding.gadgetId} is offline',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: _online ? Colors.green : Colors.grey,
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                icon: Icon(Icons.wifi_tethering),
                label: Text('Nearby setup'),
              ),
              ButtonSegment(
                value: false,
                icon: Icon(Icons.cloud_outlined),
                label: Text('Over the internet'),
              ),
            ],
            selected: {_nearby},
            onSelectionChanged: _busy
                ? null
                : (value) => setState(() => _nearbyChoice = value.single),
          ),
          const SizedBox(height: 20),
          if (_nearby)
            NearbySetupPanel(
              client: widget.setupClient,
              status: widget.service.streamGadgetStatus,
            )
          else
            Form(key: _form, child: _internetForm()),
        ],
      ),
    );
  }

  Widget _internetForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_status != null && !_online)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            'The WisePlug is offline, so it cannot receive settings over the '
            'internet. Use "Nearby setup".',
            style: TextStyle(color: Colors.orange),
          ),
        ),
      TextFormField(
        controller: _ssid,
        enabled: !_busy,
        decoration: const InputDecoration(
          labelText: 'Wi-Fi network name',
          helperText: 'Exactly as written, 2.4 GHz only',
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
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
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
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(_busy ? 'Sending…' : 'Send to WisePlug'),
      ),
      const SizedBox(height: 16),
      const Text(
        'The WisePlug keeps the new network after every reboot. If it cannot '
        'join, it returns to its previous network within about 30 seconds.',
        style: TextStyle(color: Colors.grey, fontSize: 12),
      ),
    ],
  );
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
                    'them; if it is offline, use "Nearby setup".',
              ),
              WifiProvisionStage.noReconnect => (
                Icons.timer_off,
                Colors.red,
                'Not back online',
                'The WisePlug received the settings but has not come back online. If it '
                    'stays offline, use "Nearby setup".',
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

/// Nearby setup in two steps: (1) join "wisewp", detected automatically,
/// then (2) tap a network the plug can see and type its password.
class NearbySetupPanel extends StatefulWidget {
  final SetupNetworkClient client;
  final Stream<GadgetStatus> Function() status;
  const NearbySetupPanel({
    super.key,
    required this.client,
    required this.status,
  });

  @override
  State<NearbySetupPanel> createState() => _NearbySetupPanelState();
}

class _NearbySetupPanelState extends State<NearbySetupPanel> {
  final _password = TextEditingController();
  final _manualName = TextEditingController();
  Timer? _poll;
  bool _joined = false, _searching = false, _sending = false, _manual = false;
  bool _obscure = true;
  List<NearbyNetwork>? _networks;
  NearbyNetwork? _chosen;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _password.dispose();
    _manualName.dispose();
    super.dispose();
  }

  /// Notices when this device joins (or leaves) "wisewp".
  Future<void> _check() async {
    final joined = await widget.client.isReachable();
    if (!mounted || joined == _joined) return;
    setState(() => _joined = joined);
    if (joined && _networks == null) await _search();
  }

  Future<void> _search({bool again = false}) async {
    setState(() => _searching = true);
    final networks = await widget.client.nearbyNetworks(refresh: again);
    if (!mounted) return;
    setState(() {
      _networks = networks;
      _searching = false;
    });
  }

  String get _ssid => _manual ? _manualName.text : _chosen?.ssid ?? '';
  bool get _needsPassword => _manual || (_chosen?.secure ?? false);

  Future<void> _connect() async {
    final ssid = _ssid;
    final password = _needsPassword ? _password.text : '';
    if (ssid.trim().isEmpty) {
      setState(() => _error = 'Choose your network first.');
      return;
    }
    if (_needsPassword && (password.length < 8 || password.length > 63)) {
      setState(() => _error = 'Wi-Fi passwords are 8 to 63 characters.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.client.send(ssid, password);
      _password.clear();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => DirectSetupDialog(ssid: ssid, status: widget.status()),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final networks = _networks ?? const <NearbyNetwork>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Step(
          number: 1,
          done: _joined,
          waiting: !_joined,
          title: _joined
              ? 'Connected to your WisePlug'
              : 'Join the "${SetupNetwork.ssid}" Wi-Fi',
          detail: _joined
              ? null
              : 'Open the Wi-Fi settings of this phone (or computer) and tap '
                    '"${SetupNetwork.ssid}". No password is needed. Then come back: '
                    'this page notices by itself.\n'
                    'Tip: a WisePlug page may open on its own; you can finish there too.',
        ),
        const SizedBox(height: 14),
        _Step(
          number: 2,
          done: false,
          enabled: _joined,
          title: 'Choose your home Wi-Fi',
        ),
        if (_joined) ...[
          const SizedBox(height: 8),
          if (_searching) const LinearProgressIndicator(),
          for (final n in networks)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 3),
              color: !_manual && _chosen?.ssid == n.ssid
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: ListTile(
                leading: Icon(
                  const [
                    Icons.wifi_1_bar,
                    Icons.wifi_2_bar,
                    Icons.wifi,
                  ][n.bars - 1],
                ),
                title: Text(n.ssid),
                trailing: n.secure ? const Icon(Icons.lock_outline) : null,
                onTap: _sending
                    ? null
                    : () => setState(() {
                        _manual = false;
                        _chosen = n;
                        _error = null;
                      }),
              ),
            ),
          if (!_searching && networks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No 2.4 GHz networks found. Check that your router\'s 2.4 GHz '
                'band is on, then search again.',
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _searching || _sending
                    ? null
                    : () => _search(again: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Search again'),
              ),
              TextButton(
                onPressed: _sending
                    ? null
                    : () => setState(() {
                        _manual = true;
                        _chosen = null;
                      }),
                child: const Text('My network is not listed'),
              ),
            ],
          ),
          if (_manual)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _manualName,
                decoration: const InputDecoration(
                  labelText: 'Network name, exactly as written',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          if (_needsPassword) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscure,
              enabled: !_sending,
              decoration: InputDecoration(
                labelText: _manual
                    ? 'Wi-Fi password'
                    : 'Password for ${_chosen!.ssid}',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _connect(),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _sending || (_chosen == null && !_manual)
                ? null
                : _connect,
            child: Text(_sending ? 'Sending…' : 'Connect'),
          ),
        ],
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final bool done, enabled, waiting;
  final String title;
  final String? detail;
  const _Step({
    required this.number,
    required this.done,
    required this.title,
    this.detail,
    this.enabled = true,
    this.waiting = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = done
        ? Colors.green
        : enabled
        ? Theme.of(context).colorScheme.primary
        : Colors.grey;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 15,
          backgroundColor: color,
          child: done
              ? const Icon(Icons.check, size: 18, color: Colors.white)
              : Text('$number', style: const TextStyle(color: Colors.white)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: enabled ? null : Colors.grey,
                        ),
                      ),
                    ),
                    if (waiting) ...[
                      const SizedBox(width: 10),
                      const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  detail!,
                  style: const TextStyle(color: Colors.grey, height: 1.4),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// After nearby setup: waits until the plug reports in on [ssid]. That needs
/// this device back on a network with internet, so it is not a timeout.
class DirectSetupDialog extends StatelessWidget {
  final String ssid;
  final Stream<GadgetStatus> status;
  const DirectSetupDialog({
    super.key,
    required this.ssid,
    required this.status,
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<GadgetStatus>(
    stream: status,
    builder: (context, snapshot) {
      final s = snapshot.data;
      final connected =
          s != null && s.isOnline(DateTime.now()) && s.wifiSSID == ssid;
      return AlertDialog(
        icon: connected
            ? const Icon(Icons.check_circle, color: Colors.green, size: 40)
            : const SizedBox.square(
                dimension: 36,
                child: CircularProgressIndicator(),
              ),
        title: Text(connected ? 'Connected' : 'Almost done'),
        content: Text(
          connected
              ? 'The WisePlug is online on "$ssid".'
              : 'The WisePlug is joining "$ssid". Switch this device back to your '
                    'home Wi-Fi; this turns into "Connected" once the WisePlug is '
                    'online. If "${SetupNetwork.ssid}" appears again, the password '
                    'was wrong: join it and try again.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(connected ? 'Done' : 'Close'),
          ),
        ],
      );
    },
  );
}
