import 'package:flutter/material.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';
import 'package:wiseplug/screens/appliance_registration_screen.dart';
import 'package:wiseplug/screens/edit_appliance_profile_screen.dart';

enum ProfileStatus { active, nearLimit, idle }

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
  final Set<String> _dismissedSignatures = {};

  ProfileStatus _statusFor(ApplianceProfile profile) {
    if (!profile.isOn) return ProfileStatus.idle;
    if (profile.startTime != null) {
      final elapsed = DateTime.now().difference(profile.startTime!);
      final remaining = Duration(minutes: profile.safetyCeilingDuration) - elapsed;
      if (remaining.inMinutes < 5) return ProfileStatus.nearLimit;
    }
    return ProfileStatus.active;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.profiles.where((p) {
      if (selectedFilter == 'Active') return p.isOn;
      if (selectedFilter == 'Idle') return !p.isOn;
      return true;
    }).toList();

    return SafeArea(
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text('Appliance Profiles', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
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
                          return _ProfileListTile(
                            profile: profile,
                            status: _statusFor(profile),
                            onTap: () => _openEdit(context, profile),
                          );
                        },
                      ),
              ),
            ],
          ),

          StreamBuilder<List<DetectedAppliance>>(
            stream: widget.backend.streamDetectedAppliances(widget.deviceID),
            builder: (context, snapshot) {
              final patterns = (snapshot.data ?? [])
                  .where((p) => !_dismissedSignatures.contains(p.signature))
                  .toList();
              if (patterns.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _showDetectionDialog(context, patterns.first);
                });
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  void _showDetectionDialog(BuildContext context, DetectedAppliance pattern) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Expanded(child: Text('New Appliance Pattern Detected', style: TextStyle(fontSize: 16))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text('Do you want to register this appliance?', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('Detected on Outlet ${pattern.outlet}',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
              child: Column(
                children: [
                  _detailRow('Outlet:', pattern.outlet),
                  _detailRow('Power draw:', '~${pattern.estimatedWattage.toStringAsFixed(0)} W'),
                  _detailRow('Signature:', pattern.signature, chip: true),
                ],
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                setState(() => _dismissedSignatures.add(pattern.signature));
                widget.backend.dismissDetectedAppliance(pattern.signature);
                Navigator.pop(context);
              },
              child: const Text('No, Disregard'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: () {
                Navigator.pop(context);
                _openRegistration(context, pattern: pattern);
              },
              child: const Text('Yes, Register'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool chip = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          chip
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(6)),
                  child: Text(value, style: TextStyle(color: Colors.blue.shade700, fontSize: 12)),
                )
              : Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  void _openRegistration(BuildContext context, {required DetectedAppliance pattern}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ApplianceRegistrationScreen(
          deviceID: widget.deviceID,
          backend: widget.backend,
          detectedPattern: pattern,
        ),
      ),
    );
  }

  void _openEdit(BuildContext context, ApplianceProfile profile) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EditApplianceProfileScreen(profile: profile, backend: widget.backend),
      ),
    );
  }

  Widget _filterButton(String title) {
    final selected = selectedFilter == title;
    return ChoiceChip(
      label: Text(title),
      selected: selected,
      selectedColor: Colors.blue,
      labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87),
      onSelected: (_) => setState(() => selectedFilter = title),
    );
  }
}

class _ProfileListTile extends StatelessWidget {
  final ApplianceProfile profile;
  final ProfileStatus status;
  final VoidCallback onTap;

  const _ProfileListTile({required this.profile, required this.status, required this.onTap});

  Color get _dotColor {
    switch (status) {
      case ProfileStatus.active:
        return Colors.green;
      case ProfileStatus.nearLimit:
        return Colors.orange;
      case ProfileStatus.idle:
        return Colors.grey;
    }
  }

  String get _badgeLabel {
    switch (status) {
      case ProfileStatus.active:
        return 'Active';
      case ProfileStatus.nearLimit:
        return 'Near limit';
      case ProfileStatus.idle:
        return 'Idle';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: _dotColor, shape: BoxShape.circle),
        ),
        title: Text(profile.applianceName, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${profile.applianceType} · Outlet ${profile.outlet}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _dotColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(_badgeLabel, style: TextStyle(color: _dotColor, fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}