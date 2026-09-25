import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';

/// Countdown dialog shown when an appliance's safety ceiling has been
/// exceeded (Fig. 13). The countdown is driven by the alert's own
/// `countdownExpiry` timestamp (set server-side by `triggerAlert()`),
/// not a local timer, so it stays correct if the user backgrounds the
/// app or the dialog is rebuilt.
class SafetyWarningDialog extends StatefulWidget {
  final AnomalyAlert alert;
  final FirebaseBackendService backend;

  const SafetyWarningDialog({
    super.key,
    required this.alert,
    required this.backend,
  });

  @override
  State<SafetyWarningDialog> createState() => _SafetyWarningDialogState();
}

class _SafetyWarningDialogState extends State<SafetyWarningDialog> {
  Timer? _timer;
  late int _secondsRemaining;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = _computeSecondsRemaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = _computeSecondsRemaining();
      if (remaining <= 0) {
        timer.cancel();
        _turnOffNow();
      } else if (mounted) {
        setState(() => _secondsRemaining = remaining);
      }
    });
  }

  int _computeSecondsRemaining() {
    final diff = widget.alert.countdownExpiry
        .difference(DateTime.now())
        .inSeconds;
    return diff < 0 ? 0 : diff;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _turnOffNow() {
    widget.backend.toggleAppliancePower(widget.alert.profileID, false);
    widget.backend.acknowledgeShutdown(widget.alert.alertID);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _override() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final user = await widget.backend.loadConfiguredUser(
        widget.alert.deviceID,
      );
      if (!mounted || _computeSecondsRemaining() <= 0) return;
      if (user == null) {
        throw StateError('No user is configured for this device.');
      }
      await widget.backend.requestSmartOverride(
        SmartOverride(
          overrideID: DateTime.now().microsecondsSinceEpoch.toString(),
          alertID: widget.alert.alertID,
          userID: user.userID,
          extensionDuration: 15,
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Override failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                    SizedBox(height: 6),
                    Text(
                      'WARNING',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Safety Limit Exceeded!',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Text(
                '$_secondsRemaining',
                style: const TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Text(
                'Seconds Remaining',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 20),
              const Text(
                'Are you still using the Appliance?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade100,
                        foregroundColor: Colors.black87,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _turnOffNow,
                      child: const Text('Turn Off Now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade100,
                        foregroundColor: Colors.black87,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _busy ? null : _override,
                      child: const Text('Yes, Override'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
