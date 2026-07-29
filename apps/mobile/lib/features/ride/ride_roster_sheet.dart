import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/ride_controller.dart';
import '../../domain/ride_role.dart';
import '../../domain/rider_color.dart';
import '../../relay/live_presence.dart';
import '../../services/ride_membership.dart';
import '../../services/tec_role_assignment.dart';
import '../map/motorcycle_icon.dart';

enum _RosterFilter { active, attention, left, all }

class RideRosterSheet extends StatefulWidget {
  const RideRosterSheet({
    super.key,
    required this.controller,
    this.relayCanCarryTecRequest = true,
    this.legacyPeerRiderIds = const {},
  });

  final RideController controller;

  /// The negotiated `tec-role-assignment-v1` capability. False means the leader
  /// is told the request cannot be sent, rather than a request being recorded
  /// that can never reach anybody.
  final bool relayCanCarryTecRequest;

  /// Riders whose build is known to be older than this one, from the live
  /// presence channel. Their phone will skip the request, so the leader is told
  /// by name before asking rather than watching it sit unanswered.
  final Set<String> legacyPeerRiderIds;

  static Future<void> show(
    BuildContext context,
    RideController controller, {
    bool relayCanCarryTecRequest = true,
    Set<String> legacyPeerRiderIds = const {},
  }) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => RideRosterSheet(
      controller: controller,
      relayCanCarryTecRequest: relayCanCarryTecRequest,
      legacyPeerRiderIds: legacyPeerRiderIds,
    ),
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
      final departed = all.where((participant) => participant.hasLeft).length;
      final visible = all.where(_matchesFilter).toList(growable: false)
        ..sort(_compareParticipants);
      final isLeader = widget.controller.isLocalRideLeader;
      final assignment = widget.controller.tecRoleAssignments.latest;
      final acceptedTecRiderId = assignment?.isAccepted == true
          ? assignment!.targetRiderId
          : null;
      final effectiveTecRiderId =
          acceptedTecRiderId != null &&
              all.any(
                (participant) =>
                    participant.riderId == acceptedTecRiderId &&
                    participant.isIncludedInLiveCount,
              )
          ? acceptedTecRiderId
          : null;
      final hasTec =
          effectiveTecRiderId != null ||
          all.any(
            (participant) =>
                participant.isIncludedInLiveCount &&
                participant.role == RideRole.tailEndCharlie,
          );
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
            // Shown to everyone, unlike the TEC notice: there is no leader to
            // show it to, and every remaining rider needs to know (#176).
            if (widget.controller.rideHasNoLeader)
              _MissingLeaderNotice(
                onTakeLead: () async {
                  await widget.controller.setRole(RideRole.lead);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            if (isLeader && !hasTec) const _MissingTecNotice(),
            if (isLeader && assignment != null)
              _TecRequestStatus(assignment: assignment),
            // The record exists; say so where it is not being shown. A rider who
            // has left is the rider a leader may need to look up afterwards.
            if (departed > 0 && !visible.any((rider) => rider.hasLeft))
              _DepartedRidersNotice(
                departed: departed,
                onShow: () => setState(() => _filter = _RosterFilter.left),
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
                    value: _RosterFilter.left,
                    icon: Icon(Icons.logout_outlined),
                    label: Text('Left'),
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
                  ? Center(
                      child: Text(
                        _filter == _RosterFilter.left
                            ? 'Nobody has left this ride.'
                            : 'No riders match this filter.',
                        style: const TextStyle(color: Color(0xFF9DA8B6)),
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
                        effectiveTecRiderId: effectiveTecRiderId,
                        onAskToBeTec:
                            _canAsk(visible[index], effectiveTecRiderId)
                            ? () => _askToBeTec(visible[index])
                            : null,
                        peerAppIsOlder: widget.legacyPeerRiderIds.contains(
                          visible[index].riderId,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );

  /// The leader may ask any live rider other than themselves who is not the
  /// effective TEC. Before an accepted assignment, a self-selected TEC is
  /// effective; afterwards an older self-selection has been superseded and can
  /// be asked again.
  bool _canAsk(RideParticipant participant, String? effectiveTecRiderId) =>
      widget.controller.isLocalRideLeader &&
      !participant.isLocal &&
      participant.isIncludedInLiveCount &&
      participant.riderId != effectiveTecRiderId &&
      (effectiveTecRiderId != null ||
          participant.role != RideRole.tailEndCharlie);

  Future<void> _askToBeTec(RideParticipant participant) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // Named before the request goes anywhere: this rider's build will skip it.
    if (widget.legacyPeerRiderIds.contains(participant.riderId)) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            PresenceLimitation.tecAssignmentUnsupportedByPeer(
              riderId: participant.riderId,
              displayName: participant.displayName,
            ).message,
          ),
        ),
      );
      return;
    }
    final outcome = await widget.controller.requestTecRole(
      targetRiderId: participant.riderId,
      targetDisplayName: participant.displayName,
      relayCanCarryRequest: widget.relayCanCarryTecRequest,
    );
    if (!mounted) return;
    final message = switch (outcome) {
      TecRoleRequestOutcome.sent =>
        'Asked ${participant.displayName} to be Tail End Charlie. They have to '
            'accept before the back is covered.',
      TecRoleRequestOutcome.relayUnsupported =>
        PresenceLimitation.tecAssignmentUnsupportedByService.message,
      TecRoleRequestOutcome.notLeader =>
        'Only the current ride leader can ask a rider to be Tail End Charlie.',
      TecRoleRequestOutcome.invalidTarget =>
        '${participant.displayName} is no longer in the ride.',
      TecRoleRequestOutcome.alreadyTailEndCharlie =>
        '${participant.displayName} is already Tail End Charlie.',
      TecRoleRequestOutcome.failed =>
        widget.controller.errorMessage ??
            'That request could not be saved. Please try again.',
    };
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(key: const Key('tec-request-outcome'), content: Text(message)),
    );
  }

  bool _matchesFilter(RideParticipant participant) => switch (_filter) {
    _RosterFilter.active => participant.isIncludedInLiveCount,
    _RosterFilter.attention =>
      participant.state == RideMembershipState.inactive ||
          participant.attentionLabel != null,
    _RosterFilter.left => participant.hasLeft,
    _RosterFilter.all => true,
  };

  int _compareParticipants(RideParticipant left, RideParticipant right) {
    // Riders still in the ride come first; a departed record is history, and it
    // is kept rather than promoted.
    if (left.hasLeft != right.hasLeft) return left.hasLeft ? 1 : -1;
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

/// Names the missing back-marker for the leader, and both ways to close the gap.
///
/// The leader can now ask a named rider directly (#128). It is still a request
/// the rider accepts, not a silent assignment, so this deliberately says the
/// rider has to accept: a rider who has not noticed they are TEC is worse than
/// no TEC, because the group then believes the back is covered.
/// Shown when a running ride has nobody holding the lead role (#176).
///
/// Offers rather than assigns. Roles in this app are self-selected - the
/// precedent #128 set for the TEC role, where a leader *asks* and the target's
/// own `roleChanged` is what counts - so the group cannot be handed a leader it
/// did not choose, and the app cannot pick one on the strength of who happens to
/// be nearest the front.
class _MissingLeaderNotice extends StatelessWidget {
  const _MissingLeaderNotice({required this.onTakeLead});

  final Future<void> Function() onTakeLead;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: Card(
      key: const Key('roster-missing-leader-notice'),
      margin: EdgeInsets.zero,
      color: const Color(0xFF3A2320),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFFF8A6B),
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This ride has no leader',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'The leader has left. Nobody is setting the pace, the Tail '
                    'End Charlie has no line to follow, and route changes '
                    'cannot be published until somebody takes the lead.',
                    style: TextStyle(color: Color(0xFFE4D6D2), height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const Key('roster-take-the-lead-button'),
                    onPressed: () => unawaited(onTakeLead()),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: const Text('Take the lead'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MissingTecNotice extends StatelessWidget {
  const _MissingTecNotice();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: Card(
      key: const Key('roster-missing-tec-notice'),
      margin: EdgeInsets.zero,
      color: const Color(0xFF3A3320),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFFFC857),
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'No Tail End Charlie',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Nobody is covering the back of this group, so there is no '
                    'distance to the back and nobody confirming everyone is '
                    'still with you. Ask a rider below to take it — they have '
                    'to accept on their own phone — or they can set the role '
                    'themselves on their Ride tab.',
                    style: TextStyle(color: Color(0xFFE4D9BC), height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Says that a departed rider's record is still here, and how to reach it.
///
/// Issue #144: a rider leaving used to erase them from the list a leader was
/// looking at, which is exactly the rider you go back to afterwards when a lost
/// item or a question comes up. They are out of the live group; they are not out
/// of the record.
class _DepartedRidersNotice extends StatelessWidget {
  const _DepartedRidersNotice({required this.departed, required this.onShow});

  final int departed;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
    child: Row(
      key: const Key('roster-departed-notice'),
      children: [
        const Icon(Icons.logout_outlined, size: 18, color: Color(0xFF9DA8B6)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            departed == 1
                ? '1 rider has left. Their record is kept until this ride ends.'
                : '$departed riders have left. Their records are kept until '
                      'this ride ends.',
            style: const TextStyle(color: Color(0xFF9DA8B6), height: 1.3),
          ),
        ),
        TextButton(
          key: const Key('roster-show-departed'),
          onPressed: onShow,
          child: const Text('Show'),
        ),
      ],
    ),
  );
}

/// Where the leader's most recent request has got to. Pending is stated as
/// pending: until the rider accepts, the back is not covered.
class _TecRequestStatus extends StatelessWidget {
  const _TecRequestStatus({required this.assignment});

  final TecRoleAssignment assignment;

  @override
  Widget build(BuildContext context) {
    final accepted = assignment.isAccepted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Card(
        key: const Key('roster-tec-request-status'),
        margin: EdgeInsets.zero,
        color: accepted ? const Color(0xFF1E3326) : const Color(0xFF1F2A38),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Icon(
                accepted
                    ? Icons.check_circle_outline
                    : assignment.isPending
                    ? Icons.hourglass_top_outlined
                    : Icons.info_outline,
                size: 20,
                color: accepted
                    ? const Color(0xFF59D18C)
                    : const Color(0xFF9DC4FF),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  assignment.statusLabel,
                  style: const TextStyle(height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.participant,
    required this.now,
    this.effectiveTecRiderId,
    this.onAskToBeTec,
    this.peerAppIsOlder = false,
  });

  final RideParticipant participant;
  final DateTime now;
  final String? effectiveTecRiderId;
  final VoidCallback? onAskToBeTec;
  final bool peerAppIsOlder;

  @override
  Widget build(BuildContext context) {
    final role = participant.riderId == effectiveTecRiderId
        ? 'Tail End Charlie'
        : participant.role == RideRole.tailEndCharlie &&
              effectiveTecRiderId != null
        ? 'Rider · previous TEC selection superseded'
        : _roleLabel(participant.role);
    final lastSeen = _lastSeenLabel(participant.lastSeenAt, now);
    final attention = participant.attentionLabel;
    // A departed rider's record is only useful if it says where they were last
    // known to be, so an absent position is stated rather than left blank.
    final lastKnownPosition = participant.hasLeft
        ? participant.lastKnownPositionLabel ??
              'No position for this rider reached this phone'
        : null;
    final rejoin = participant.rejoinLabel;
    final semanticLabel = [
      participant.displayName,
      if (participant.isLocal) 'you',
      role,
      participant.stateLabel,
      'last seen $lastSeen',
      participant.transportLabel,
      ?rejoin,
      ?lastKnownPosition,
      ?attention,
      if (peerAppIsOlder) 'app is older',
    ].join(', ');
    return Semantics(
      label: semanticLabel,
      child: ListTile(
        key: Key('roster-rider-${participant.riderId}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        leading: RiderMarkerBadge(
          style: participant.motorcycleStyle,
          // Identity colour belongs to the rider, not the role. Lead/TEC and
          // attention remain explicit in text, semantics and status treatment
          // without making the same person change colour between roster and
          // map (#250).
          badgeColor: participant.riderColor.color,
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
              ?rejoin,
              ?lastKnownPosition,
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
        trailing: onAskToBeTec == null
            ? null
            : TextButton(
                key: Key('ask-tec-${participant.riderId}'),
                onPressed: onAskToBeTec,
                child: const Text('Ask to be TEC'),
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
