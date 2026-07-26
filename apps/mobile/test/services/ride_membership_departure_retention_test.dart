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

/// Issue #144: leaving a ride *erased* the rider. The field report is the
/// requirement — "It would be good to keep that until at least the end of the
/// ride just in case something came up like a lost item etc." — so a departure
/// now demotes a rider out of the live group and keeps their record: who they
/// were, when they went, and where they were last known to be.
///
/// The other half of the requirement is that nothing else changes: a departed
/// rider is still out of the live count, out of route alerts, and out of the
/// rendered positions (#27, #132).
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const rideId = 'ride-a';
  final startedAt = DateTime.utc(2026, 7, 26, 14);
  final now = startedAt.add(const Duration(minutes: 30));

  List<RideParticipant> reduce({
    List<RideEvent> events = const [],
    List<LiveRiderPresence> livePresence = const [],
    List<PresenceRosterMember> presenceRoster = const [],
    DateTime? rideEndedAt,
  }) => const RideMembershipReducer().fromEvents(
    rideId: rideId,
    inviteSecret: secret,
    events: events,
    now: now,
    localRiderId: 'leader',
    localDisplayName: 'Oliver',
    localRole: RideRole.lead,
    localJoinedAt: startedAt,
    localMotorcycleStyle: motorcycleIconStyleDefault,
    localRiderColor: riderColorDefault,
    rideStartedAt: startedAt,
    rideEndedAt: rideEndedAt,
    livePresence: livePresence,
    presenceRoster: presenceRoster,
  );

  RideParticipant riderIn(List<RideParticipant> participants, String riderId) =>
      participants.singleWhere((participant) => participant.riderId == riderId);

  test(
    'a rider who leaves keeps their row, their role and where they were',
    () {
      final participants = reduce(
        events: [
          _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
          _roleChanged(
            deviceId: 'bill',
            role: RideRole.tailEndCharlie,
            at: startedAt.add(const Duration(minutes: 1)),
          ),
          _location(
            deviceId: 'bill',
            displayName: 'Bill',
            role: RideRole.tailEndCharlie,
            at: startedAt.add(const Duration(minutes: 10)),
            latitude: 51.20011,
            longitude: -2.40022,
          ),
          _left(
            deviceId: 'bill',
            displayName: 'Bill',
            at: startedAt.add(const Duration(minutes: 32)),
          ),
        ],
      );

      final bill = riderIn(participants, 'bill');
      expect(bill.state, RideMembershipState.left);
      expect(bill.hasLeft, isTrue);
      // Marked as having left, and when.
      expect(bill.leftAt, startedAt.add(const Duration(minutes: 32)));
      expect(bill.stateLabel, 'Left the ride at 14:32');
      // Role and last-seen survive: this is the record you look somebody up in.
      expect(bill.role, RideRole.tailEndCharlie);
      expect(bill.lastSeenAt, startedAt.add(const Duration(minutes: 32)));
      // Last known position survives, read from the ride's own journal.
      expect(bill.lastKnownLocation?.sample.position.latitude, 51.20011);
      expect(bill.lastKnownPositionLabel, contains('51.20011, -2.40022'));
      // And they are out of the live group, immediately.
      expect(bill.isIncludedInLiveCount, isFalse);
      expect(bill.isEligibleForLivePosition, isFalse);
      expect(bill.isEligibleForRouteAlerts, isFalse);
    },
  );

  test('the retained position is the one from before they left', () {
    final participants = reduce(
      events: [
        _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 5)),
          latitude: 51.1,
          longitude: -2.1,
        ),
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 9)),
          latitude: 51.9,
          longitude: -2.9,
        ),
        _left(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 10)),
        ),
        // A duplicate or late-delivered position from after the departure must
        // not move a rider who has gone.
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 12)),
          latitude: 52.5,
          longitude: -3.5,
        ),
      ],
    );

    final bill = riderIn(participants, 'bill');
    expect(bill.lastKnownLocation?.sample.position.latitude, 51.9);
    expect(bill.lastSeenAt, startedAt.add(const Duration(minutes: 10)));
  });

  test('a departure whose join never arrived still leaves a record', () {
    // The #132 failure mode: a wedged or backed-off batch sync means a rider is
    // known to the relay but their membership events are not in this journal.
    // Before #144 the unmatched departure was dropped and live presence stopped
    // naming them, so the rider vanished from the roster entirely.
    final participants = reduce(
      events: [
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          role: RideRole.marker,
          at: startedAt.add(const Duration(minutes: 4)),
          latitude: 51.5,
          longitude: -2.5,
        ),
        _left(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 6)),
        ),
      ],
    );

    final bill = riderIn(participants, 'bill');
    expect(bill.state, RideMembershipState.left);
    expect(bill.displayName, 'Bill');
    expect(bill.role, RideRole.marker);
    expect(bill.stateLabel, 'Left the ride at 14:06');
    expect(bill.lastKnownLocation?.sample.position.latitude, 51.5);
    expect(bill.isIncludedInLiveCount, isFalse);
  });

  test('an unidentifiable departure adds no row at all', () {
    final participants = reduce(
      events: [_left(deviceId: 'ghost', displayName: null, at: startedAt)],
    );

    expect(
      participants.where((participant) => participant.riderId == 'ghost'),
      isEmpty,
      reason: 'a row nobody can identify is worse than no row',
    );
  });

  test("the relay's roster keeps a departed rider this journal never saw", () {
    // Presence deliberately drops a departed rider, so the roster is the only
    // channel still naming them when the batch has delivered nothing.
    final participants = reduce(
      presenceRoster: [
        _rosterMember(
          riderId: 'bill',
          displayName: 'Bill',
          role: RideRole.tailEndCharlie,
          joinedAt: startedAt,
          left: true,
          leftAt: startedAt.add(const Duration(minutes: 32)),
        ),
      ],
    );

    final bill = riderIn(participants, 'bill');
    expect(bill.state, RideMembershipState.left);
    expect(bill.stateLabel, 'Left the ride at 14:32');
    expect(bill.role, RideRole.tailEndCharlie);
    expect(bill.knownFromRelayOnly, isTrue);
    expect(bill.isIncludedInLiveCount, isFalse);
    expect(bill.lastKnownPositionLabel, isNull);
  });

  test("the relay's roster marks a journal-known rider as left", () {
    // The fast channel: the roster carries the departure before the batch does,
    // which is the propagation the field report saw working. The row must say
    // "left", not drift into "inactive".
    final participants = reduce(
      events: [_join(deviceId: 'bill', displayName: 'Bill', at: startedAt)],
      presenceRoster: [
        _rosterMember(
          riderId: 'bill',
          displayName: 'Bill',
          joinedAt: startedAt,
          left: true,
          leftAt: startedAt.add(const Duration(minutes: 20)),
        ),
      ],
    );

    final bill = riderIn(participants, 'bill');
    expect(bill.state, RideMembershipState.left);
    expect(bill.leftAt, startedAt.add(const Duration(minutes: 20)));
    expect(bill.isIncludedInLiveCount, isFalse);
  });

  test(
    'a stale roster departure never resurrects the ghost after a rejoin',
    () {
      final participants = reduce(
        events: [
          _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
          _left(
            deviceId: 'bill',
            displayName: 'Bill',
            at: startedAt.add(const Duration(minutes: 10)),
          ),
          _join(
            deviceId: 'bill',
            displayName: 'Bill',
            at: startedAt.add(const Duration(minutes: 20)),
          ),
        ],
        presenceRoster: [
          _rosterMember(
            riderId: 'bill',
            displayName: 'Bill',
            joinedAt: startedAt,
            left: true,
            leftAt: startedAt.add(const Duration(minutes: 10)),
          ),
        ],
      );

      expect(
        participants.where((participant) => participant.riderId == 'bill'),
        hasLength(1),
      );
      final bill = riderIn(participants, 'bill');
      expect(bill.hasLeft, isFalse);
      expect(bill.isIncludedInLiveCount, isTrue);
      expect(bill.rejoinLabel, 'Rejoined after leaving at 14:10');
    },
  );

  test('a relay with no departure time may add a row, never overrule one', () {
    final participants = reduce(
      events: [_join(deviceId: 'bill', displayName: 'Bill', at: startedAt)],
      presenceRoster: [
        _rosterMember(
          riderId: 'bill',
          displayName: 'Bill',
          joinedAt: startedAt,
          left: true,
        ),
        _rosterMember(
          riderId: 'sam',
          displayName: 'Sam',
          joinedAt: startedAt,
          left: true,
        ),
      ],
    );

    // Bill's row stays with the journal until its own `riderLeft` arrives: an
    // undated departure cannot be ordered against a rejoin.
    expect(riderIn(participants, 'bill').hasLeft, isFalse);
    // Sam is known to nobody else, so the undated departure is all there is.
    final sam = riderIn(participants, 'sam');
    expect(sam.hasLeft, isTrue);
    expect(sam.stateLabel, 'Left the ride');
    expect(sam.isIncludedInLiveCount, isFalse);
  });

  test('a departed rider stops carrying a route alert', () {
    final participants = reduce(
      events: [
        _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
        _event(
          id: 'alert-bill',
          deviceId: 'leader',
          type: RideEventType.routeDeviationChanged,
          createdAt: startedAt.add(const Duration(minutes: 4)),
          payload: const {
            'alert': {
              'riderId': 'bill',
              'assessment': {'state': 'offRoute'},
            },
          },
        ),
        _left(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 5)),
        ),
      ],
    );

    final bill = riderIn(participants, 'bill');
    expect(bill.hasLeft, isTrue);
    expect(
      bill.attentionLabel,
      isNull,
      reason: 'a rider who has gone is not off course',
    );
  });

  test('the record is retained through the end of the ride, not beyond it', () {
    final events = [
      _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
      _location(
        deviceId: 'bill',
        displayName: 'Bill',
        at: startedAt.add(const Duration(minutes: 4)),
        latitude: 51.5,
        longitude: -2.5,
      ),
      _left(
        deviceId: 'bill',
        displayName: 'Bill',
        at: startedAt.add(const Duration(minutes: 5)),
      ),
    ];

    // Ending the ride does not expire the departure into something vaguer, and
    // does not extend it either: the record lives in the ride's own journal.
    final ended = reduce(
      events: events,
      rideEndedAt: startedAt.add(const Duration(minutes: 20)),
    );
    final bill = riderIn(ended, 'bill');
    expect(bill.state, RideMembershipState.left);
    expect(bill.stateLabel, 'Left the ride at 14:05');
    expect(bill.isIncludedInLiveCount, isFalse);

    // Deleting the ride takes its journal, and the record goes with it. There is
    // no other place it is kept.
    final deleted = reduce(rideEndedAt: startedAt);
    expect(
      deleted.where((participant) => participant.riderId == 'bill'),
      isEmpty,
    );
  });
}

RideEvent _join({
  required String deviceId,
  required String displayName,
  required DateTime at,
  RideRole role = RideRole.rider,
}) => _event(
  id: 'join-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: RideEventType.riderJoined,
  createdAt: at,
  payload: {'displayName': displayName, 'role': role.name},
);

RideEvent _left({
  required String deviceId,
  required String? displayName,
  required DateTime at,
}) => _event(
  id: 'left-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: RideEventType.riderLeft,
  createdAt: at,
  payload: {'riderId': deviceId, 'displayName': ?displayName, 'reason': 'left'},
);

RideEvent _roleChanged({
  required String deviceId,
  required RideRole role,
  required DateTime at,
}) => _event(
  id: 'role-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: RideEventType.roleChanged,
  createdAt: at,
  payload: {'role': role.name},
);

RideEvent _location({
  required String deviceId,
  required String displayName,
  required DateTime at,
  required double latitude,
  required double longitude,
  RideRole role = RideRole.rider,
}) => _event(
  id: 'location-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: RideEventType.riderLocationUpdated,
  createdAt: at,
  payload: {
    'location': RiderLocation(
      riderId: deviceId,
      displayName: displayName,
      role: role,
      sample: LocationSample(
        position: GeoPoint(latitude: latitude, longitude: longitude),
        recordedAt: at,
        accuracyMeters: 5,
      ),
      receivedAt: at,
    ).toJson(),
  },
);

PresenceRosterMember _rosterMember({
  required String riderId,
  required String displayName,
  required DateTime joinedAt,
  RideRole role = RideRole.rider,
  bool left = false,
  DateTime? leftAt,
}) => PresenceRosterMember(
  riderId: riderId,
  displayName: displayName,
  role: role,
  joinedAt: joinedAt,
  left: left,
  leftAt: leftAt,
);

RideEvent _event({
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  const secret = '0123456789abcdef0123456789abcdef';
  final unsigned = RideEvent(
    id: id,
    rideId: 'ride-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: id,
    rideId: 'ride-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: RideEventAuthenticator.sign(unsigned, secret),
  );
}
