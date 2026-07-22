import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/rider_color.dart';
import '../features/map/motorcycle_icon.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';

enum RideMembershipState { joined, active, inactive, left, expired }

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
    this.attentionLabel,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final DateTime joinedAt;
  final DateTime lastSeenAt;
  final DateTime? leftAt;
  final RideMembershipState state;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderColor riderColor;
  final Set<RideTransportEvidence> transportEvidence;
  final bool isLocal;
  final String? attentionLabel;

  bool get isIncludedInLiveCount =>
      state != RideMembershipState.left && state != RideMembershipState.expired;

  bool get isEligibleForLivePosition => isIncludedInLiveCount;

  bool get isEligibleForRouteAlerts => state == RideMembershipState.active;

  String get stateLabel => switch (state) {
    RideMembershipState.joined => 'Joined · waiting to ride',
    RideMembershipState.active => 'Active now',
    RideMembershipState.inactive => 'Inactive · location is stale',
    RideMembershipState.left => 'Left the ride',
    RideMembershipState.expired => 'Expired',
  };

  String get transportLabel {
    if (isLocal) return 'This phone';
    final internet = transportEvidence.contains(
      RideTransportEvidence.internetRelay,
    );
    final nearby = transportEvidence.contains(
      RideTransportEvidence.nearbyRelay,
    );
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
    RideMembershipState? state,
    MotorcycleIconStyle? motorcycleStyle,
    RiderColor? riderColor,
    Set<RideTransportEvidence>? transportEvidence,
    bool? isLocal,
    String? attentionLabel,
    bool clearAttention = false,
  }) => RideParticipant(
    riderId: riderId,
    displayName: displayName ?? this.displayName,
    role: role ?? this.role,
    joinedAt: joinedAt ?? this.joinedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    leftAt: clearLeftAt ? null : (leftAt ?? this.leftAt),
    state: state ?? this.state,
    motorcycleStyle: motorcycleStyle ?? this.motorcycleStyle,
    riderColor: riderColor ?? this.riderColor,
    transportEvidence: transportEvidence ?? this.transportEvidence,
    isLocal: isLocal ?? this.isLocal,
    attentionLabel: clearAttention
        ? null
        : (attentionLabel ?? this.attentionLabel),
  );
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

    for (final event in ordered) {
      final existing = participants[event.deviceId];
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
        );
        lastActivityAt.remove(event.deviceId);
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
      if (event.type == RideEventType.riderLeft) {
        final payloadRiderId = event.payload['riderId'];
        if (payloadRiderId != null && payloadRiderId != event.deviceId) {
          continue;
        }
        participants[event.deviceId] = existing.copyWith(
          lastSeenAt: event.createdAt,
          leftAt: event.createdAt,
          state: RideMembershipState.left,
          transportEvidence: Set.unmodifiable(evidence),
        );
        continue;
      }
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
              if (participant.state == RideMembershipState.left) {
                return participant;
              }
              final age = now.difference(participant.lastSeenAt);
              if (rideEndedAt != null || age >= expireAfter) {
                return participant.copyWith(state: RideMembershipState.expired);
              }
              if (rideStartedAt == null) {
                return participant.copyWith(state: RideMembershipState.joined);
              }
              final activityAt = lastActivityAt[participant.riderId];
              if (activityAt != null &&
                  now.difference(activityAt) < inactiveAfter) {
                return participant.copyWith(state: RideMembershipState.active);
              }
              final waitingSince = participant.joinedAt.isAfter(rideStartedAt)
                  ? participant.joinedAt
                  : rideStartedAt;
              if (now.difference(waitingSince) < inactiveAfter) {
                return participant.copyWith(state: RideMembershipState.joined);
              }
              return participant.copyWith(state: RideMembershipState.inactive);
            })
            .toList(growable: false)
          ..sort((left, right) {
            final byJoin = left.joinedAt.compareTo(right.joinedAt);
            if (byJoin != 0) return byJoin;
            return left.riderId.compareTo(right.riderId);
          });
    return List.unmodifiable(result);
  }

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
