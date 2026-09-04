import 'package:flutter/material.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';

/// Edit / delete an existing appliance profile (Fig. 12).
class EditApplianceProfileScreen extends StatefulWidget {
  final ApplianceProfile profile;
  final FirebaseBackendService backend;

  const EditApplianceProfileScreen({super.key, required this.profile, required this.backend});

  @override
  State<EditApplianceProfileScreen> createState() => _EditApplianceProfileScreenState();
}

class _EditApplianceProfileScreenState extends State<EditApplianceProfileScreen> {
  static const _types = ['Rice cooker', 'Flat iron / hair straightener', 'Electric fan', 'Other'];

  late final TextEditingController _nameController;
  late String _selectedType;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.applianceName);
    _selectedType = _types.contains(widget.profile.applianceType) ? widget.profile.applianceType : _types.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _save() {
    if (_nameController.text.trim().isEmpty) return;
    widget.backend.saveProfile(
      widget.profile.copyWith(
        applianceName: _nameController.text.trim(),
        applianceType: _selectedType,
      ),
    );
    Navigator.pop(context);
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text('This removes "${widget.profile.applianceName}" and its history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              widget.backend.removeProfile(widget.profile.profileID);
              Navigator.pop(context); // close confirmation dialog
              Navigator.pop(context); // close edit screen
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Appliance Profile'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
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
              initialValue: _selectedType,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (val) {
                if (val != null) setState(() => _selectedType = val);
              },
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                padding: const EdgeInsets.symmetric(vertical: 14),
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _save,
              child: const Text('Save Profile'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 14),
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _confirmDelete,
              child: const Text('Delete profile'),
            ),
          ],
        ),
      ),
    );
  }
}
