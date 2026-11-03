import 'package:flutter/material.dart';

import '../theme.dart';

import '../models/appliance_icons.dart';
import '../models/recognition.dart';

/// What the user answered in a recognition prompt.
sealed class PromptChoice {
  const PromptChoice();
}

/// "Yes, this is [applianceId]."
class ConfirmChoice extends PromptChoice {
  final String applianceId, name;
  const ConfirmChoice(this.applianceId, this.name);
}

/// "Register it": a new appliance, optionally pre-filled ("Fan", "Fan 2").
class RegisterChoice extends PromptChoice {
  final String? typeName, name;
  const RegisterChoice({this.typeName, this.name});
}

/// The question WisePlug asks about the run on one outlet, as a bottom sheet:
///
///   UNKNOWN              "New appliance detected. Register it?"
///   SAME_TYPE_IN_USE     "This looks like another Fan. Register as Fan 2?"
///   AMBIGUOUS            "Is this Fan 1 or Fan 2?" (last used here pre-selected)
///   MATCHED_PROVISIONAL  "Is this Fan?" (the label is provisional until confirmed)
///
/// Every unanswered load runs on the safe default limit, which the sheet says.
/// Returns the choice, or null for "Not now".
Future<PromptChoice?> showRecognitionPrompt(
  BuildContext context,
  OutletSession session, {
  int defaultCutoffMinutes = 30,
}) => showModalBottomSheet<PromptChoice>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  // Scrolls when the question is taller than a small phone's screen.
  builder: (_) => SingleChildScrollView(
    child: RecognitionPromptSheet(
      session: session,
      defaultCutoffMinutes: defaultCutoffMinutes,
    ),
  ),
);

class RecognitionPromptSheet extends StatefulWidget {
  final OutletSession session;
  final int defaultCutoffMinutes;
  const RecognitionPromptSheet({
    super.key,
    required this.session,
    this.defaultCutoffMinutes = 30,
  });

  @override
  State<RecognitionPromptSheet> createState() => _RecognitionPromptSheetState();
}

class _RecognitionPromptSheetState extends State<RecognitionPromptSheet> {
  late String? _selected =
      widget.session.suggested?.applianceId ??
      (widget.session.candidates.isEmpty
          ? null
          : widget.session.candidates.first.applianceId);

  OutletSession get s => widget.session;

  @override
  Widget build(BuildContext context) {
    final outlet = 'Outlet ${s.outletName}';
    final title = switch (s.status) {
      RecognitionStatus.sameTypeInUse =>
        'Another ${s.registerAs?.typeName ?? 'appliance'}?',
      RecognitionStatus.ambiguous => 'Which appliance is on $outlet?',
      RecognitionStatus.provisional => 'Is this ${s.applianceName ?? 'it'}?',
      _ => 'New appliance on $outlet',
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // What it is (or a question mark while WisePlug does not know).
                ApplianceIcon(_kind(), size: 24, label: title),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_question()),
            if (s.status == RecognitionStatus.ambiguous) ..._choices(),
            if (_note() case final note?) ...[
              const SizedBox(height: 10),
              Text(note, style: TextStyle(fontSize: 16, color: context.muted)),
            ],
            const SizedBox(height: 14),
            _SafetyBanner(minutes: widget.defaultCutoffMinutes),
            const SizedBox(height: 18),
            for (final action in _actions())
              Padding(padding: const EdgeInsets.only(bottom: 8), child: action),
          ],
        ),
      ),
    );
  }

  String _question() => switch (s.status) {
    RecognitionStatus.provisional =>
      // No mode names ("Normal", "Mode 2"): they are WisePlug's own labels
      // for an appliance's power patterns and mean nothing to users.
      'WisePlug thinks this is ${s.applianceName}. '
          'Confirm it to use its own safe operating time.',
    _ => s.promptText ?? 'New appliance detected. Register it?',
  };

  /// The appliance the question is about, for its icon.
  ApplianceKind _kind() => switch (s.status) {
    RecognitionStatus.sameTypeInUse => kindForType(s.registerAs?.typeName),
    RecognitionStatus.provisional => kindForType(
      s.candidates
              .where((c) => c.applianceId == s.applianceId)
              .firstOrNull
              ?.typeName ??
          s.applianceName,
    ),
    _ => unknownKind, // a new or unsure load
  };

  /// Why WisePlug asks, in the honest terms of the rules.
  String? _note() => switch (s.status) {
    RecognitionStatus.sameTypeInUse =>
      '${s.registerAs?.resembles ?? 'That appliance'} is running on another '
          'outlet, and one appliance cannot be in two sockets, so this must be '
          'a different unit.',
    RecognitionStatus.ambiguous => s.reason,
    _ => null,
  };

  List<Widget> _choices() => [
    const SizedBox(height: 8),
    for (final c in s.candidates)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          _selected == c.applianceId
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
          color: _selected == c.applianceId
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
        title: Row(
          children: [
            ApplianceIcon(kindForType(c.typeName), size: 24, label: c.name),
            const SizedBox(width: 10),
            Expanded(child: Text(c.name)),
          ],
        ),
        trailing: c.applianceId == s.suggested?.applianceId
            ? const Text('Last used here', style: TextStyle(fontSize: 16))
            : null,
        onTap: () => setState(() => _selected = c.applianceId),
      ),
  ];

  List<Widget> _actions() {
    void pop(PromptChoice? c) => Navigator.pop(context, c);
    final notNow = TextButton(
      onPressed: () => pop(null),
      child: const Text('Not now'),
    );
    switch (s.status) {
      case RecognitionStatus.sameTypeInUse:
        final r = s.registerAs;
        return [
          FilledButton(
            onPressed: () =>
                pop(RegisterChoice(typeName: r?.typeName, name: r?.name)),
            child: Text('Register as ${r?.name ?? 'new appliance'}'),
          ),
          OutlinedButton(
            onPressed: () => pop(const RegisterChoice()),
            child: const Text('It is something else'),
          ),
          notNow,
        ];
      case RecognitionStatus.ambiguous:
        final chosen = s.candidates
            .where((c) => c.applianceId == _selected)
            .firstOrNull;
        return [
          FilledButton(
            onPressed: chosen == null
                ? null
                : () => pop(ConfirmChoice(chosen.applianceId, chosen.name)),
            child: Text(
              chosen == null ? 'Confirm' : 'Yes, it is ${chosen.name}',
            ),
          ),
          OutlinedButton(
            onPressed: () => pop(const RegisterChoice()),
            child: const Text('Register new appliance'),
          ),
          TextButton(
            onPressed: () => pop(null),
            child: const Text('Ask me later'),
          ),
        ];
      case RecognitionStatus.provisional:
        return [
          FilledButton(
            onPressed: s.applianceId == null
                ? null
                : () =>
                      pop(ConfirmChoice(s.applianceId!, s.applianceName ?? '')),
            child: Text('Yes, it is ${s.applianceName}'),
          ),
          OutlinedButton(
            onPressed: () => pop(const RegisterChoice()),
            child: const Text('No, register a new appliance'),
          ),
          notNow,
        ];
      default:
        return [
          FilledButton(
            onPressed: () => pop(const RegisterChoice()),
            child: const Text('Register'),
          ),
          notNow,
        ];
    }
  }
}

class _SafetyBanner extends StatelessWidget {
  final int minutes;
  const _SafetyBanner({required this.minutes});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFFF5A623).withValues(alpha: .14),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const Icon(Icons.shield_outlined, size: 18, color: Color(0xFFF5A623)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Using a $minutes-minute safety limit until you confirm what this is.',
            style: const TextStyle(fontSize: 16),
          ),
        ),
      ],
    ),
  );
}
