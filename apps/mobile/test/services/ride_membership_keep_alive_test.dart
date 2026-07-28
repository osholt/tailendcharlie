import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/position_report_policy.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/ride_membership.dart';

/// The #166 guarantee that #27 and #144 must survive: a rider who has stopped
/// moving is still there.
///
/// These tests drive the real [PositionReportGate] rather than hand-written
/// events, because the thing that could regress is the *coupling* — a keep-alive
/// interval that drifts past `inactiveAfter`, or a membership rule that goes back
/// to reading a position's age as evidence of absence. Both layers have to be in
/// the test or neither is protected.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const rideId = 'ride-166';
  final startedAt = DateTime.utc(2026, 7, 27, 10);

  List<RideParticipant> reduce({
    required List<RideEvent> events,
    required DateTime now,
    List<LiveRiderPresence> livePresence = const [],
  }) => const RideMembershipReducer().fromEvents(
    rideId: rideId,
    inviteSecret: secret,
    events: events,
    now: now,
    localRiderId: 'leader',
    localDisplayName: 'Lead',
    localRole: RideRole.lead,
    localJoinedAt: startedAt,
    localMotorcycleStyle: motorcycleIconStyleDefault,
    localRiderColor: riderColorDefault,
    rideStartedAt: startedAt,
    livePresence: livePresence,
  );

  test('a stationary rider stays active for an hour on keep-alives alone', () {
    final events = [
      _join(rideId: rideId, secret: secret, at: startedAt),
      // A phone parked at a cafe for an hour. Every event here is a keep-alive:
      // the gate produced none of them because the rider moved.
      ..._journalledPositions(
        rideId: rideId,
        secret: secret,
        fixes: _stationaryFixes(seconds: 3600, from: startedAt),
      ),
    ];

    // Every reported event is a keep-alive, so nothing in this journal claims
    // movement.
    expect(events.length - 1, 240);

    // Sampled across the whole hour, including the moments between keep-alives.
    for (var second = 30; second <= 3600; second += 30) {
      final rider = reduce(
        events: events,
        now: startedAt.add(Duration(seconds: second)),
      ).singleWhere((participant) => participant.riderId == 'parked');
      expect(
        rider.state,
        RideMembershipState.active,
        reason: '$second s into the stop',
      );
      expect(rider.isIncludedInLiveCount, isTrue);
    }
  });

  test('a rider whose keep-alives stop does become inactive', () {
    // The other half of the guarantee: silence still means something. Without
    // this the change would make every rider permanently active and #27's
    // lifecycle would be decoration.
    final events = [
      _join(rideId: rideId, secret: secret, at: startedAt),
      ..._journalledPositions(
        rideId: rideId,
        secret: secret,
        fixes: _stationaryFixes(seconds: 60, from: startedAt),
      ),
    ];

    RideParticipant riderAt(Duration elapsed) => reduce(
      events: events,
      now: startedAt.add(elapsed),
    ).singleWhere((participant) => participant.riderId == 'parked');

    expect(
      riderAt(const Duration(minutes: 1)).state,
      RideMembershipState.active,
    );
    // The last keep-alive was at 45 s, so two minutes after it the rider has
    // been silent for longer than `inactiveAfter`.
    expect(
      riderAt(const Duration(minutes: 3)).state,
      RideMembershipState.inactive,
    );
    expect(
      riderAt(const Duration(minutes: 3)).stateLabel,
      startsWith('Inactive · not heard from'),
    );
  });

  test('presence contact keeps a rider active when their position is old', () {
    // The membership rule that had to change. A peer republishing an unchanged
    // position is in contact *now*; dating that contact to when the position was
    // recorded would read a parked rider as one who had gone.
    final events = [_join(rideId: rideId, secret: secret, at: startedAt)];

    RideParticipant riderAt(Duration elapsed) {
      final now = startedAt.add(elapsed);
      return reduce(
        events: events,
        now: now,
        livePresence: [
          _parkedPresence(
            knownSince: startedAt,
            // The position is as old as the stop, and correct: they have not
            // moved a metre since they reported it.
            recordedAt: startedAt,
            // Contact is four seconds ago, because the presence poll is a timer.
            contactAt: now.subtract(const Duration(seconds: 4)),
          ),
        ],
      ).singleWhere((participant) => participant.riderId == 'parked');
    }

    expect(
      riderAt(const Duration(minutes: 30)).state,
      RideMembershipState.active,
    );
    // And past `expireAfter`, which is the case that would have caught a rule
    // reading the position's own timestamp: thirteen hours of standing still must
    // not expire a rider who never stopped reporting.
    expect(
      riderAt(const Duration(hours: 13)).state,
      RideMembershipState.active,
    );
  });
}

/// A relay-stamped presence entry for a rider who is parked and still
/// republishing, as `LivePresenceReconciler` would produce it.
LiveRiderPresence _parkedPresence({
  required DateTime knownSince,
  required DateTime recordedAt,
  required DateTime contactAt,
}) => LiveRiderPresence(
  riderId: 'parked',
  displayName: 'Parked',
  role: RideRole.rider,
  freshness: PresenceFreshness.live,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: knownSince,
  location: RiderLocation(
    riderId: 'parked',
    displayName: 'Parked',
    role: RideRole.rider,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.5, longitude: -2.4),
      recordedAt: recordedAt,
      accuracyMeters: 5,
    ),
    receivedAt: recordedAt,
  ),
  age: const Duration(seconds: 4),
  contactAt: contactAt,
);

/// A phone that is not moving but whose receiver wanders enough to keep the OS
/// delivering.
List<LocationSample> _stationaryFixes({
  required int seconds,
  required DateTime from,
}) => [
  for (var second = 0; second < seconds; second += 1)
    LocationSample(
      position: GeoPoint(
        latitude: 51.5 + 6 * math.cos(second * 1.9) / 111132,
        longitude: -2.4 + 6 * math.sin(second * 1.9) / 69163,
      ),
      recordedAt: from.add(Duration(seconds: second)),
      accuracyMeters: 5,
      speedMetersPerSecond: 0,
    ),
];

/// The fixes the gate agreed to report, as signed journal events — the same path
/// the ride shell takes.
List<RideEvent> _journalledPositions({
  required String rideId,
  required String secret,
  required List<LocationSample> fixes,
}) {
  final gate = PositionReportGate();
  final events = <RideEvent>[];
  for (final fix in fixes) {
    final reason = gate.consider(fix);
    if (reason == null) continue;
    // Nothing in this journal may claim the rider moved.
    expect(reason.isMovement, isFalse);
    events.add(
      _signed(
        rideId: rideId,
        secret: secret,
        id: 'position-${events.length}',
        deviceId: 'parked',
        type: RideEventType.riderLocationUpdated,
        createdAt: fix.recordedAt,
        payload: {
          'location': RiderLocation(
            riderId: 'parked',
            displayName: 'Parked',
            role: RideRole.rider,
            sample: fix,
            receivedAt: fix.recordedAt,
          ).toJson(),
        },
      ),
    );
  }
  return events;
}

RideEvent _join({
  required String rideId,
  required String secret,
  required DateTime at,
}) => _signed(
  rideId: rideId,
  secret: secret,
  id: 'join-parked',
  deviceId: 'parked',
  type: RideEventType.riderJoined,
  createdAt: at,
  payload: const {'displayName': 'Parked', 'role': 'rider'},
);

RideEvent _signed({
  required String rideId,
  required String secret,
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: id,
    rideId: rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: RideEventAuthenticator.sign(unsigned, secret),
  );
}
