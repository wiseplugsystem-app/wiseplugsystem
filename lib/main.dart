import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'models.dart';
import 'firebase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // Connects to your wiseplug-capstone project
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
  String currentDeviceID = "DEV_WISEPLUG_001"; // WiseplugDevice primary key

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

/// Represents the WiseplugDevice controller from the Class Diagram
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
  State<WiseplugDeviceDashboard> createState() => _WiseplugDeviceDashboardState();
}

class _WiseplugDeviceDashboardState extends State<WiseplugDeviceDashboard> {
  final FirebaseBackendService _backend = FirebaseBackendService();
  int _currentIndex = 0;

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
                  // --- Home Tab ---
                  _buildHomeScreen(profiles, activePower),

                  // --- Profiles Management Tab ---
                  _buildProfilesScreen(profiles),

                  // --- Settings Tab ---
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
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.tune), selectedIcon: Icon(Icons.tune), label: 'Profiles'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
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
              const Text('WisePlug', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.blue)),
              IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => setState(() => _currentIndex = 2)),
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
                        Text('${activePower.toStringAsFixed(1)} W', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
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
                        Text('$activeCount Active', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                        const Text('Outlets Running', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Power Control', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          ...profiles.map((profile) => Card(
                child: SwitchListTile(
                  title: Text(profile.applianceName),
                  subtitle: Text('Outlet ${profile.outlet} • ${profile.applianceType}'),
                  secondary: Icon(profile.icon, color: profile.color),
                  value: profile.isOn,
                  onChanged: (val) {
                    _backend.toggleAppliancePower(profile.profileID, val);
                  },
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildProfilesScreen(List<ApplianceProfile> profiles) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Appliance Profiles', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, color: Colors.blue, size: 28),
                onPressed: () {
                  // Prompt to register a new profile
                  _backend.saveProfile(
                    ApplianceProfile(
                      profileID: '',
                      deviceID: widget.deviceID,
                      applianceName: 'New Device',
                      applianceType: 'Electric Fan',
                      outlet: 'A',
                    ),
                  );
                },
              )
            ],
          ),
          const SizedBox(height: 16),
          ...profiles.map((profile) => Card(
                child: ListTile(
                  leading: Icon(profile.icon, color: profile.color),
                  title: Text(profile.applianceName),
                  subtitle: Text('Threshold: ${profile.thresholdWattage}W | Safety Limit: ${profile.safetyCeilingDuration}m'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _backend.removeProfile(profile.profileID),
                  ),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text('Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
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