import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';

/// Where one leader-issued Tail End Charlie request has got to.
///
/// The app is named after the back-marker role, so the leader must be able to
/// tell "I have asked someone" from "someone is actually watching the back".
/// A rider who has not noticed they are TEC is worse than no TEC, because the
/// group then believes the back is covered when nobody is watching it — which
/// is why this is a request the target answers rather than a silent assignment.
enum TecRoleAssignmentStatus {
  /// Sent, not yet answered. The group still has no confirmed back-marker.
  pending,

  /// The target answered yes. They record their own `roleChanged` alongside the
  /// answer, so the role itself stays self-selected and the membership reducer
  /// is unchanged.
  accepted,

  /// The target answered no. Named rather than silently dropped: the leader has
  /// to know to ask somebody else.
  declined,

  /// Unanswered for longer than [TecRoleAssignmentPolicy.requestExpiresAfter].
  /// A request nobody answered must not sit on the leader's screen as "pending"
  /// for the rest of the ride.
  expired,

  /// The leader asked somebody else while this one was still unanswered.
  superseded,

  /// The target left the ride. A departed rider is not a back-marker, whether
  /// they had accepted or not.
  targetLeft,
}

/// One leader-issued request for the Tail End Charlie role.
class TecRoleAssignment {
  const TecRoleAssignment({
    required this.requestId,
    required this.leaderRiderId,
    required this.targetRiderId,
    required this.targetDisplayName,
    required this.requestedAt,
    required this.status,
    this.respondedAt,
  });

  final String requestId;

  /// The rider who issued it, verified to have held [RideRole.lead] at the
  /// moment the event was created.
  final String leaderRiderId;

  final String targetRiderId;

  /// The name the leader saw when they asked. Only ever used as a label, never
  /// as identity.
  final String targetDisplayName;

  final DateTime requestedAt;
  final TecRoleAssignmentStatus status;
  final DateTime? respondedAt;

  bool get isPending => status == TecRoleAssignmentStatus.pending;

  bool get isAccepted => status == TecRoleAssignmentStatus.accepted;

  /// Leader-facing one-liner. Deliberately never claims the role is filled
  /// while the request is unanswered.
  String get statusLabel => switch (status) {
    TecRoleAssignmentStatus.pending =>
      'Asked $targetDisplayName — waiting for them to accept',
    TecRoleAssignmentStatus.accepted =>
      '$targetDisplayName accepted Tail End Charlie',
    TecRoleAssignmentStatus.declined => '$targetDisplayName declined',
    TecRoleAssignmentStatus.expired =>
      '$targetDisplayName never answered, so nobody is covering the back',
    TecRoleAssignmentStatus.superseded =>
      'Superseded — you asked somebody else',
    TecRoleAssignmentStatus.targetLeft =>
      '$targetDisplayName has left the ride',
  };

  TecRoleAssignment _withStatus(
    TecRoleAssignmentStatus next, {
    DateTime? respondedAt,
  }) => TecRoleAssignment(
    requestId: requestId,
    leaderRiderId: leaderRiderId,
    targetRiderId: targetRiderId,
    targetDisplayName: targetDisplayName,
    requestedAt: requestedAt,
    status: next,
    respondedAt: respondedAt ?? this.respondedAt,
  );
}

/// How long an unanswered request stays pending.
///
/// Ten minutes. The situation this exists for is a leader at a fuel stop with a
/// line of bikes: long enough for a rider to get a glove off and answer, short
/// enough that the group is not still being told the back is "about to be"
/// covered a county later.
class TecRoleAssignmentPolicy {
  const TecRoleAssignmentPolicy({
    this.requestExpiresAfter = const Duration(minutes: 10),
  });

  final Duration requestExpiresAfter;
}

/// Every leader-issued Tail End Charlie request in this ride, reconciled.
class TecRoleAssignmentState {
  const TecRoleAssignmentState({this.assignments = const []});

  /// Oldest first, by the journal's own deterministic ordering.
  final List<TecRoleAssignment> assignments;

  /// The request that currently matters — the newest admissible one.
  TecRoleAssignment? get latest =>
      assignments.isEmpty ? null : assignments.last;

  /// The unanswered request addressed to [riderId], if any. This is what raises
  /// the accept/decline prompt on the target's own phone.
  TecRoleAssignment? pendingFor(String riderId) => assignments
      .where(
        (assignment) =>
            assignment.isPending && assignment.targetRiderId == riderId,
      )
      .lastOrNull;

  /// The most recently accepted request still standing.
  TecRoleAssignment? get acceptedAssignment =>
      assignments.where((assignment) => assignment.isAccepted).lastOrNull;

  /// The rider the leader's own record says is Tail End Charlie.
  ///
  /// This is the deterministic tie-break when two riders hold the role at once:
  /// pass it to [LeaderRideStatusCalculator.resolveTecTarget] and the most
  /// recently accepted leader request wins over an arbitrary self-selection.
  String? get acceptedTecRiderId => acceptedAssignment?.targetRiderId;

  /// True while the leader has asked somebody and nobody has answered, so a
  /// surface can say "waiting" instead of either "covered" or "nobody asked".
  bool get hasPendingRequest =>
      assignments.any((assignment) => assignment.isPending);
}

/// Rebuilds [TecRoleAssignmentState] from the signed event journal.
///
/// Deliberately a pure reducer over the durable journal, like every other ride
/// state in this app: it converges the same way for both transports, for
/// out-of-order and duplicate delivery, across a restart, and after a leader
/// handover, because it never depends on arrival order — only on the journal's
/// (createdAt, id) ordering.
///
/// Authority rules, which are what make a forged or replayed assignment
/// harmless:
///
/// * A request is admissible only from a device whose latest signed role **at
///   that point in the journal** is [RideRole.lead], and only when the payload
///   names its own author as the leader. This is exactly how
///   [RideLifecycleReducer] admits `rideStarted`, and how #99 rejects a forged
///   departure.
/// * A response is admissible only from the device the request named. Nobody
///   can accept or decline on another rider's behalf.
/// * A duplicate request id is ignored, and only the first response to a
///   request counts, so replaying a frame changes nothing.
class TecRoleAssignmentReducer {
  const TecRoleAssignmentReducer({
    this.policy = const TecRoleAssignmentPolicy(),
  });

  final TecRoleAssignmentPolicy policy;

  TecRoleAssignmentState fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
    required DateTime now,
  }) {
    final ordered =
        events
            .where(
              (event) =>
                  event.rideId == rideId &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(RideLifecycleReducer.compareEvents);

    final roles = <String, RideRole>{};
    final departed = <String>{};
    final byRequestId = <String, TecRoleAssignment>{};
    final order = <String>[];
    final answered = <String>{};

    for (final event in ordered) {
      switch (event.type) {
        case RideEventType.rideCreated:
        case RideEventType.riderJoined:
        case RideEventType.roleChanged:
          final role = _role(event.payload['role']);
          if (role != null) roles[event.deviceId] = role;
        case RideEventType.riderLeft:
          // Same rule as the membership reducer: a departure only speaks for
          // the device that recorded it.
          final claimed = event.payload['riderId'];
          if (claimed == null || claimed == event.deviceId) {
            departed.add(event.deviceId);
          }
        case RideEventType.tecRoleRequested:
          final assignment = _requestFrom(event, roles);
          if (assignment == null) continue;
          if (byRequestId.containsKey(assignment.requestId)) continue;
          byRequestId[assignment.requestId] = assignment;
          order.add(assignment.requestId);
        case RideEventType.tecRoleResponded:
          // Applied in a second pass below. An answer can legitimately carry an
          // earlier timestamp than the question - two phones, two clocks - and
          // it must still count, so the two halves are never matched by their
          // relative position in the journal.
          break;
        case RideEventType.rideStarted:
        case RideEventType.markerStarted:
        case RideEventType.markerPass:
        case RideEventType.markerEnded:
        case RideEventType.statusMessage:
        case RideEventType.riderLocationUpdated:
        case RideEventType.hazardReported:
        case RideEventType.hazardCleared:
        case RideEventType.routeDeviationChanged:
        case RideEventType.routeAlertAcknowledged:
        case RideEventType.routeRevisionChunk:
        case RideEventType.routeRevisionPublished:
        case RideEventType.routeCleared:
        case RideEventType.ridePaused:
        case RideEventType.rideResumed:
        case RideEventType.rideEnded:
        case RideEventType.iceInfoShared:
        case RideEventType.iceInfoViewed:
        case RideEventType.rejoinRouteShared:
        case RideEventType.riderContactShared:
          break;
      }
    }

    // Second pass: the answers. Ordered, so the first admissible answer to a
    // request wins however many duplicates arrive after it.
    for (final event in ordered) {
      if (event.type != RideEventType.tecRoleResponded) continue;
      final requestId = _identifier(event.payload['requestId']);
      if (requestId == null) continue;
      final request = byRequestId[requestId];
      // Only the rider the leader named may answer, and only once.
      if (request == null ||
          event.deviceId != request.targetRiderId ||
          answered.contains(requestId)) {
        continue;
      }
      final accepted = event.payload['accepted'];
      if (accepted is! bool) continue;
      answered.add(requestId);
      byRequestId[requestId] = request._withStatus(
        accepted
            ? TecRoleAssignmentStatus.accepted
            : TecRoleAssignmentStatus.declined,
        respondedAt: event.createdAt,
      );
    }

    final resolved = <TecRoleAssignment>[];
    for (var index = 0; index < order.length; index += 1) {
      var assignment = byRequestId[order[index]]!;
      final isNewest = index == order.length - 1;
      if (assignment.isPending && !isNewest) {
        assignment = assignment._withStatus(TecRoleAssignmentStatus.superseded);
      } else if (assignment.isPending &&
          now.difference(assignment.requestedAt) >=
              policy.requestExpiresAfter) {
        assignment = assignment._withStatus(TecRoleAssignmentStatus.expired);
      }
      if (departed.contains(assignment.targetRiderId) &&
          (assignment.isPending || assignment.isAccepted)) {
        assignment = assignment._withStatus(TecRoleAssignmentStatus.targetLeft);
      }
      resolved.add(assignment);
    }
    return TecRoleAssignmentState(assignments: List.unmodifiable(resolved));
  }

  /// Builds the request payload the leader records. Kept here so the writer and
  /// the reducer cannot disagree about the field names.
  static Map<String, Object?> requestPayload({
    required String requestId,
    required String leaderRiderId,
    required String targetRiderId,
    required String targetDisplayName,
  }) => {
    'requestId': requestId,
    'leaderRiderId': leaderRiderId,
    'targetRiderId': targetRiderId,
    'targetDisplayName': targetDisplayName,
  };

  /// Builds the answer payload the target records.
  static Map<String, Object?> responsePayload({
    required String requestId,
    required String targetRiderId,
    required bool accepted,
  }) => {
    'requestId': requestId,
    'targetRiderId': targetRiderId,
    'accepted': accepted,
  };

  static TecRoleAssignment? _requestFrom(
    RideEvent event,
    Map<String, RideRole> roles,
  ) {
    // Only the current leader may initiate, and the event must name its own
    // author as that leader. A request forged or replayed by another device
    // fails one of these and is dropped whole.
    if (roles[event.deviceId] != RideRole.lead) return null;
    if (event.payload['leaderRiderId'] != event.deviceId) return null;
    final requestId = _identifier(event.payload['requestId']);
    final targetRiderId = _identifier(event.payload['targetRiderId']);
    if (requestId == null || targetRiderId == null) return null;
    // A leader taking the role themselves is a self-selection, not a request.
    if (targetRiderId == event.deviceId) return null;
    final name = event.payload['targetDisplayName'];
    return TecRoleAssignment(
      requestId: requestId,
      leaderRiderId: event.deviceId,
      targetRiderId: targetRiderId,
      targetDisplayName: name is String && name.trim().isNotEmpty
          ? name.trim()
          : 'That rider',
      requestedAt: event.createdAt,
      status: TecRoleAssignmentStatus.pending,
    );
  }

  static String? _identifier(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 128) return null;
    return trimmed;
  }

  static RideRole? _role(Object? value) {
    if (value is! String) return null;
    try {
      return RideRole.values.byName(value);
    } on ArgumentError {
      return null;
    }
  }
}
