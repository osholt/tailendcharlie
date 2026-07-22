import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/ride_membership.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final joinedAt = DateTime.utc(2026, 7, 22, 10);

  test(
    'membership transitions from joined to active, inactive and expired',
    () {
      final events = [
        _event(
          id: 'join-rider',
          deviceId: 'rider-a',
          type: RideEventType.riderJoined,
          createdAt: joinedAt,
          payload: const {
            'displayName': 'Alex',
            'role': 'rider',
            'motorcycleStyle': 'adventure',
            'riderColor': 'blue',
          },
          secret: secret,
        ),
        _event(
          id: 'location-rider',
          deviceId: 'rider-a',
          type: RideEventType.riderLocationUpdated,
          createdAt: joinedAt.add(const Duration(minutes: 1)),
          payload: const {'location': {}},
          secret: secret,
        ),
      ];

      RideParticipant riderAt(DateTime now) => const RideMembershipReducer()
          .fromEvents(
            rideId: 'ride-a',
            inviteSecret: secret,
            events: events,
            now: now,
            localRiderId: 'leader',
            localDisplayName: 'Lead',
            localRole: RideRole.lead,
            localJoinedAt: joinedAt,
            localMotorcycleStyle: motorcycleIconStyleDefault,
            localRiderColor: riderColorDefault,
            rideStartedAt: joinedAt,
            transportByEventId: const {
              'location-rider': {RideTransportEvidence.internetRelay},
            },
          )
          .singleWhere((participant) => participant.riderId == 'rider-a');

      expect(
        riderAt(joinedAt.add(const Duration(minutes: 2))).state,
        RideMembershipState.active,
      );
      expect(
        riderAt(joinedAt.add(const Duration(minutes: 4))).state,
        RideMembershipState.inactive,
      );
      final expired = riderAt(joinedAt.add(const Duration(hours: 13)));
      expect(expired.state, RideMembershipState.expired);
      expect(expired.transportLabel, 'Internet relay');
      expect(expired.isIncludedInLiveCount, isFalse);
    },
  );

  test('leave and later rejoin converge by canonical rider identity', () {
    final events = [
      _event(
        id: 'join-first',
        deviceId: 'same-rider',
        type: RideEventType.riderJoined,
        createdAt: joinedAt,
        payload: const {'displayName': 'Alex', 'role': 'rider'},
        secret: secret,
      ),
      _event(
        id: 'left',
        deviceId: 'same-rider',
        type: RideEventType.riderLeft,
        createdAt: joinedAt.add(const Duration(minutes: 1)),
        payload: const {'riderId': 'same-rider'},
        secret: secret,
      ),
      _event(
        id: 'join-again',
        deviceId: 'same-rider',
        type: RideEventType.riderJoined,
        createdAt: joinedAt.add(const Duration(minutes: 2)),
        payload: const {'displayName': 'Alex', 'role': 'rider'},
        secret: secret,
      ),
    ];

    final participants = const RideMembershipReducer().fromEvents(
      rideId: 'ride-a',
      inviteSecret: secret,
      events: events.reversed,
      now: joinedAt.add(const Duration(minutes: 2, seconds: 30)),
      localRiderId: 'leader',
      localDisplayName: 'Lead',
      localRole: RideRole.lead,
      localJoinedAt: joinedAt,
      localMotorcycleStyle: motorcycleIconStyleDefault,
      localRiderColor: riderColorDefault,
      rideStartedAt: joinedAt,
    );

    expect(
      participants.where((participant) => participant.riderId == 'same-rider'),
      hasLength(1),
    );
    expect(
      participants
          .singleWhere((participant) => participant.riderId == 'same-rider')
          .state,
      RideMembershipState.joined,
    );
  });

  test('a forged departure cannot remove a participant', () {
    final joined = _event(
      id: 'join',
      deviceId: 'rider-a',
      type: RideEventType.riderJoined,
      createdAt: joinedAt,
      payload: const {'displayName': 'Alex', 'role': 'rider'},
      secret: secret,
    );
    final forged = RideEvent(
      id: 'forged-left',
      rideId: 'ride-a',
      deviceId: 'rider-a',
      type: RideEventType.riderLeft,
      priority: EventPriority.important,
      createdAt: joinedAt.add(const Duration(minutes: 1)),
      payload: const {'riderId': 'rider-a'},
      signature: '0' * 64,
    );

    final rider = const RideMembershipReducer()
        .fromEvents(
          rideId: 'ride-a',
          inviteSecret: secret,
          events: [joined, forged],
          now: joinedAt.add(const Duration(minutes: 1)),
          localRiderId: 'leader',
          localDisplayName: 'Lead',
          localRole: RideRole.lead,
          localJoinedAt: joinedAt,
          localMotorcycleStyle: motorcycleIconStyleDefault,
          localRiderColor: riderColorDefault,
        )
        .singleWhere((participant) => participant.riderId == 'rider-a');

    expect(rider.state, RideMembershipState.joined);
  });
}

RideEvent _event({
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
  required String secret,
}) {
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
