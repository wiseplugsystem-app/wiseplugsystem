import 'package:flutter/material.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';

class HomeTab extends StatelessWidget {
  final String deviceID;
  final List<ApplianceProfile> profiles;
  final double activePower;
  final FirebaseBackendService backend;
  final VoidCallback onSettingsTap;

  const HomeTab({
    super.key,
    required this.deviceID,
    required this.profiles,
    required this.activePower,
    required this.backend,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final activeCount = profiles.where((p) => p.isOn).length;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          // Top Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    'Wise',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  const Text(
                    'Plug',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined, size: 26),
                onPressed: onSettingsTap,
              ),
            ],
          ),
          const SizedBox(height: 15),
          const Text(
            'CURRENTLY CONNECTED — DUAL OUTLET',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          // Real-time Summary Cards
          Row(
            children: [
              Expanded(
                child: SummaryCard(
                  value: '${activePower.toStringAsFixed(1)} W',
                  label: 'Total draw',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SummaryCard(
                  value: '$activeCount / ${profiles.length}',
                  label: 'Outlets active',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Active Anomaly Alerts Banner Stream
          StreamBuilder<List<AnomalyAlert>>(
            stream: backend.streamActiveAlerts(deviceID),
            builder: (context, snapshot) {
              final alerts = snapshot.data ?? [];
              if (alerts.isEmpty) return const SizedBox.shrink();

              return Column(
                children: alerts.map((alert) => Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.red),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.red),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              alert.alertType,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.red,
                              ),
                            ),
                            Text(
                              'Triggered: ${alert.triggerTime.hour}:${alert.triggerTime.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 12, color: Colors.black87),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          // Request a Smart Override (extend by 15 mins)
                          final override = SmartOverride(
                            overrideID: DateTime.now().millisecondsSinceEpoch.toString(),
                            alertID: alert.alertID,
                            userID: 'USER_001',
                            extensionDuration: 15,
                          );
                          backend.requestSmartOverride(override);
                        },
                        child: const Text('Override'),
                      ),
                    ],
                  ),
                )).toList(),
              );
            },
          ),

          // Power Control Section
          const Text(
            'Power Control',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          if (profiles.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(20.0),
                child: Text('No appliances configured yet.'),
              ),
            )
          else
            ...profiles.map((profile) => Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: SwitchListTile(
                    title: Text(
                      profile.applianceName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'Outlet ${profile.outlet} • ${profile.applianceType} (${profile.isOn ? 'Active' : 'Idle'})',
                    ),
                    secondary: CircleAvatar(
                      backgroundColor: profile.color.withValues(alpha: 0.15),
                      child: Icon(profile.icon, color: profile.color),
                    ),
                    value: profile.isOn,
                    onChanged: (val) {
                      backend.toggleAppliancePower(profile.profileID, val);
                    },
                  ),
                )),
        ],
      ),
    );
  }
}

class SummaryCard extends StatelessWidget {
  final String value;
  final String label;

  const SummaryCard({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: 0,
      color: isDark ? Colors.grey.shade900 : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}