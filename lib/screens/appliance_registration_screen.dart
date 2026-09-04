import 'package:flutter/material.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';

/// Full-screen appliance registration form. Reached from "Yes, Register" on a
/// detected-pattern dialog, where [detectedPattern] pre-fills the outlet + signature.
class ApplianceRegistrationScreen extends StatefulWidget {
  final String deviceID;
  final FirebaseBackendService backend;
  final DetectedAppliance detectedPattern; // Required to enforce registration from pattern

  const ApplianceRegistrationScreen({
    super.key,
    required this.deviceID,
    required this.backend,
    required this.detectedPattern,
  });

  @override
  State<ApplianceRegistrationScreen> createState() => _ApplianceRegistrationScreenState();
}

class _ApplianceRegistrationScreenState extends State<ApplianceRegistrationScreen> {
  static const _types = ['Rice cooker', 'Flat iron / hair straightener', 'Electric fan', 'Other'];

  late final TextEditingController _nameController;
  late String _selectedType;
  late String _selectedOutlet;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _selectedOutlet = widget.detectedPattern.outlet;
    _selectedType = widget.detectedPattern.suggestedType ?? _types.first;
    if (!_types.contains(_selectedType)) _selectedType = _types.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty || _isLoading) return;
    
    setState(() => _isLoading = true);
    
    try {
      final profile = ApplianceProfile(
        profileID: '', // Let Firestore auto-generate ID safely
        deviceID: widget.deviceID,
        applianceName: _nameController.text.trim(),
        applianceType: _selectedType,
        outlet: _selectedOutlet,
      );
      
      await widget.backend.saveProfile(profile);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detected = widget.detectedPattern;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appliance Registration'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Outlet ${detected.outlet} · detected signature',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(6)),
                  child: Text(detected.signature, style: TextStyle(color: Colors.blue.shade700, fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Appliance Name', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 20),
            const Text('Type of Appliance', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedType,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (val) {
                if (val != null) setState(() => _selectedType = val);
              },
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: _isLoading ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _isLoading ? null : _save,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Save Profile'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}