import 'package:flutter/material.dart';

import '../../controllers/ride_controller.dart';
import '../../domain/ride_role.dart';
import '../../domain/rider_color.dart';
import '../../services/ride_membership.dart';
import '../map/motorcycle_icon.dart';

enum _RosterFilter { active, attention, all }

class RideRosterSheet extends StatefulWidget {
  const RideRosterSheet({super.key, required this.controller});

  final RideController controller;

  static Future<void> show(BuildContext context, RideController controller) =>
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => RideRosterSheet(controller: controller),
      );

  @override
  State<RideRosterSheet> createState() => _RideRosterSheetState();
}

class _RideRosterSheetState extends State<RideRosterSheet> {
  _RosterFilter _filter = _RosterFilter.active;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final all = widget.controller.participants;
      final liveCount = all
          .where((participant) => participant.isIncludedInLiveCount)
          .length;
      final visible = all.where(_matchesFilter).toList(growable: false)
        ..sort(_compareParticipants);
      return FractionallySizedBox(
        heightFactor: 0.86,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ride roster',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          '$liveCount currently included · ${all.length} recorded',
                          style: const TextStyle(color: Color(0xFF9DA8B6)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close roster',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<_RosterFilter>(
                segments: const [
                  ButtonSegment(
                    value: _RosterFilter.active,
                    icon: Icon(Icons.motorcycle_outlined),
                    label: Text('Current'),
                  ),
                  ButtonSegment(
                    value: _RosterFilter.attention,
                    icon: Icon(Icons.report_problem_outlined),
                    label: Text('Attention'),
                  ),
                  ButtonSegment(
                    value: _RosterFilter.all,
                    icon: Icon(Icons.groups_outlined),
                    label: Text('All joined'),
                  ),
                ],
                selected: {_filter},
                onSelectionChanged: (selection) =>
                    setState(() => _filter = selection.single),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: visible.isEmpty
                  ? const Center(
                      child: Text(
                        'No riders match this filter.',
                        style: TextStyle(color: Color(0xFF9DA8B6)),
                      ),
                    )
                  : ListView.separated(
                      key: const Key('ride-roster-list'),
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) => _ParticipantTile(
                        participant: visible[index],
                        now: DateTime.now(),
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );

  bool _matchesFilter(RideParticipant participant) => switch (_filter) {
    _RosterFilter.active => participant.isIncludedInLiveCount,
    _RosterFilter.attention =>
      participant.state == RideMembershipState.inactive ||
          participant.attentionLabel != null,
    _RosterFilter.all => true,
  };

  int _compareParticipants(RideParticipant left, RideParticipant right) {
    final leftAttention =
        left.state == RideMembershipState.inactive ||
        left.attentionLabel != null;
    final rightAttention =
        right.state == RideMembershipState.inactive ||
        right.attentionLabel != null;
    if (leftAttention != rightAttention) return leftAttention ? -1 : 1;
    if (left.isLocal != right.isLocal) return left.isLocal ? -1 : 1;
    return left.displayName.compareTo(right.displayName);
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, required this.now});

  final RideParticipant participant;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final role = _roleLabel(participant.role);
    final lastSeen = _lastSeenLabel(participant.lastSeenAt, now);
    final attention = participant.attentionLabel;
    final semanticLabel = [
      participant.displayName,
      if (participant.isLocal) 'you',
      role,
      participant.stateLabel,
      'last seen $lastSeen',
      participant.transportLabel,
      ?attention,
    ].join(', ');
    return Semantics(
      label: semanticLabel,
      child: ListTile(
        key: Key('roster-rider-${participant.riderId}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        leading: RiderMarkerBadge(
          style: participant.motorcycleStyle,
          badgeColor: _roleColor(participant),
          size: 42,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                '${participant.displayName}${participant.isLocal ? ' (you)' : ''}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
            _StateDot(state: participant.state),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            [
              '$role · ${participant.stateLabel}',
              'Last seen $lastSeen · ${participant.transportLabel}',
              ?attention,
            ].join('\n'),
            style: TextStyle(
              color: attention == null
                  ? const Color(0xFFA6B0BD)
                  : const Color(0xFFFFC857),
              height: 1.35,
            ),
          ),
        ),
      ),
    );
  }

  static String _roleLabel(RideRole role) => switch (role) {
    RideRole.lead => 'Lead',
    RideRole.tailEndCharlie => 'Tail End Charlie',
    RideRole.marker => 'Marker',
    RideRole.rider => 'Rider',
  };

  static Color _roleColor(RideParticipant participant) =>
      switch (participant.role) {
        RideRole.lead => const Color(0xFFFFC857),
        RideRole.tailEndCharlie => const Color(0xFFB58CFF),
        _ => participant.riderColor.color,
      };

  static String _lastSeenLabel(DateTime value, DateTime now) {
    final age = now.difference(value);
    if (age <= const Duration(seconds: 45)) return 'just now';
    if (age < const Duration(hours: 1)) return '${age.inMinutes} min ago';
    if (age < const Duration(hours: 24)) return '${age.inHours} hr ago';
    return '${age.inDays} days ago';
  }
}

class _StateDot extends StatelessWidget {
  const _StateDot({required this.state});

  final RideMembershipState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      RideMembershipState.active => const Color(0xFF59D18C),
      RideMembershipState.joined => const Color(0xFF66AFFF),
      RideMembershipState.inactive => const Color(0xFFFFC857),
      RideMembershipState.left ||
      RideMembershipState.expired => const Color(0xFF7F8A98),
    };
    return Tooltip(
      message: state.name,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
