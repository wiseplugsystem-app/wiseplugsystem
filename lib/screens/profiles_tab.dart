import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/firebase_service.dart';

class ProfilesTab extends StatefulWidget {
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
  State<ProfilesTab> createState() => _ProfilesTabState();
}

class _ProfilesTabState extends State<ProfilesTab> {
  String selectedFilter = 'All';

  void _showAddProfileDialog() {
    final nameController = TextEditingController();
    String selectedType = 'Rice cooker';
    String selectedOutlet = 'A';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Register Appliance'),
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
                value: selectedType,
                decoration: const InputDecoration(
                  labelText: 'Appliance Type',
                  border: OutlineInputBorder(),
                ),
                items: ['Rice cooker', 'Flat Iron', 'Electric Fan', 'Other']
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: (val) => setDialogState(() => selectedType = val!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedOutlet,
                decoration: const InputDecoration(
                  labelText: 'Assigned Outlet',
                  border: OutlineInputBorder(),
                ),
                items: ['A', 'B']
                    .map((o) => DropdownMenuItem(value: o, child: Text('Outlet $o')))
                    .toList(),
                onChanged: (val) => setDialogState(() => selectedOutlet = val!),
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
                if (nameController.text.isNotEmpty) {
                  final newProfile = ApplianceProfile(
                    profileID: '',
                    deviceID: widget.deviceID,
                    applianceName: nameController.text,
                    applianceType: selectedType,
                    outlet: selectedOutlet,
                  );
                  widget.backend.saveProfile(newProfile);
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
    final filtered = widget.profiles.where((p) {
      if (selectedFilter == 'Active') return p.isOn;
      if (selectedFilter == 'Idle') return !p.isOn;
      return true;
    }).toList();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Appliance Profiles',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.blue, size: 32),
                  onPressed: _showAddProfileDialog,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                _filterButton('All'),
                const SizedBox(width: 8),
                _filterButton('Active'),
                const SizedBox(width: 8),
                _filterButton('Idle'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('No profiles found.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final profile = filtered[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: Icon(profile.icon, color: profile.color, size: 30),
                          title: Text(profile.applianceName, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('Threshold: ${profile.thresholdWattage}W | Safety Limit: ${profile.safetyCeilingDuration}m'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed: () => widget.backend.removeProfile(profile.profileID),
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

  Widget _filterButton(String title) {
    final selected = selectedFilter == title;
    return ChoiceChip(
      label: Text(title),
      selected: selected,
      onSelected: (_) => setState(() => selectedFilter = title),
    );
  }
}