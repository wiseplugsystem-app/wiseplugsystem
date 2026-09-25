import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';
import 'package:wiseplug/firebase_options.dart';

import 'screens/home_tab.dart';
import 'screens/profiles_tab.dart';
import 'screens/settings_tab.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const WisePlugApp());
}

class WisePlugApp extends StatefulWidget {
  const WisePlugApp({super.key});

  @override
  State<WisePlugApp> createState() => _WisePlugAppState();
}

class _WisePlugAppState extends State<WisePlugApp> {
  bool darkMode = false;
  final String currentDeviceID = const String.fromEnvironment(
    'WISEPLUG_DEVICE_ID',
    defaultValue: 'wiseplug_01',
  );

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
                  HomeTab(
                    deviceID: widget.deviceID,
                    profiles: profiles,
                    activePower: activePower,
                    backend: _backend,
                    onSettingsTap: () => setState(() => _currentIndex = 2),
                  ),
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
                onDestinationSelected: (idx) =>
                    setState(() => _currentIndex = idx),
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
}