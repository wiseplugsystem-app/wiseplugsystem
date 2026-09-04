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
  final FirebaseBackendService backend;
  final VoidCallback onSettingsTap;

  const HomeTab({
    super.key,
    required this.deviceID,
    required this.profiles,
    required this.activePower,
    required this.backend,
    required this.onSettingsTap,
  });

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  Timer? _ticker;
  final Set<String> _shownAlertIDs = {};

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
    final matches = widget.profiles.where((p) => p.outlet == outlet).toList();
    if (matches.isEmpty) return null;
    return matches.firstWhere((p) => p.isOn, orElse: () => matches.first);
  }

  Duration? _remaining(ApplianceProfile profile) {
    if (!profile.isOn || profile.startTime == null) return null;
    final elapsed = DateTime.now().difference(profile.startTime!);
    final limit = Duration(minutes: profile.safetyCeilingDuration);
    return limit - elapsed;
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
    final limit = Duration(minutes: profile.safetyCeilingDuration);
    if (limit.inSeconds == 0) return 0;
    final elapsedFraction = 1 - (remaining.inSeconds / limit.inSeconds);
    return elapsedFraction.clamp(0.0, 1.0);
  }

  String _formatRemaining(Duration? remaining) {
    if (remaining == null) return '—';
    if (remaining.isNegative) return '0 min';
    if (remaining.inMinutes < 1) return '${remaining.inSeconds}s';
    return '${remaining.inMinutes} min';
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
                        stream: widget.backend.streamActiveAlerts(widget.deviceID),
                        builder: (context, snapshot) {
                          final count = snapshot.data?.length ?? 0;
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.notifications_none_rounded, size: 26),
                                onPressed: () => _showAlertsSheet(context),
                              ),
                              if (count > 0)
                                Positioned(
                                  right: 6,
                                  top: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '$count',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white, fontSize: 10),
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
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: isLast ? 0 : 12),
                      child: _OutletCard(
                        outlet: outlet,
                        profile: profile,
                        statusColor: _statusColor(status),
                        remainingLabel: profile == null ? '—' : _formatRemaining(_remaining(profile)),
                        startLabel: profile == null ? '—' : _formatClock(profile.startTime),
                        progress: profile == null || !profile.isOn ? 0.0 : _progressFor(profile),
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
                  side: BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
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
                      builder: (_) => SafetyWarningDialog(alert: alert, backend: widget.backend),
                    );
                  });
                }
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
    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.power, color: profile == null ? Colors.grey : color),
          title: Text(
            'Outlet $outlet${profile != null ? ' — ${profile.applianceName}' : ''}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          trailing: Switch(
            value: profile?.isOn ?? false,
            onChanged: profile == null
                ? null
                : (val) => widget.backend.toggleAppliancePower(profile.profileID, val),
          ),
        ),
        if (!isLast) const Divider(height: 1),
      ],
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
                  const Text('Active Alerts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  if (alerts.isEmpty)
                    const Text('No active alerts.', style: TextStyle(color: Colors.grey))
                  else
                    ...alerts.map((a) => ListTile(
                          leading: const Icon(Icons.warning_amber_rounded, color: Colors.red),
                          title: Text(a.alertType, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('Triggered: ${_formatClock(a.triggerTime)}'),
                        )),
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

  const _OutletCard({
    required this.outlet,
    required this.profile,
    required this.statusColor,
    required this.remainingLabel,
    required this.startLabel,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
              Text('Outlet $outlet',
                  style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            profile?.applianceName ?? 'Not assigned',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            overflow: TextOverflow.ellipsis,
          ),
          Text(profile?.applianceType ?? '—', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          _infoRow('Start', startLabel),
          const SizedBox(height: 4),
          _infoRow('Safety Limit', profile == null ? '—' : '${profile!.safetyCeilingDuration}m total'),
          const SizedBox(height: 4),
          _infoRow('Remaining', remainingLabel, valueColor: statusColor),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
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
        Text(value, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: valueColor)),
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
        side: BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}