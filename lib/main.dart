import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';
import 'package:wiseplug/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const WisePlugApp());
}

class WisePlugApp extends StatefulWidget {
  const WisePlugApp({super.key});

  @override
  State<WisePlugApp> createState() => _WisePlugAppState();
}

class _WisePlugAppState extends State<WisePlugApp> {
  bool darkMode = false;
  String currentDeviceID = "DEV_WISEPLUG_001";

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFF2F2F2),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
      ),
      home: WiseplugDeviceDashboard(
        deviceID: currentDeviceID,
        darkMode: darkMode,
        onDarkModeChanged: (val) => setState(() => darkMode = val),
      ),
    );
  }
}

class WiseplugDeviceDashboard extends StatefulWidget {
  final String deviceID;
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  const WiseplugDeviceDashboard({
    super.key,
    required this.deviceID,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  @override
  State<WiseplugDeviceDashboard> createState() =>
      _WiseplugDeviceDashboardState();
}

class _WiseplugDeviceDashboardState extends State<WiseplugDeviceDashboard> {
  final FirebaseBackendService _backend = FirebaseBackendService();
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ApplianceProfile>>(
      stream: _backend.streamApplianceProfiles(widget.deviceID),
      builder: (context, profileSnapshot) {
        final profiles = profileSnapshot.data ?? [];

        return StreamBuilder<TelemetryLog?>(
          stream: _backend.streamLatestTelemetry(widget.deviceID),
          builder: (context, telemetrySnapshot) {
            final telemetry = telemetrySnapshot.data;
            final double activePower = telemetry?.activePower ?? 0.0;

            return Scaffold(
              body: IndexedStack(
                index: _currentIndex,
                children: [
                  _buildHomeScreen(profiles, activePower),
                  ProfilesTab(
                    deviceID: widget.deviceID,
                    profiles: profiles,
                    backend: _backend,
                  ),
                  SettingsTab(
                    darkMode: widget.darkMode,
                    onDarkModeChanged: widget.onDarkModeChanged,
                  ),
                ],
              ),
              bottomNavigationBar: NavigationBar(
                selectedIndex: _currentIndex,
                onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.tune),
                    selectedIcon: Icon(Icons.tune),
                    label: 'Profiles',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: 'Settings',
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHomeScreen(List<ApplianceProfile> profiles, double activePower) {
    final activeCount = profiles.where((p) => p.isOn).length;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'WisePlug',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.notifications_outlined),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => setState(() => _currentIndex = 2),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'CURRENTLY CONNECTED — DUAL OUTLET',
            style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: ['A', 'B'].map((outletKey) {
              final profile = profiles.firstWhere(
                (p) => p.outlet == outletKey,
                orElse: () => ApplianceProfile(
                  profileID: '',
                  deviceID: widget.deviceID,
                  applianceName: 'Unassigned',
                  applianceType: 'Other',
                  outlet: outletKey,
                  isOn: false,
                ),
              );

              return Expanded(
                child: Card(
                  margin: EdgeInsets.only(right: outletKey == 'A' ? 8 : 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: profile.isOn ? Colors.orange.shade300 : Colors.grey.shade300,
                      width: 1.5,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Outlet $outletKey',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: profile.isOn ? Colors.orange : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          profile.applianceName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          profile.applianceType,
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const Divider(height: 16),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Safety Limit', style: TextStyle(fontSize: 10, color: Colors.grey)),
                            Text('2h total', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Remaining', style: TextStyle(fontSize: 10, color: Colors.grey)),
                            Text(
                              profile.isOn ? '38 min' : 'Idle',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: profile.isOn ? Colors.green.shade700 : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          '${activePower.toStringAsFixed(0)} W',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                        const Text('Total draw', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          '$activeCount / 2',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                        const Text('Outlets active', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Power Control',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (profiles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32.0),
              child: Center(child: Text('No appliances configured.', style: TextStyle(color: Colors.grey))),
            )
          else
            ...profiles.map(
              (profile) => Card(
                child: SwitchListTile(
                  title: Text('${profile.outlet == 'A' ? 'Outlet A' : 'Outlet B'} — ${profile.applianceName}'),
                  secondary: Icon(
                    Icons.power,
                    color: profile.outlet == 'A' ? Colors.blue : Colors.orange,
                  ),
                  value: profile.isOn,
                  onChanged: (val) {
                    _backend.toggleAppliancePower(profile.profileID, val);
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ProfilesTab extends StatelessWidget {
  final String deviceID;
  final List<ApplianceProfile> profiles;
  final FirebaseBackendService backend;

  const ProfilesTab({
    super.key,
    required this.deviceID,
    required this.profiles,
    required this.backend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text(
                'Appliance Profiles',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Profiles are automatically generated when appliances are registered.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: profiles.isEmpty
                  ? const Center(
                      child: Text(
                        'No appliance profiles registered.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: profiles.length,
                      itemBuilder: (context, index) {
                        final profile = profiles[index];
                        return Card(
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(color: Colors.grey.shade300),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.all(16),
                            leading: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(profile.icon, color: profile.color),
                            ),
                            title: Text(
                              profile.applianceName,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                'Outlet ${profile.outlet} • Threshold: ${profile.thresholdWattage.toStringAsFixed(0)}W\nSafety Limit: ${profile.safetyCeilingDuration}m',
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              onPressed: () => backend.removeProfile(profile.profileID),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsTab extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  const SettingsTab({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool deviceAlerts = true;
  bool alertStatusChanges = true;
  bool alertNewDevices = true;
  bool alertSafetyWarnings = true;

  void _showAlertDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Alert Types',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                title: const Text(
                  'Device status changes',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('When a device changes state'),
                value: alertStatusChanges,
                onChanged: (val) =>
                    setDialogState(() => alertStatusChanges = val ?? true),
              ),
              CheckboxListTile(
                title: const Text(
                  'New devices',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('When a new device is detected'),
                value: alertNewDevices,
                onChanged: (val) =>
                    setDialogState(() => alertNewDevices = val ?? true),
              ),
              CheckboxListTile(
                title: const Text(
                  'Safety warnings',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('When a device approaches its limit'),
                value: alertSafetyWarnings,
                onChanged: (val) =>
                    setDialogState(() => alertSafetyWarnings = val ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Done',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Settings',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text(
                    'Dark Mode',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('Reduce eye strain during night use'),
                  value: widget.darkMode,
                  onChanged: widget.onDarkModeChanged,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text(
                    'Device Alerts',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('Get notified about device changes'),
                  value: deviceAlerts,
                  onChanged: (val) => setState(() => deviceAlerts = val),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text(
                    'Alert Types',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Device changes, New devices, Safety warnings',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showAlertDialog,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.wifi),
                  title: const Text(
                    'Connected Device',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('WisePlug Dual Outlet'),
                  trailing: const Icon(Icons.check_circle, color: Colors.green),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text(
                    'App Version',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('v1.0.0'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}