import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wiseplug/models/models.dart';
import 'package:wiseplug/services/firebase_service.dart';
import 'package:wiseplug/screens/safety_warning_dialog.dart';

enum OutletStatus { idle, active, nearLimit, exceeded }

class HomeTab extends StatefulWidget {
  final String deviceID;
  final List<ApplianceProfile> profiles;
  final double activePower;
  final TelemetryLog? telemetry;
  final bool telemetryLoading;
  final bool telemetryHasError;
  final FirebaseBackendService backend;
  final VoidCallback onSettingsTap;
  final void Function(DetectedAppliance pattern) onRegisterDetected;

  const HomeTab({
    super.key,
    required this.deviceID,
    required this.profiles,
    required this.activePower,
    this.telemetry,
    this.telemetryLoading = false,
    this.telemetryHasError = false,
    required this.backend,
    required this.onSettingsTap,
    required this.onRegisterDetected,
  });

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  Timer? _ticker;
  final Set<String> _shownAlertIDs = {};
  final Set<String> _dismissedSignatures = {};
  bool _detectionDialogOpen = false;
  final Set<String> _pendingToggles = {};

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  ApplianceProfile? _profileForOutlet(String outlet) {
    final matches = widget.profiles
        .where((p) => p.outlet.trim().toUpperCase() == outlet.trim().toUpperCase())
        .toList();
    if (matches.isEmpty) return null;
    final activeMatches = matches.where((p) => p.isOn).toList();
    if (activeMatches.isNotEmpty) return activeMatches.first;
    return matches.first;
  }

  Duration? _remaining(ApplianceProfile profile) {
    if (!profile.isOn || profile.startTime == null) return null;
    final elapsed = DateTime.now().difference(profile.startTime!);
    final limit = Duration(seconds: profile.safetyCeilingDuration);
    return limit - elapsed;
  }

  double _outletPowerDraw(String outlet) {
    final profile = _profileForOutlet(outlet);
    if (profile == null || !profile.isOn) return 0.0;
    final onProfiles = widget.profiles.where((p) => p.isOn).toList();
    if (onProfiles.length == 1) return widget.activePower;
    final totalBaseline = onProfiles.fold<double>(0, (s, p) => s + (p.baselineWattage > 0 ? p.baselineWattage : 1));
    if (totalBaseline == 0) return widget.activePower / onProfiles.length;
    final profileBase = profile.baselineWattage > 0 ? profile.baselineWattage : 1;
    return widget.activePower * (profileBase / totalBaseline);
  }

  OutletStatus _statusFor(ApplianceProfile? profile) {
    if (profile == null || !profile.isOn) return OutletStatus.idle;
    final remaining = _remaining(profile);
    if (remaining == null) return OutletStatus.active;
    if (remaining.isNegative) return OutletStatus.exceeded;
    if (remaining.inMinutes < 5) return OutletStatus.nearLimit;
    return OutletStatus.active;
  }

  Color _statusColor(OutletStatus status) {
    switch (status) {
      case OutletStatus.active:
        return Colors.green;
      case OutletStatus.nearLimit:
        return Colors.orange;
      case OutletStatus.exceeded:
        return Colors.red;
      case OutletStatus.idle:
        return Colors.grey;
    }
  }

  double _progressFor(ApplianceProfile profile) {
    final remaining = _remaining(profile);
    if (remaining == null) return 0;
    final limit = Duration(seconds: profile.safetyCeilingDuration);
    if (limit.inSeconds == 0) return 0;
    final elapsedFraction = 1 - (remaining.inSeconds / limit.inSeconds);
    return elapsedFraction.clamp(0.0, 1.0);
  }

  String _formatRemaining(Duration? remaining) {
    if (remaining == null) return '—';
    if (remaining.isNegative) return '0s';
    if (remaining.inMinutes < 1) return '${remaining.inSeconds}s';
    final hrs = remaining.inHours;
    final mins = remaining.inMinutes.remainder(60);
    if (hrs > 0) return '${hrs}h ${mins}m';
    return '${remaining.inMinutes}m';
  }

  String _formatDurationTotal(int secondsTotal) {
    final hrs = secondsTotal ~/ 3600;
    final mins = (secondsTotal % 3600) ~/ 60;
    if (hrs > 0) return '${hrs}h ${mins}m';
    return '${mins}m';
  }

  String _formatClock(DateTime? time) {
    if (time == null) return '—';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final activeCount = widget.profiles.where((p) => p.isOn).length;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const outlets = ['A', 'B'];

    return SafeArea(
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        'Wise',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const Text(
                        'Plug',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      StreamBuilder<List<AnomalyAlert>>(
                        stream: widget.backend.streamActiveAlerts(
                          widget.deviceID,
                        ),
                        builder: (context, snapshot) {
                          final count = snapshot.data?.length ?? 0;
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.notifications_none_rounded,
                                  size: 26,
                                ),
                                onPressed: () => _showAlertsSheet(context),
                              ),
                              if (count > 0)
                                Positioned(
                                  right: 6,
                                  top: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    constraints: const BoxConstraints(
                                      minWidth: 16,
                                      minHeight: 16,
                                    ),
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '$count',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings_outlined, size: 26),
                        onPressed: widget.onSettingsTap,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 15),
              const Text(
                'CURRENTLY CONNECTED — DUAL OUTLET',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: outlets.map((outlet) {
                  final profile = _profileForOutlet(outlet);
                  final status = _statusFor(profile);
                  final isLast = outlet == outlets.last;
                  final outletPower = _outletPowerDraw(outlet);
                  final voltage = widget.telemetry?.voltage;
                  final current = profile != null && profile.isOn
                      ? (voltage != null && voltage > 0 && outletPower > 0
                          ? outletPower / voltage
                          : null)
                      : null;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: isLast ? 0 : 12),
                      child: _OutletCard(
                        outlet: outlet,
                        profile: profile,
                        statusColor: _statusColor(status),
                        remainingLabel: profile == null
                            ? '—'
                            : _formatRemaining(_remaining(profile)),
                        startLabel: profile == null
                            ? '—'
                            : _formatClock(profile.startTime),
                        progress: profile == null || !profile.isOn
                            ? 0.0
                            : _progressFor(profile),
                        powerDraw: outletPower,
                        voltage: voltage,
                        current: current,
                        safetyCeilingLabel: profile == null
                            ? '—'
                            : _formatDurationTotal(profile.safetyCeilingDuration),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: SummaryCard(
                      value: '${widget.activePower.toStringAsFixed(1)} W',
                      label: 'Total draw',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SummaryCard(
                      value: '$activeCount / ${widget.profiles.length}',
                      label: 'Outlets active',
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
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                  ),
                ),
                child: Column(
                  children: [
                    for (final outlet in outlets)
                      _buildPowerRow(outlet, isLast: outlet == outlets.last),
                  ],
                ),
              ),
            ],
          ),
          StreamBuilder<List<AnomalyAlert>>(
            stream: widget.backend.streamActiveAlerts(widget.deviceID),
            builder: (context, snapshot) {
              final alerts = snapshot.data ?? [];
              for (final alert in alerts) {
                if (!_shownAlertIDs.contains(alert.alertID)) {
                  _shownAlertIDs.add(alert.alertID);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => SafetyWarningDialog(
                        alert: alert,
                        backend: widget.backend,
                      ),
                    );
                  });
                }
              }
              return const SizedBox.shrink();
            },
          ),
          StreamBuilder<List<DetectedAppliance>>(
            stream: widget.backend.streamDetectedAppliances(widget.deviceID),
            builder: (context, snapshot) {
              final patterns = (snapshot.data ?? [])
                  .where((p) => !_dismissedSignatures.contains(p.signature))
                  .toList();
              if (patterns.isNotEmpty && !_detectionDialogOpen) {
                _detectionDialogOpen = true;
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

  Widget _buildPowerRow(String outlet, {required bool isLast}) {
    final profile = _profileForOutlet(outlet);
    final color = outlet == 'A' ? Colors.blue : Colors.orange;
    bool isPending = false;
    bool effectiveIsOn = profile?.isOn ?? false;
    if (profile != null) {
      isPending = _pendingToggles.contains(profile.profileID);
      if (isPending) effectiveIsOn = !profile.isOn;
    }
    return Column(
      children: [
        ListTile(
          leading: Icon(
            Icons.power,
            color: profile == null ? Colors.grey : color,
          ),
          title: Text(
            'Outlet $outlet${profile != null ? ' — ${profile.applianceName}' : ''}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: profile != null && profile.isOn
              ? Text(
                  'Drawing ${_outletPowerDraw(outlet).toStringAsFixed(1)} W',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                )
              : null,
          trailing: Switch(
            value: effectiveIsOn,
            onChanged: (profile == null || isPending)
                ? null
                : (val) async {
                    setState(() => _pendingToggles.add(profile.profileID));
                    try {
                      await widget.backend.toggleAppliancePower(
                        profile.profileID,
                        val,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '${profile.applianceName} ${val ? "powered on" : "powered off"}',
                            ),
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Failed to toggle power: $e'),
                            backgroundColor: Colors.red,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    } finally {
                      if (mounted) {
                        setState(() => _pendingToggles.remove(profile.profileID));
                      }
                    }
                  },
          ),
        ),
        if (!isLast) const Divider(height: 1),
      ],
    );
  }

  Future<void> _showDetectionDialog(
    BuildContext context,
    DetectedAppliance pattern,
  ) async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.power_outlined, color: Colors.blue),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'New Appliance Plug-in Detected',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              'An unassigned appliance pattern has been detected on your WisePlug. Register it now?',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Device: ${pattern.deviceID.isEmpty ? widget.deviceID : pattern.deviceID} · Outlet ${pattern.outlet}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _detailRow('Outlet:', pattern.outlet),
                  _detailRow(
                    'Est. draw:',
                    '~${pattern.estimatedWattage.toStringAsFixed(0)} W',
                  ),
                  _detailRow('Signature:', pattern.signature, chip: true),
                  if (pattern.suggestedType != null && pattern.suggestedType!.isNotEmpty)
                    _detailRow('Suggested:', pattern.suggestedType!),
                ],
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          OutlinedButton(
            onPressed: () {
              setState(() => _dismissedSignatures.add(pattern.signature));
              widget.backend.dismissDetectedAppliance(pattern.signature);
              Navigator.pop(context);
            },
            child: const Text('Not now'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () {
              Navigator.pop(context);
              setState(() => _dismissedSignatures.add(pattern.signature));
              widget.onRegisterDetected(pattern);
            },
            child: const Text('Yes, Register'),
          ),
        ],
      ),
    );
    if (mounted) _detectionDialogOpen = false;
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    value,
                    style: TextStyle(color: Colors.blue.shade700, fontSize: 12),
                  ),
                )
              : Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
        ],
      ),
    );
  }

  void _showAlertsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StreamBuilder<List<AnomalyAlert>>(
        stream: widget.backend.streamActiveAlerts(widget.deviceID),
        builder: (context, snapshot) {
          final alerts = snapshot.data ?? [];
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Active Alerts',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  if (alerts.isEmpty)
                    const Text(
                      'No active alerts.',
                      style: TextStyle(color: Colors.grey),
                    )
                  else
                    ...alerts.map(
                      (a) => ListTile(
                        leading: const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.red,
                        ),
                        title: Text(
                          a.alertType,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          'Triggered: ${_formatClock(a.triggerTime)}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OutletCard extends StatelessWidget {
  final String outlet;
  final ApplianceProfile? profile;
  final Color statusColor;
  final String remainingLabel;
  final String startLabel;
  final double progress;
  final double powerDraw;
  final double? voltage;
  final double? current;
  final String safetyCeilingLabel;

  const _OutletCard({
    required this.outlet,
    required this.profile,
    required this.statusColor,
    required this.remainingLabel,
    required this.startLabel,
    required this.progress,
    required this.powerDraw,
    this.voltage,
    this.current,
    required this.safetyCeilingLabel,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isActive = profile != null && profile!.isOn;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade900 : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Outlet $outlet',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            profile?.applianceName ?? 'Not assigned',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            profile?.applianceType ?? '—',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            decoration: BoxDecoration(
              color: isActive
                  ? statusColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Live Draw',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                Text(
                  '${powerDraw.toStringAsFixed(1)} W',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isActive ? statusColor : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          if (isActive && (voltage != null || current != null))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (voltage != null)
                    Expanded(
                      child: Text(
                        '${voltage!.toStringAsFixed(0)} V',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  if (voltage != null && current != null)
                    const Text(' · ',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  if (current != null)
                    Expanded(
                      child: Text(
                        '${current!.toStringAsFixed(2)} A',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          _infoRow('Start', startLabel),
          const SizedBox(height: 4),
          _infoRow('Safety Limit', safetyCeilingLabel),
          const SizedBox(height: 4),
          _infoRow('Remaining', remainingLabel, valueColor: statusColor),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: isDark
                  ? Colors.grey.shade800
                  : Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation(statusColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

class SummaryCard extends StatelessWidget {
  final String value;
  final String label;

  const SummaryCard({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: 0,
      color: isDark ? Colors.grey.shade900 : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
