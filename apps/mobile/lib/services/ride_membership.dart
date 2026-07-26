import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/rider_color.dart';
import '../domain/rider_location.dart';
import '../features/map/motorcycle_icon.dart';
import '../relay/live_presence.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';

enum RideMembershipState { joined, active, inactive, left, expired }

/// Wall-clock `HH:mm` for a roster row.
///
/// Formatted on the value exactly as held, which is the local clock: a journal
/// event's `createdAt` is local whether this phone recorded it or decoded it
/// from the relay. Deliberately not re-derived from a time zone here, so a
/// departure time reads the same as the clock the rider looked at.
String formatRideClockTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

/// Why a rider who is counted in the live total has no position drawn.
///
/// Issue #132: the count and the marker were two separate judgements of the same
/// rider, so a rider could be "one of 2 riders" and simultaneously have no
/// position and no explanation. Every counted rider now resolves to exactly one
/// of these, and only [hasPosition] means a marker is drawn.
enum RidePositionAbsence {
  /// A position is available and drawn.
  hasPosition,

  /// The rider is in the ride and no position has reached this phone yet.
  noPositionReported,

  /// Live positions cannot reach this phone at the moment, so the absence says
  /// nothing about the rider. The transport's own named limitation says why.
  positionChannelUnavailable,
}

extension RidePositionAbsenceLabels on RidePositionAbsence {
  /// Wording for a roster row. Never colour, never silence.
  String? get label => switch (this) {
    RidePositionAbsence.hasPosition => null,
    RidePositionAbsence.noPositionReported => 'no position reported yet',
    RidePositionAbsence.positionChannelUnavailable =>
      'live positions paused on this phone',
  };
}

enum RideTransportEvidence { localDevice, internetRelay, nearbyRelay, journal }

class RideParticipant {
  const RideParticipant({
    required this.riderId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    required this.lastSeenAt,
    required this.state,
    required this.motorcycleStyle,
    required this.riderColor,
    required this.transportEvidence,
    required this.isLocal,
    this.leftAt,
    this.rejoinedAfterLeavingAt,
    this.lastKnownLocation,
    this.attentionLabel,
    this.positionFreshness,
    this.knownFromRelayOnly = false,
    this.positionAbsence = RidePositionAbsence.noPositionReported,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final DateTime joinedAt;
  final DateTime lastSeenAt;
  final DateTime? leftAt;

  /// The departure this rider's current membership replaced, when they left and
  /// came back (#27's rejoin rule). Non-null only while [leftAt] is null: one
  /// identity, one row, and the history stays readable rather than becoming a
  /// second row or vanishing.
  final DateTime? rejoinedAfterLeavingAt;

  /// The newest position this phone ever held for this rider, frozen at their
  /// departure once they leave (#144).
  ///
  /// It exists so a rider who has left is still findable afterwards — a lost
  /// item, a question — and it is read from the ride's own journal, so it lives
  /// exactly as long as the ride and is deleted with it.
  ///
  /// **Never a marker source.** A departed rider is not there; only
  /// [RideLiveView.renderedPositions] draws, and that comes from live presence.
  final RiderLocation? lastKnownLocation;
  final RideMembershipState state;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderColor riderColor;
  final Set<RideTransportEvidence> transportEvidence;
  final bool isLocal;
  final String? attentionLabel;

  /// How fresh this rider's newest position is, or null when live presence was
  /// not evaluated for this roster.
  final PresenceFreshness? positionFreshness;

  /// True when the only evidence of this rider is the relay's out-of-band
  /// roster or presence channel — their membership event has not arrived in the
  /// durable journal yet. They are still a real, reachable participant.
  final bool knownFromRelayOnly;

  /// Whether this rider's position is drawn, and if not, the stated reason.
  ///
  /// A rider in the live count with [RidePositionAbsence.hasPosition] must have
  /// a rendered marker; any other value must be shown in words. There is no
  /// third state.
  final RidePositionAbsence positionAbsence;

  bool get isIncludedInLiveCount =>
      state != RideMembershipState.left && state != RideMembershipState.expired;

  bool get isEligibleForLivePosition => isIncludedInLiveCount;

  /// True when this rider's position state is accounted for: either drawn, or
  /// absent with a reason a rider can read. Asserted by [RideLiveView].
  bool get hasStatedPositionState =>
      !isIncludedInLiveCount ||
      positionAbsence == RidePositionAbsence.hasPosition ||
      positionAbsence.label != null;

  bool get isEligibleForRouteAlerts => state == RideMembershipState.active;

  /// True when this rider has left and their record is being kept for the rest
  /// of the ride (#144).
  bool get hasLeft => state == RideMembershipState.left;

  String get stateLabel {
    final departedAt = leftAt;
    final base = switch (state) {
      RideMembershipState.joined => 'Joined · waiting to ride',
      RideMembershipState.active => 'Active now',
      RideMembershipState.inactive => 'Inactive · location is stale',
      // Its own state, with the time on it: "Left at 14:32" is neither active
      // nor inactive, and the row stays until the ride is over.
      RideMembershipState.left =>
        departedAt == null
            ? 'Left the ride'
            : 'Left the ride at ${formatRideClockTime(departedAt)}',
      RideMembershipState.expired => 'Expired',
    };
    if (state == RideMembershipState.left ||
        state == RideMembershipState.expired) {
      return base;
    }
    // Stated in words, never by colour alone, and never silently absent: a
    // counted rider with no position always says why.
    final suffix = switch (positionFreshness) {
      PresenceFreshness.live => null,
      PresenceFreshness.ageing => 'position ageing',
      PresenceFreshness.stale => 'position stale',
      null || PresenceFreshness.none => positionAbsence.label,
    };
    return suffix == null ? base : '$base · $suffix';
  }

  /// One identity's visible history: they left, and they came back. Null when
  /// there is nothing to say.
  String? get rejoinLabel {
    final previously = rejoinedAfterLeavingAt;
    if (previously == null || hasLeft) return null;
    return 'Rejoined after leaving at ${formatRideClockTime(previously)}';
  }

  /// Where this rider was last known to be, in words. Null when no position for
  /// them ever reached this phone.
  String? get lastKnownPositionLabel {
    final location = lastKnownLocation;
    if (location == null) return null;
    final position = location.sample.position;
    return 'Last known position '
        '${position.latitude.toStringAsFixed(5)}, '
        '${position.longitude.toStringAsFixed(5)} '
        'at ${formatRideClockTime(location.sample.recordedAt)}';
  }

  String get transportLabel {
    if (isLocal) return 'This phone';
    final internet = transportEvidence.contains(
      RideTransportEvidence.internetRelay,
    );
    final nearby = transportEvidence.contains(
      RideTransportEvidence.nearbyRelay,
    );
    if (knownFromRelayOnly) {
      return internet && nearby
          ? 'Internet + nearby · joining'
          : nearby
          ? 'Nearby relay · joining'
          : 'Internet relay · joining';
    }
    if (internet && nearby) return 'Internet + nearby';
    if (internet) return 'Internet relay';
    if (nearby) return 'Nearby relay';
    return 'Saved ride journal';
  }

  RideParticipant copyWith({
    String? displayName,
    RideRole? role,
    DateTime? joinedAt,
    DateTime? lastSeenAt,
    DateTime? leftAt,
    bool clearLeftAt = false,
    DateTime? rejoinedAfterLeavingAt,
    RiderLocation? lastKnownLocation,
    RideMembershipState? state,
    MotorcycleIconStyle? motorcycleStyle,
    RiderColor? riderColor,
    Set<RideTransportEvidence>? transportEvidence,
    bool? isLocal,
    String? attentionLabel,
    bool clearAttention = false,
    PresenceFreshness? positionFreshness,
    bool? knownFromRelayOnly,
    RidePositionAbsence? positionAbsence,
  }) => RideParticipant(
    riderId: riderId,
    displayName: displayName ?? this.displayName,
    role: role ?? this.role,
    joinedAt: joinedAt ?? this.joinedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    leftAt: clearLeftAt ? null : (leftAt ?? this.leftAt),
    rejoinedAfterLeavingAt:
        rejoinedAfterLeavingAt ?? this.rejoinedAfterLeavingAt,
    lastKnownLocation: lastKnownLocation ?? this.lastKnownLocation,
    state: state ?? this.state,
    motorcycleStyle: motorcycleStyle ?? this.motorcycleStyle,
    riderColor: riderColor ?? this.riderColor,
    transportEvidence: transportEvidence ?? this.transportEvidence,
    isLocal: isLocal ?? this.isLocal,
    attentionLabel: clearAttention
        ? null
        : (attentionLabel ?? this.attentionLabel),
    positionFreshness: positionFreshness ?? this.positionFreshness,
    knownFromRelayOnly: knownFromRelayOnly ?? this.knownFromRelayOnly,
    positionAbsence: positionAbsence ?? this.positionAbsence,
  );
}

/// The one reconciled live model: the rider count, the roster rows, the main map
/// and the mini-map all derive from this and cannot disagree.
///
/// Issue #132: the count came from membership while the marker came from a
/// separate freshness judgement, so a leader could count a follower and refuse
/// to draw them with nothing said. [reconcile] makes that state unrepresentable:
/// every counted rider is either in [renderedPositions] or in
/// [countedWithoutPosition] with a stated reason, and never in both or neither.
class RideLiveView {
  RideLiveView._(this.participants, this.renderedPositions)
    : assert(
        participants.every((participant) => participant.hasStatedPositionState),
        'A rider in the live count must have a position or a stated reason.',
      );

  /// Builds the reconciled view from the membership roster and the reconciled
  /// live presence for the same rider set.
  ///
  /// [positionChannelUnavailable] is true when this device cannot currently
  /// receive positions at all, so an absence is attributed to the transport
  /// rather than to the rider.
  factory RideLiveView.reconcile({
    required Iterable<RideParticipant> participants,
    required Iterable<LiveRiderPresence> presence,
    bool positionChannelUnavailable = false,
  }) {
    final presenceById = {for (final entry in presence) entry.riderId: entry};
    final resolved = <RideParticipant>[];
    final positions = <RiderLocation>[];
    for (final participant in participants) {
      final location = presenceById[participant.riderId]?.location;
      final absence = location != null
          ? RidePositionAbsence.hasPosition
          : positionChannelUnavailable
          ? RidePositionAbsence.positionChannelUnavailable
          : RidePositionAbsence.noPositionReported;
      resolved.add(participant.copyWith(positionAbsence: absence));
      if (location != null && participant.isEligibleForLivePosition) {
        positions.add(location);
      }
    }
    return RideLiveView._(
      List.unmodifiable(resolved),
      List.unmodifiable(positions),
    );
  }

  /// Every rider in the ride, each carrying a resolved position state.
  final List<RideParticipant> participants;

  /// The positions to draw: one per counted rider that has one. Nothing else is
  /// drawable, and nothing drawable is missing from the count.
  final List<RiderLocation> renderedPositions;

  List<RideParticipant> get liveParticipants => List.unmodifiable([
    for (final participant in participants)
      if (participant.isIncludedInLiveCount) participant,
  ]);

  int get liveRiderCount => liveParticipants.length;

  /// Counted riders with no marker, each with a reason to show.
  List<RideParticipant> get countedWithoutPosition => List.unmodifiable([
    for (final participant in liveParticipants)
      if (participant.positionAbsence != RidePositionAbsence.hasPosition)
        participant,
  ]);

  /// The count and the drawn positions agree: every counted rider is accounted
  /// for exactly once.
  bool get isReconciled =>
      renderedPositions.length + countedWithoutPosition.length ==
      liveRiderCount;
}

class RideMembershipReducer {
  const RideMembershipReducer({
    this.inactiveAfter = const Duration(minutes: 2),
    this.expireAfter = const Duration(hours: 12),
  });

  final Duration inactiveAfter;
  final Duration expireAfter;

  List<RideParticipant> fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
    required DateTime now,
    required String localRiderId,
    required String localDisplayName,
    required RideRole localRole,
    required DateTime localJoinedAt,
    required MotorcycleIconStyle localMotorcycleStyle,
    required RiderColor localRiderColor,
    DateTime? rideStartedAt,
    DateTime? rideEndedAt,
    Map<String, Set<RideTransportEvidence>> transportByEventId = const {},
    Iterable<LiveRiderPresence> livePresence = const [],
    Iterable<PresenceRosterMember> presenceRoster = const [],
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
    final participants = <String, RideParticipant>{
      localRiderId: RideParticipant(
        riderId: localRiderId,
        displayName: localDisplayName,
        role: localRole,
        joinedAt: localJoinedAt,
        lastSeenAt: localJoinedAt,
        state: RideMembershipState.joined,
        motorcycleStyle: localMotorcycleStyle,
        riderColor: localRiderColor,
        transportEvidence: const {RideTransportEvidence.localDevice},
        isLocal: true,
      ),
    };
    final lastActivityAt = <String, DateTime>{};
    // The newest journal position per rider, and the one frozen at a departure.
    // Both come from the ride's own journal, so a retained record is deleted
    // with the ride and nothing new is written to storage (#144).
    final newestLocation = <String, RiderLocation>{};
    final locationAtDeparture = <String, RiderLocation>{};

    for (final event in ordered) {
      final existing = participants[event.deviceId];
      if (event.type == RideEventType.riderLocationUpdated) {
        final location = _location(event);
        if (location != null) newestLocation[event.deviceId] = location;
      }
      if (event.type == RideEventType.rideCreated ||
          event.type == RideEventType.riderJoined) {
        final displayName = _nonEmptyString(event.payload['displayName']);
        final role = _role(event.payload['role']);
        if (displayName == null || role == null) continue;
        final isLocal = event.deviceId == localRiderId;
        participants[event.deviceId] = RideParticipant(
          riderId: event.deviceId,
          displayName: isLocal ? localDisplayName : displayName,
          role: isLocal ? localRole : role,
          joinedAt: event.createdAt,
          lastSeenAt: event.createdAt,
          state: RideMembershipState.joined,
          motorcycleStyle: isLocal
              ? localMotorcycleStyle
              : motorcycleIconStyleFromName(
                  event.payload['motorcycleStyle'] as String?,
                ),
          riderColor: isLocal
              ? localRiderColor
              : riderColorFromName(event.payload['riderColor'] as String?),
          transportEvidence: _evidenceFor(
            event,
            isLocal: isLocal,
            transportByEventId: transportByEventId,
          ),
          isLocal: isLocal,
          // One identity, one row: a rider who left and came back keeps the
          // departure they came back from instead of becoming a second row or
          // losing the history (#27).
          rejoinedAfterLeavingAt:
              existing?.leftAt ?? existing?.rejoinedAfterLeavingAt,
          lastKnownLocation: existing?.lastKnownLocation,
        );
        lastActivityAt.remove(event.deviceId);
        continue;
      }
      if (event.type == RideEventType.riderLeft) {
        final payloadRiderId = event.payload['riderId'];
        if (payloadRiderId != null && payloadRiderId != event.deviceId) {
          continue;
        }
        // A departure is never dropped for want of a join event. Before #144 an
        // unmatched `riderLeft` was ignored, and because live presence also
        // drops a departed rider, the row disappeared altogether: exactly the
        // record the field report needed afterwards.
        final departing =
            existing ??
            _departedFromJournal(
              event,
              location: newestLocation[event.deviceId],
              transportByEventId: transportByEventId,
            );
        if (departing == null) continue;
        final atDeparture =
            newestLocation[event.deviceId] ?? departing.lastKnownLocation;
        if (atDeparture != null) {
          locationAtDeparture[event.deviceId] = atDeparture;
        }
        participants[event.deviceId] = departing.copyWith(
          lastSeenAt: event.createdAt,
          leftAt: event.createdAt,
          state: RideMembershipState.left,
          transportEvidence: Set.unmodifiable({
            ...departing.transportEvidence,
            ..._evidenceFor(
              event,
              isLocal: departing.isLocal,
              transportByEventId: transportByEventId,
            ),
          }),
        );
        continue;
      }
      if (existing == null) continue;
      final evidence = {
        ...existing.transportEvidence,
        ..._evidenceFor(
          event,
          isLocal: existing.isLocal,
          transportByEventId: transportByEventId,
        ),
      };
      if (event.type == RideEventType.roleChanged) {
        final role = _role(event.payload['role']);
        if (role == null) continue;
        participants[event.deviceId] = existing.copyWith(
          role: existing.isLocal ? localRole : role,
          lastSeenAt: event.createdAt,
          transportEvidence: Set.unmodifiable(evidence),
        );
        continue;
      }
      if (existing.leftAt != null) continue;
      participants[event.deviceId] = existing.copyWith(
        lastSeenAt: event.createdAt,
        transportEvidence: Set.unmodifiable(evidence),
      );
      if (_isActivity(event.type)) {
        lastActivityAt[event.deviceId] = event.createdAt;
      }
    }

    // A rider the relay can demonstrably reach must appear even when their
    // membership event has not arrived through the bulk batch. Otherwise a
    // wedged or backed-off sync hides a participant completely, and every
    // surface that filters positions by participant drops their marker too.
    final presenceById = <String, LiveRiderPresence>{};
    for (final presence in livePresence) {
      presenceById[presence.riderId] = presence;
      if (participants.containsKey(presence.riderId)) continue;
      final evidence = _presenceEvidence(presence);
      participants[presence.riderId] = RideParticipant(
        riderId: presence.riderId,
        displayName: presence.displayName,
        role: presence.role,
        joinedAt: presence.knownSince,
        lastSeenAt: presence.location?.sample.recordedAt ?? presence.knownSince,
        state: RideMembershipState.joined,
        motorcycleStyle: presence.motorcycleStyle,
        riderColor: presence.riderColor,
        // A roster entry with no position yet is still internet-relay evidence:
        // the relay named the rider.
        transportEvidence: Set.unmodifiable(
          evidence.isEmpty
              ? const {RideTransportEvidence.internetRelay}
              : evidence,
        ),
        isLocal: false,
        knownFromRelayOnly: true,
      );
    }

    // The mirror image of the loop above, for a rider who has *gone*. Live
    // presence deliberately drops a departed rider — they are not there — so the
    // relay's roster is the only channel that still names them when their
    // membership events never made it into this phone's journal. Keeping the row
    // here is what stops a departure erasing the record (#144).
    for (final member in presenceRoster) {
      if (!member.left || member.riderId == localRiderId) continue;
      final existing = participants[member.riderId];
      final departedAt = member.leftAt;
      if (existing != null) {
        // Already recorded as gone by the journal, which carries the time.
        if (existing.hasLeft) continue;
        // A relay without a departure time cannot be ordered against a rejoin,
        // so it may only add a row it alone knows about, never overrule one the
        // journal is maintaining. The journal's own `riderLeft` follows.
        if (departedAt == null) continue;
        // The journal has a later membership: they came back after this
        // departure, and a stale roster flag must not resurrect the ghost.
        if (existing.joinedAt.isAfter(departedAt)) continue;
        participants[member.riderId] = existing.copyWith(
          leftAt: departedAt,
          lastSeenAt: existing.lastSeenAt.isAfter(departedAt)
              ? existing.lastSeenAt
              : departedAt,
          state: RideMembershipState.left,
        );
        continue;
      }
      participants[member.riderId] = RideParticipant(
        riderId: member.riderId,
        displayName: member.displayName,
        role: member.role,
        joinedAt: member.joinedAt,
        lastSeenAt: departedAt ?? member.joinedAt,
        leftAt: departedAt,
        state: RideMembershipState.left,
        motorcycleStyle: member.motorcycleStyle,
        riderColor: member.riderColor,
        transportEvidence: const {RideTransportEvidence.internetRelay},
        isLocal: false,
        knownFromRelayOnly: true,
      );
    }

    for (final event in ordered) {
      if (event.type != RideEventType.routeDeviationChanged &&
          event.type != RideEventType.routeAlertAcknowledged) {
        continue;
      }
      final alert = event.payload['alert'];
      if (alert is! Map) continue;
      final riderId = alert['riderId'];
      final assessment = alert['assessment'];
      final state = assessment is Map ? assessment['state'] : null;
      final participant = riderId is String ? participants[riderId] : null;
      if (participant == null) continue;
      // A rider who has left is not off course, not being looked for, and not
      // something the group can act on. Their record says they left; it must not
      // also keep claiming an alert that stopped applying when they went.
      if (participant.hasLeft) continue;
      final label = switch (state) {
        'offRoute' => 'Off course',
        'suspectedOffRoute' => 'Route check',
        'staleGps' => 'GPS stale',
        _ => null,
      };
      participants[riderId as String] = participant.copyWith(
        attentionLabel: label,
        clearAttention: label == null,
      );
    }

    final result =
        participants.values
            .map((participant) {
              final presence = presenceById[participant.riderId];
              // Where this rider was last known to be. A departed rider keeps
              // the position frozen at their departure; nothing here is ever
              // drawn, because only live presence produces a marker.
              final recorded = participant.copyWith(
                lastKnownLocation: participant.hasLeft
                    ? locationAtDeparture[participant.riderId] ??
                          newestLocation[participant.riderId]
                    : newestLocation[participant.riderId],
              );
              final resolved = presence == null
                  ? recorded
                  : recorded.copyWith(
                      positionFreshness: presence.freshness,
                      transportEvidence: Set.unmodifiable({
                        ...recorded.transportEvidence,
                        ..._presenceEvidence(presence),
                      }),
                    );
              if (resolved.state == RideMembershipState.left) {
                return resolved;
              }
              // A live presence position is current proof of reachability, so
              // it counts as recent contact even if no journal event has
              // arrived. Without this a demonstrably visible rider expires.
              final presenceSeenAt =
                  presence != null && presence.freshness.isTrackedAsContact
                  ? presence.location?.sample.recordedAt
                  : null;
              final lastSeenAt =
                  presenceSeenAt != null &&
                      presenceSeenAt.isAfter(resolved.lastSeenAt)
                  ? presenceSeenAt
                  : resolved.lastSeenAt;
              final age = now.difference(lastSeenAt);
              if (rideEndedAt != null || age >= expireAfter) {
                return resolved.copyWith(state: RideMembershipState.expired);
              }
              if (rideStartedAt == null) {
                return resolved.copyWith(state: RideMembershipState.joined);
              }
              final activityAt = lastActivityAt[resolved.riderId];
              if ((activityAt != null &&
                      now.difference(activityAt) < inactiveAfter) ||
                  presenceSeenAt != null) {
                return resolved.copyWith(state: RideMembershipState.active);
              }
              final waitingSince = resolved.joinedAt.isAfter(rideStartedAt)
                  ? resolved.joinedAt
                  : rideStartedAt;
              if (now.difference(waitingSince) < inactiveAfter) {
                return resolved.copyWith(state: RideMembershipState.joined);
              }
              return resolved.copyWith(state: RideMembershipState.inactive);
            })
            .toList(growable: false)
          ..sort((left, right) {
            final byJoin = left.joinedAt.compareTo(right.joinedAt);
            if (byJoin != 0) return byJoin;
            return left.riderId.compareTo(right.riderId);
          });
    return List.unmodifiable(result);
  }

  /// The rider's own position from an authenticated journal location event, or
  /// null when the payload is not one this build can read. A rider may only
  /// report their own position, so anything else is discarded.
  static RiderLocation? _location(RideEvent event) {
    final raw = event.payload['location'];
    if (raw is! Map) return null;
    try {
      final location = RiderLocation.fromJson(Map<String, Object?>.from(raw));
      return location.riderId == event.deviceId ? location : null;
    } on Object {
      return null;
    }
  }

  /// A record for a rider whose departure reached this phone but whose join
  /// never did.
  ///
  /// Null when there is no name to show from either the departure itself or a
  /// position they reported: a row nobody can identify is worse than no row, and
  /// #27 was raised partly over generic device labels. The role is taken from
  /// their own last position when it is known.
  static RideParticipant? _departedFromJournal(
    RideEvent event, {
    required RiderLocation? location,
    required Map<String, Set<RideTransportEvidence>> transportByEventId,
  }) {
    final displayName =
        _nonEmptyString(event.payload['displayName']) ?? location?.displayName;
    if (displayName == null) return null;
    return RideParticipant(
      riderId: event.deviceId,
      displayName: displayName,
      role: location?.role ?? RideRole.rider,
      joinedAt: location?.sample.recordedAt ?? event.createdAt,
      lastSeenAt: event.createdAt,
      state: RideMembershipState.left,
      motorcycleStyle: location?.motorcycleStyle ?? motorcycleIconStyleDefault,
      riderColor: location?.riderColor ?? riderColorDefault,
      transportEvidence: _evidenceFor(
        event,
        isLocal: false,
        transportByEventId: transportByEventId,
      ),
      isLocal: false,
      lastKnownLocation: location,
    );
  }

  static Set<RideTransportEvidence> _presenceEvidence(
    LiveRiderPresence presence,
  ) => {
    if (presence.sources.contains(LivePresenceSource.internetPresence))
      RideTransportEvidence.internetRelay,
    if (presence.sources.contains(LivePresenceSource.nearbyPresence))
      RideTransportEvidence.nearbyRelay,
  };

  static bool _isActivity(RideEventType type) => switch (type) {
    RideEventType.rideCreated ||
    RideEventType.riderJoined ||
    RideEventType.riderLeft ||
    RideEventType.roleChanged => false,
    _ => true,
  };

  static Set<RideTransportEvidence> _evidenceFor(
    RideEvent event, {
    required bool isLocal,
    required Map<String, Set<RideTransportEvidence>> transportByEventId,
  }) {
    if (isLocal) return const {RideTransportEvidence.localDevice};
    final evidence = transportByEventId[event.id];
    if (evidence == null || evidence.isEmpty) {
      return const {RideTransportEvidence.journal};
    }
    return Set.unmodifiable(evidence);
  }

  static RideRole? _role(Object? value) {
    if (value is! String) return null;
    try {
      return RideRole.values.byName(value);
    } on ArgumentError {
      return null;
    }
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }
}
