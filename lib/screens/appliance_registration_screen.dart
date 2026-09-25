import 'package:flutter/material.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';

class ApplianceRegistrationScreen extends StatefulWidget {
  final String deviceID;
  final FirebaseBackendService backend;
  final DetectedAppliance detectedPattern;

  const ApplianceRegistrationScreen({
    super.key,
    required this.deviceID,
    required this.backend,
    required this.detectedPattern,
  });

  @override
  State<ApplianceRegistrationScreen> createState() =>
      _ApplianceRegistrationScreenState();
}

class _ApplianceRegistrationScreenState
    extends State<ApplianceRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _safetyLimitController =
      TextEditingController(text: '30');

  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _safetyLimitController.dispose();
    super.dispose();
  }

  Future<void> _submitRegistration() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);
    final String applianceName = _nameController.text.trim();
    final int safetyMinutes =
        int.tryParse(_safetyLimitController.text.trim()) ?? 30;

    try {
      final String nodeName = widget.detectedPattern.outlet.contains('B') ||
              widget.detectedPattern.outlet.contains('b')
          ? 'outlet_B'
          : 'outlet_A';

      // 1. Send register command for the hardware
      await widget.backend.sendRegisterCommand(
        nodeName: nodeName,
        applianceName: applianceName,
      );

      // 2. Save the new profile to Firestore using your service
      final newProfile = ApplianceProfile(
        profileID: '',
        deviceID: widget.deviceID,
        applianceName: applianceName,
        applianceType: 'General',
        outlet: widget.detectedPattern.outlet,
        safetyCeilingDuration: safetyMinutes * 60,
        isOn: true,
        startTime: DateTime.now(),
      );

      await widget.backend.saveProfile(newProfile);

      // 3. Dismiss detected pattern entry
      await widget.backend.dismissDetectedAppliance(
        widget.detectedPattern.signature,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Registered "$applianceName" successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to register device: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register Appliance'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                elevation: 0,
                color: Colors.blue.shade50,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.blue.shade200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Captured Power Signature',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Target Outlet:'),
                          Text(
                            widget.detectedPattern.outlet,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Power Draw:'),
                          Text(
                            '~${widget.detectedPattern.estimatedWattage.toStringAsFixed(0)} W',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Signature:'),
                          Text(
                            widget.detectedPattern.signature,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Appliance Details',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Appliance Name',
                  hintText: 'e.g. Electric Fan, Rice Cooker',
                  border: OutlineInputBorder(),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter a name for this appliance';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _safetyLimitController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Safety Auto-Off Limit (Minutes)',
                  hintText: 'Default: 30',
                  border: OutlineInputBorder(),
                  suffixText: 'mins',
                ),
                validator: (val) {
                  if (val == null || int.tryParse(val.trim()) == null) {
                    return 'Please enter a valid number of minutes';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _isSubmitting ? null : _submitRegistration,
                  child: _isSubmitting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          'Save Profile & Link Outlet',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}