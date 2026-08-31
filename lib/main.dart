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
  bool notifications = true;
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

/// Represents the WiseplugDevice controller dashboard
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

  void _showAddProfileDialog() {
    final nameController = TextEditingController();
    String selectedType = 'Electric Fan';
    String selectedOutlet = 'A';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Appliance Profile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Appliance Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selectedType,
                decoration: const InputDecoration(
                  labelText: 'Appliance Type',
                  border: OutlineInputBorder(),
                ),
                items: ['Rice cooker', 'Flat Iron', 'Electric Fan', 'Other']
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) setDialogState(() => selectedType = val);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selectedOutlet,
                decoration: const InputDecoration(
                  labelText: 'Assigned Outlet',
                  border: OutlineInputBorder(),
                ),
                items: ['A', 'B']
                    .map((o) => DropdownMenuItem(value: o, child: Text('Outlet $o')))
                    .toList(),
                onChanged: (val) {
                  if (val != null) setDialogState(() => selectedOutlet = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.trim().isNotEmpty) {
                  final newProfile = ApplianceProfile(
                    profileID: DateTime.now().millisecondsSinceEpoch.toString(),
                    deviceID: widget.deviceID,
                    applianceName: nameController.text.trim(),
                    applianceType: selectedType,
                    outlet: selectedOutlet,
                  );
                  _backend.saveProfile(newProfile);
                  Navigator.pop(context);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<List<ApplianceProfile>>(
        stream: _backend.streamApplianceProfiles(widget.deviceID),
        builder: (context, profileSnapshot) {
          final profiles = profileSnapshot.data ?? [];

          return StreamBuilder<TelemetryLog?>(
            stream: _backend.streamLatestTelemetry(widget.deviceID),
            builder: (context, telemetrySnapshot) {
              final telemetry = telemetrySnapshot.data;
              final double activePower = telemetry?.activePower ?? 0.0;

              return IndexedStack(
                index: _currentIndex,
                children: [
                  _buildHomeScreen(profiles, activePower),
                  _buildProfilesScreen(profiles),
                  _buildSettingsScreen(),
                ],
              );
            },
          );
        },
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
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => setState(() => _currentIndex = 2),
              ),
            ],
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
                          '${activePower.toStringAsFixed(1)} W',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text('Total Draw', style: TextStyle(color: Colors.grey)),
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
                          '$activeCount Active',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text('Outlets Running', style: TextStyle(color: Colors.grey)),
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
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          ...profiles.map(
            (profile) => Card(
              child: SwitchListTile(
                title: Text(profile.applianceName),
                subtitle: Text('Outlet ${profile.outlet} • ${profile.applianceType}'),
                secondary: Icon(profile.icon, color: profile.color),
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

  Widget _buildProfilesScreen(List<ApplianceProfile> profiles) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Appliance Profiles',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.add_circle_outline,
                    color: Colors.blue,
                    size: 28,
                  ),
                  onPressed: _showAddProfileDialog,
                ),
              ],
            ),
          ),
          Expanded(
            child: profiles.isEmpty
                ? const Center(child: Text('No appliance profiles registered.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    itemCount: profiles.length,
                    itemBuilder: (context, index) {
                      final profile = profiles[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: Icon(profile.icon, color: profile.color),
                          title: Text(profile.applianceName),
                          subtitle: Text(
                            'Threshold: ${profile.thresholdWattage}W | Safety Limit: ${profile.safetyCeilingDuration}m',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed: () =>
                                _backend.removeProfile(profile.profileID),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text(
            'Settings',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              title: const Text('Dark Mode'),
              value: widget.darkMode,
              onChanged: widget.onDarkModeChanged,
            ),
          ),
        ],
      ),
    );
  }
}