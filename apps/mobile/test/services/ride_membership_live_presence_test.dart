import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/ride_membership.dart';

/// `riderJoined` used to be visible only through the bulk event batch, so one
/// wedged sync hid a participant entirely — and every surface that filters
/// positions by participant then dropped their marker too.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const rideId = 'ride-membership-presence';
  final startedAt = DateTime.utc(2026, 7, 25, 9);
  final now = startedAt.add(const Duration(minutes: 10));

  List<RideParticipant> reduce({
    List<RideEvent> events = const [],
    List<LiveRiderPresence> livePresence = const [],
    DateTime? rideStartedAt,
  }) => const RideMembershipReducer().fromEvents(
    rideId: rideId,
    inviteSecret: secret,
    events: events,
    now: now,
    localRiderId: 'local',
    localDisplayName: 'Oliver',
    localRole: RideRole.lead,
    localJoinedAt: startedAt,
    localMotorcycleStyle: motorcycleIconStyleDefault,
    localRiderColor: riderColorDefault,
    rideStartedAt: rideStartedAt,
    livePresence: livePresence,
  );

  test('a rider known only to the relay still appears in the roster', () {
    final participants = reduce(
      rideStartedAt: startedAt,
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: PresenceFreshness.live,
          recordedAt: now.subtract(const Duration(seconds: 3)),
          knownSince: startedAt.add(const Duration(minutes: 5)),
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.riderId == 'bill');
    expect(bill.displayName, 'Bill');
    expect(bill.knownFromRelayOnly, isTrue);
    expect(
      bill.transportEvidence,
      contains(RideTransportEvidence.internetRelay),
    );
    expect(bill.transportLabel, 'Internet relay · joining');
    expect(bill.isEligibleForLivePosition, isTrue);
    // A live position is current proof of reachability, so the rider is active
    // rather than "inactive · location is stale".
    expect(bill.state, RideMembershipState.active);
  });

  test('the journal stays authoritative for identity once it arrives', () {
    final participants = reduce(
      rideStartedAt: startedAt,
      events: [
        _joinEvent(
          id: 'joined-bill',
          deviceId: 'bill',
          displayName: 'Bill Smith',
          role: RideRole.tailEndCharlie,
          createdAt: startedAt.add(const Duration(minutes: 1)),
        ),
      ],
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: PresenceFreshness.live,
          recordedAt: now,
          knownSince: startedAt,
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.riderId == 'bill');
    expect(bill.displayName, 'Bill Smith');
    expect(bill.role, RideRole.tailEndCharlie);
    expect(bill.knownFromRelayOnly, isFalse);
    expect(bill.transportLabel, 'Internet relay');
  });

  test('presence never resurrects a rider who has left', () {
    final participants = reduce(
      rideStartedAt: startedAt,
      events: [
        _joinEvent(
          id: 'joined-bill',
          deviceId: 'bill',
          displayName: 'Bill',
          role: RideRole.rider,
          createdAt: startedAt.add(const Duration(minutes: 1)),
        ),
        _event(
          id: 'left-bill',
          deviceId: 'bill',
          type: RideEventType.riderLeft,
          createdAt: startedAt.add(const Duration(minutes: 2)),
          payload: const {'riderId': 'bill', 'reason': 'left'},
        ),
      ],
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: PresenceFreshness.live,
          recordedAt: now,
          knownSince: startedAt,
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.riderId == 'bill');
    expect(bill.state, RideMembershipState.left);
    expect(bill.isIncludedInLiveCount, isFalse);
    // The row stays, and it says when they went (#144): 09:02 for a departure
    // two minutes after this ride started.
    expect(bill.stateLabel, 'Left the ride at 09:02');
    expect(bill.leftAt, startedAt.add(const Duration(minutes: 2)));
  });

  test('the roster states the position age in words', () {
    PresenceFreshness? labelFor(PresenceFreshness freshness) => freshness;
    String stateLabelFor(PresenceFreshness freshness) => reduce(
      rideStartedAt: startedAt,
      events: [
        _joinEvent(
          id: 'joined-bill',
          deviceId: 'bill',
          displayName: 'Bill',
          role: RideRole.rider,
          createdAt: now.subtract(const Duration(seconds: 5)),
        ),
      ],
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: labelFor(freshness)!,
          recordedAt: now.subtract(const Duration(seconds: 5)),
          knownSince: startedAt,
        ),
      ],
    ).firstWhere((entry) => entry.riderId == 'bill').stateLabel;

    expect(stateLabelFor(PresenceFreshness.live), isNot(contains('position')));
    expect(
      stateLabelFor(PresenceFreshness.ageing),
      contains('position ageing'),
    );
    expect(stateLabelFor(PresenceFreshness.stale), contains('position stale'));
    expect(stateLabelFor(PresenceFreshness.none), contains('no position'));
  });

  test('a rider with no position at all is reported, not omitted', () {
    final participants = reduce(
      rideStartedAt: startedAt,
      livePresence: [
        LiveRiderPresence(
          riderId: 'bill',
          displayName: 'Bill',
          role: RideRole.rider,
          freshness: PresenceFreshness.none,
          sources: const {},
          isLocal: false,
          knownSince: startedAt.add(const Duration(minutes: 9)),
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.riderId == 'bill');
    expect(bill.positionFreshness, PresenceFreshness.none);
    expect(bill.stateLabel, contains('no position'));
    expect(bill.knownFromRelayOnly, isTrue);
  });

  test('a nearby-only presence records the nearby transport', () {
    final participants = reduce(
      rideStartedAt: startedAt,
      livePresence: [
        _presence(
          'sam',
          'Sam',
          freshness: PresenceFreshness.live,
          recordedAt: now,
          knownSince: startedAt,
          sources: const {LivePresenceSource.nearbyPresence},
        ),
      ],
    );

    final sam = participants.firstWhere((entry) => entry.riderId == 'sam');
    expect(sam.transportEvidence, {RideTransportEvidence.nearbyRelay});
    expect(sam.transportLabel, 'Nearby relay · joining');
  });

  test('a counted rider with no presence still states why, not nothing', () {
    final events = [
      _joinEvent(
        id: 'joined-bill',
        deviceId: 'bill',
        displayName: 'Bill',
        role: RideRole.rider,
        createdAt: startedAt.add(const Duration(minutes: 1)),
      ),
    ];

    final participants = reduce(events: events, rideStartedAt: startedAt);

    final bill = participants.firstWhere((entry) => entry.riderId == 'bill');
    expect(bill.positionFreshness, isNull);
    // Issue #132: "in the count, no marker, nothing said" is the defect. A
    // rider with no position always carries the reason there is none.
    expect(bill.positionAbsence, RidePositionAbsence.noPositionReported);
    expect(
      bill.stateLabel,
      'Inactive · location is stale · no position reported yet',
    );
    expect(bill.hasStatedPositionState, isTrue);
    expect(bill.knownFromRelayOnly, isFalse);
  });
}

LiveRiderPresence _presence(
  String riderId,
  String displayName, {
  required PresenceFreshness freshness,
  required DateTime recordedAt,
  required DateTime knownSince,
  Set<LivePresenceSource> sources = const {LivePresenceSource.internetPresence},
}) => LiveRiderPresence(
  riderId: riderId,
  displayName: displayName,
  role: RideRole.rider,
  freshness: freshness,
  sources: sources,
  isLocal: false,
  knownSince: knownSince,
  location: RiderLocation(
    riderId: riderId,
    displayName: displayName,
    role: RideRole.rider,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.5, longitude: -2.4),
      recordedAt: recordedAt,
      accuracyMeters: 5,
    ),
    receivedAt: recordedAt,
  ),
  age: const Duration(seconds: 5),
);

RideEvent _joinEvent({
  required String id,
  required String deviceId,
  required String displayName,
  required RideRole role,
  required DateTime createdAt,
}) => _event(
  id: id,
  deviceId: deviceId,
  type: RideEventType.riderJoined,
  createdAt: createdAt,
  payload: {'displayName': displayName, 'role': role.name},
);

RideEvent _event({
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: 'ride-membership-presence',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: unsigned.id,
    rideId: unsigned.rideId,
    deviceId: unsigned.deviceId,
    type: unsigned.type,
    priority: unsigned.priority,
    createdAt: unsigned.createdAt,
    payload: unsigned.payload,
    signature: RideEventAuthenticator.sign(
      unsigned,
      '0123456789abcdef0123456789abcdef',
    ),
  );
}
