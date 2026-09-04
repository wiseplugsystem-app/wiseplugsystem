import 'package:flutter/material.dart';

class SettingsTab extends StatelessWidget {
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  const SettingsTab({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
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
              side: BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Dark Mode'),
                  subtitle: const Text('Reduce eye strain during night use'),
                  value: darkMode,
                  onChanged: onDarkModeChanged,
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.wifi, color: Colors.blue),
                  title: Text('Connected Device'),
                  subtitle: Text('WisePlug Dual Outlet'),
                  trailing: Icon(Icons.check_circle, color: Colors.green),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.security, color: Colors.blue),
                  title: Text('Safety Ceiling Protection'),
                  subtitle: Text('Auto shut-off enabled on limit breach'),
                  trailing: Icon(Icons.shield, color: Colors.blue),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.info_outline, color: Colors.blue),
                  title: Text('App Version'),
                  subtitle: Text('v1.0.0'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
