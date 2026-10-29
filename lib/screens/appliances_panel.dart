import 'dart:async';

import 'package:flutter/material.dart';

import '../models/recognition.dart';
import '../services/recognition_service.dart';
import 'register_appliance_screen.dart';

/// The Appliances tab: the user's registered appliances (from Supabase),
/// which outlet each is on, and management (register, rename, safe operating
/// time, add or delete a mode, delete).
class AppliancesPanel extends StatefulWidget {
  final RecognitionService service;
  final RecognitionSettings settings;

  /// Re-read when this changes (e.g. an outlet's run started or ended).
  final Object? refreshKey;
  const AppliancesPanel({
    super.key,
    required this.service,
    this.settings = const RecognitionSettings(),
    this.refreshKey,
  });

  @override
  State<AppliancesPanel> createState() => _AppliancesPanelState();
}

class _AppliancesPanelState extends State<AppliancesPanel> {
  List<RegisteredAppliance>? _appliances;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AppliancesPanel old) {
    super.didUpdateWidget(old);
    if (old.refreshKey != widget.refreshKey) _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.service.appliances();
      if (mounted) {
        setState(() {
          _appliances = list;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Cannot load appliances. $error');
    }
  }

  Future<void> _register({RegisteredAppliance? appliance, String? mode}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => RegisterApplianceScreen(
          service: widget.service,
          appliance: appliance,
          modeName: mode,
          outlet: appliance?.lastOutlet == null
              ? 'A'
              : outletLetter(appliance!.lastOutlet!),
          settings: widget.settings,
        ),
      ),
    );
    _load();
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error'.replaceFirst('Bad state: ', ''))),
        );
      }
    }
    _load();
  }

  Future<String?> _ask(
    String title,
    String label,
    String initial, {
    bool number = false,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<bool> _sure(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
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
      ) ==
      true;

  Future<void> _menu(RegisteredAppliance a, String action) async {
    switch (action) {
      case 'rename':
        final name = await _ask('Rename ${a.name}', 'Name', a.name);
        if (name != null && name.isNotEmpty && name != a.name) {
          await _run(
            () => widget.service.rename(a.id, name),
            'Renamed to $name.',
          );
        }
      case 'cutoff':
        final value = await _ask(
          'Safe operating time',
          'Minutes (1-10080)',
          '${a.cutoffMinutes}',
          number: true,
        );
        final minutes = int.tryParse(value ?? '');
        if (minutes != null) {
          await _run(
            () => widget.service.setCutoff(a.id, minutes),
            'Saved. It applies from its next confirmed run.',
          );
        }
      case 'mode':
        await _register(appliance: a);
      case 'delete':
        if (await _sure(
          'Delete ${a.name}?',
          'WisePlug forgets its signature and its usage learning. If it is '
              'plugged in again it will be treated as a new appliance.',
        )) {
          await _run(
            () => widget.service.deleteAppliance(a.id),
            '${a.name} deleted.',
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _appliances;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () => _register(),
          icon: const Icon(Icons.add),
          label: const Text('Register new appliance'),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red))
        else if (list == null)
          const LinearProgressIndicator()
        else if (list.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'No appliances yet. Register one: WisePlug measures it a few '
                'times and then recognises it on either outlet.',
              ),
            ),
          )
        else
          for (final a in list) ...[
            _ApplianceCard(
              appliance: a,
              required: widget.settings.registrationSamples,
              defaultMinutes: widget.settings.defaultCutoffMinutes,
              onMenu: (action) => _menu(a, action),
              onContinue: (mode) => _register(appliance: a, mode: mode.name),
              onDeleteMode: (mode) async {
                if (await _sure(
                  'Delete mode ${mode.name}?',
                  '${a.name} will no longer be recognised in this mode.',
                )) {
                  await _run(
                    () => widget.service.deleteMode(a.id, mode.id),
                    'Mode ${mode.name} deleted.',
                  );
                }
              },
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class _ApplianceCard extends StatelessWidget {
  final RegisteredAppliance appliance;
  final int required, defaultMinutes;
  final ValueChanged<String> onMenu;
  final ValueChanged<ApplianceMode> onContinue, onDeleteMode;
  const _ApplianceCard({
    required this.appliance,
    required this.required,
    required this.defaultMinutes,
    required this.onMenu,
    required this.onContinue,
    required this.onDeleteMode,
  });

  static String _time(int minutes) => minutes % 60 == 0
      ? '${minutes ~/ 60} h'
      : minutes > 60
      ? '${minutes ~/ 60} h ${minutes % 60} min'
      : '$minutes min';

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    // Which outlet: the one it runs on now, else the one it was last used on.
    final where = a.runningOn != null
        ? 'On Outlet ${outletLetter(a.runningOn!)} now'
        : a.lastOutlet != null
        ? 'Last used on Outlet ${outletLetter(a.lastOutlet!)}'
        : 'Not used yet';
    final learned = a.isLearned && a.baselineRuntimeSeconds != null
        ? 'Typical use ${_time((a.baselineRuntimeSeconds! / 60).ceil())}'
        : 'Learning its usual runtime: ${a.useCount} uses so far';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  a.runningOn != null ? Icons.power : Icons.power_outlined,
                  color: a.runningOn != null ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${a.typeName} · $where',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Manage ${a.name}',
                  onSelected: onMenu,
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(
                      value: 'cutoff',
                      child: Text('Safe operating time'),
                    ),
                    const PopupMenuItem(
                      value: 'mode',
                      child: Text('Add a mode'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: a.runningOn == null,
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Safe operating time: ${_time(a.cutoffMinutes)}'),
            Text(
              learned,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final m in a.modes)
                  m.sampleCount >= required
                      ? InputChip(
                          label: Text(
                            '${m.name}'
                            '${m.meanPowerW == null ? '' : ' · ${m.meanPowerW!.toStringAsFixed(1)} W'}',
                          ),
                          onDeleted: a.modes.length > 1 && a.runningOn == null
                              ? () => onDeleteMode(m)
                              : null,
                        )
                      : ActionChip(
                          avatar: const Icon(Icons.play_arrow, size: 18),
                          label: Text(
                            '${m.name}: ${m.sampleCount} of $required samples · continue',
                          ),
                          onPressed: () => onContinue(m),
                        ),
              ],
            ),
            if (!a.isReady(required))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Not recognised yet: until registration is complete it runs '
                  'on the $defaultMinutes-minute safety limit.',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
