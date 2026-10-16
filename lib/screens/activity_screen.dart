import 'package:flutter/material.dart';

import '../models/activity_event.dart';
import '../services/esp32_service.dart';

/// Persistent history written by the ESP32: safety alerts, new and recognized
/// appliances, and outlets switched on or off. Entries keep arriving while
/// the app is closed.
class ActivityScreen extends StatelessWidget {
  final Esp32Service service;

  /// Registered name for a firmware profile ID, or null when unknown.
  final String? Function(String profileID) nameFor;
  const ActivityScreen({
    super.key,
    required this.service,
    required this.nameFor,
  });

  static (IconData, Color) _look(ActivityCategory category) =>
      switch (category) {
        ActivityCategory.safety => (Icons.warning_amber_rounded, Colors.red),
        ActivityCategory.newAppliance => (Icons.fiber_new, Colors.orange),
        ActivityCategory.appliance => (Icons.power, const Color(0xFF00A4EF)),
        ActivityCategory.power => (Icons.toggle_on_outlined, Colors.grey),
      };

  Future<void> _clear(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('This removes all past activity entries.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (yes == true) await service.clearActivity();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Activity'),
      actions: [
        IconButton(
          tooltip: 'Clear history',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: () => _clear(context),
        ),
      ],
    ),
    body: StreamBuilder<List<ActivityEvent>>(
      stream: service.streamActivity(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _Message(
            'Cannot load the activity history. Check your connection and that '
            'the latest database rules are published.',
          );
        }
        final events = snapshot.data;
        if (events == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (events.isEmpty) {
          return const _Message(
            'No activity yet. Alerts, appliances turning on or off and new '
            'appliances will appear here.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: events.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
          itemBuilder: (context, i) {
            final event = events[i];
            final (icon, color) = _look(event.category);
            final name = event.profileID.isEmpty
                ? null
                : nameFor(event.profileID);
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              leading: CircleAvatar(
                backgroundColor: color.withValues(alpha: .14),
                child: Icon(icon, color: color),
              ),
              title: Text(
                event.title(name),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${formatEventTime(event.time)}'
                '${event.outlet.isEmpty ? '' : ' · Outlet ${event.outlet}'}',
              ),
            );
          },
        );
      },
    ),
  );
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.grey),
      ),
    ),
  );
}
