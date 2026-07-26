import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/tec_role_assignment.dart';

/// Issue #128 part 1. A leader can ask a named rider to be Tail End Charlie;
/// only the leader can ask, only the named rider can answer, and the leader can
/// tell "asked" from "covered".
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final start = DateTime.utc(2026, 7, 26, 9);
  const reducer = TecRoleAssignmentReducer();

  TecRoleAssignmentState reduce(
    List<RideEvent> events, {
    DateTime? now,
    TecRoleAssignmentReducer? using,
  }) => (using ?? reducer).fromEvents(
    rideId: 'ride-a',
    inviteSecret: secret,
    events: events,
    now: now ?? start.add(const Duration(minutes: 1)),
  );

  List<RideEvent> roster() => [
    _event(
      id: 'a-created',
      deviceId: 'leader',
      type: RideEventType.rideCreated,
      createdAt: start,
      payload: const {'displayName': 'Lead', 'role': 'lead'},
    ),
    _event(
      id: 'b-join-bill',
      deviceId: 'bill',
      type: RideEventType.riderJoined,
      createdAt: start.add(const Duration(seconds: 10)),
      payload: const {'displayName': 'Bill', 'role': 'rider'},
    ),
    _event(
      id: 'c-join-dave',
      deviceId: 'dave',
      type: RideEventType.riderJoined,
      createdAt: start.add(const Duration(seconds: 20)),
      payload: const {'displayName': 'Dave', 'role': 'rider'},
    ),
  ];

  RideEvent request({
    required String id,
    required String requestId,
    required String target,
    String leader = 'leader',
    String? claimedLeader,
    required Duration after,
  }) => _event(
    id: id,
    deviceId: leader,
    type: RideEventType.tecRoleRequested,
    createdAt: start.add(after),
    payload: TecRoleAssignmentReducer.requestPayload(
      requestId: requestId,
      leaderRiderId: claimedLeader ?? leader,
      targetRiderId: target,
      targetDisplayName: target == 'bill' ? 'Bill' : 'Dave',
    ),
  );

  RideEvent response({
    required String id,
    required String requestId,
    required String responder,
    required bool accepted,
    required Duration after,
  }) => _event(
    id: id,
    deviceId: responder,
    type: RideEventType.tecRoleResponded,
    createdAt: start.add(after),
    payload: TecRoleAssignmentReducer.responsePayload(
      requestId: requestId,
      targetRiderId: responder,
      accepted: accepted,
    ),
  );

  RideEvent roleChanged({
    required String id,
    required String deviceId,
    required RideRole role,
    required Duration after,
  }) => _event(
    id: id,
    deviceId: deviceId,
    type: RideEventType.roleChanged,
    createdAt: start.add(after),
    payload: {'role': role.name},
  );

  group('a leader-initiated request', () {
    test('is pending until the target answers, then accepted', () {
      final asked = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
      ];

      final pending = reduce(asked);
      expect(pending.latest?.status, TecRoleAssignmentStatus.pending);
      expect(pending.hasPendingRequest, isTrue);
      // Until Bill says yes the back is not covered, and the label says so.
      expect(pending.acceptedTecRiderId, isNull);
      expect(
        pending.latest?.statusLabel,
        contains('waiting for them to accept'),
      );
      expect(pending.pendingFor('bill')?.requestId, 'req-1');
      expect(pending.pendingFor('dave'), isNull);

      final accepted = reduce([
        ...asked,
        response(
          id: 'e-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 45),
        ),
      ]);
      expect(accepted.latest?.status, TecRoleAssignmentStatus.accepted);
      expect(accepted.acceptedTecRiderId, 'bill');
      expect(accepted.hasPendingRequest, isFalse);
      expect(accepted.pendingFor('bill'), isNull);
    });

    test('records a decline as a decline, not as silence', () {
      final declined = reduce([
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        response(
          id: 'e-decline',
          requestId: 'req-1',
          responder: 'bill',
          accepted: false,
          after: const Duration(seconds: 40),
        ),
      ]);

      expect(declined.latest?.status, TecRoleAssignmentStatus.declined);
      expect(declined.acceptedTecRiderId, isNull);
      expect(declined.latest?.statusLabel, 'Bill declined');
    });

    test('expires when nobody answers, rather than waiting for ever', () {
      final events = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
      ];

      expect(
        reduce(
          events,
          now: start.add(const Duration(minutes: 9)),
        ).latest?.status,
        TecRoleAssignmentStatus.pending,
      );
      final expired = reduce(
        events,
        now: start.add(const Duration(minutes: 11)),
      );
      expect(expired.latest?.status, TecRoleAssignmentStatus.expired);
      expect(expired.latest?.statusLabel, contains('never answered'));
      // An expired request must not raise the prompt again on the target.
      expect(expired.pendingFor('bill'), isNull);
    });
  });

  group('forged and replayed requests', () {
    test('a request from a rider who is not the leader is rejected', () {
      final forged = reduce([
        ...roster(),
        request(
          id: 'd-forged',
          requestId: 'req-forged',
          target: 'dave',
          leader: 'bill',
          after: const Duration(seconds: 30),
        ),
      ]);

      expect(forged.assignments, isEmpty);
      expect(forged.pendingFor('dave'), isNull);
    });

    test('a request naming somebody else as its author is rejected', () {
      final forged = reduce([
        ...roster(),
        // Bill's device, claiming the leader issued it.
        request(
          id: 'd-forged',
          requestId: 'req-forged',
          target: 'dave',
          leader: 'bill',
          claimedLeader: 'leader',
          after: const Duration(seconds: 30),
        ),
      ]);

      expect(forged.assignments, isEmpty);
    });

    test('a response from a device other than the target is rejected', () {
      final events = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        // Dave accepting on Bill's behalf.
        _event(
          id: 'e-forged-accept',
          deviceId: 'dave',
          type: RideEventType.tecRoleResponded,
          createdAt: start.add(const Duration(seconds: 40)),
          payload: TecRoleAssignmentReducer.responsePayload(
            requestId: 'req-1',
            targetRiderId: 'bill',
            accepted: true,
          ),
        ),
      ];

      final state = reduce(events);
      expect(state.latest?.status, TecRoleAssignmentStatus.pending);
      expect(state.acceptedTecRiderId, isNull);

      // And Bill's own later answer still counts: the forgery did not consume it.
      final answered = reduce([
        ...events,
        response(
          id: 'f-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 50),
        ),
      ]);
      expect(answered.acceptedTecRiderId, 'bill');
    });

    test('an unsigned request is rejected', () {
      final unsigned = RideEvent(
        id: 'd-unsigned',
        rideId: 'ride-a',
        deviceId: 'leader',
        type: RideEventType.tecRoleRequested,
        priority: EventPriority.important,
        createdAt: start.add(const Duration(seconds: 30)),
        payload: TecRoleAssignmentReducer.requestPayload(
          requestId: 'req-1',
          leaderRiderId: 'leader',
          targetRiderId: 'bill',
          targetDisplayName: 'Bill',
        ),
        signature: 'f' * 64,
      );

      expect(reduce([...roster(), unsigned]).assignments, isEmpty);
    });
  });

  group('convergence', () {
    test('duplicate and out-of-order delivery reach the same state', () {
      final inOrder = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        response(
          id: 'e-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 45),
        ),
      ];
      final shuffled = [
        inOrder[4],
        inOrder[2],
        inOrder[3],
        inOrder[0],
        inOrder[1],
        // Duplicates of both halves, as a replayed frame would deliver.
        inOrder[3],
        inOrder[4],
      ];

      final ordered = reduce(inOrder);
      final jumbled = reduce(shuffled);
      expect(jumbled.assignments, hasLength(ordered.assignments.length));
      expect(jumbled.acceptedTecRiderId, ordered.acceptedTecRiderId);
      expect(jumbled.latest?.status, ordered.latest?.status);
      expect(jumbled.latest?.respondedAt, ordered.latest?.respondedAt);
    });

    test('an answer timestamped before its own question still counts', () {
      // Two phones, two clocks. The answer must not be matched to the question
      // by its position in the journal.
      final state = reduce([
        ...roster(),
        request(
          id: 'e-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 40),
        ),
        response(
          id: 'd-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 30),
        ),
      ]);

      expect(state.acceptedTecRiderId, 'bill');
      expect(state.latest?.status, TecRoleAssignmentStatus.accepted);
    });

    test('a second request supersedes an unanswered first', () {
      final state = reduce([
        ...roster(),
        request(
          id: 'd-ask-bill',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        request(
          id: 'e-ask-dave',
          requestId: 'req-2',
          target: 'dave',
          after: const Duration(seconds: 40),
        ),
      ]);

      expect(
        state.assignments.first.status,
        TecRoleAssignmentStatus.superseded,
      );
      expect(state.latest?.targetRiderId, 'dave');
      expect(state.latest?.status, TecRoleAssignmentStatus.pending);
      // The superseded target must not still be prompted.
      expect(state.pendingFor('bill'), isNull);
      expect(state.pendingFor('dave'), isNotNull);
    });

    test('a rider who leaves while holding the role stops being the TEC', () {
      final state = reduce([
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        response(
          id: 'e-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 40),
        ),
        _event(
          id: 'f-left',
          deviceId: 'bill',
          type: RideEventType.riderLeft,
          createdAt: start.add(const Duration(minutes: 5)),
          payload: const {'riderId': 'bill', 'reason': 'left'},
        ),
      ], now: start.add(const Duration(minutes: 6)));

      expect(state.latest?.status, TecRoleAssignmentStatus.targetLeft);
      expect(state.acceptedTecRiderId, isNull);
      expect(state.latest?.statusLabel, contains('has left the ride'));
    });

    test('a request survives a later leader handover', () {
      // The leader asks Bill, then hands the lead to Dave. The request was
      // legitimate when issued, so it stays legitimate; only new requests are
      // judged against who is leader now.
      final state = reduce([
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        roleChanged(
          id: 'e-handover-away',
          deviceId: 'leader',
          role: RideRole.rider,
          after: const Duration(seconds: 40),
        ),
        roleChanged(
          id: 'f-handover-to',
          deviceId: 'dave',
          role: RideRole.lead,
          after: const Duration(seconds: 41),
        ),
        response(
          id: 'g-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 50),
        ),
      ]);

      expect(state.acceptedTecRiderId, 'bill');

      // And the former leader can no longer issue one.
      final afterHandover = reduce([
        ...roster(),
        roleChanged(
          id: 'd-handover-away',
          deviceId: 'leader',
          role: RideRole.rider,
          after: const Duration(seconds: 30),
        ),
        roleChanged(
          id: 'e-handover-to',
          deviceId: 'dave',
          role: RideRole.lead,
          after: const Duration(seconds: 31),
        ),
        request(
          id: 'f-stale-request',
          requestId: 'req-stale',
          target: 'bill',
          after: const Duration(seconds: 40),
        ),
      ]);
      expect(afterHandover.assignments, isEmpty);
    });
  });

  group('the four TecAvailability states through an assignment', () {
    const calculator = LeaderRideStatusCalculator();
    final askedAndAccepted = [
      ...roster(),
      request(
        id: 'd-request',
        requestId: 'req-1',
        target: 'bill',
        after: const Duration(seconds: 30),
      ),
      response(
        id: 'e-accept',
        requestId: 'req-1',
        responder: 'bill',
        accepted: true,
        after: const Duration(seconds: 40),
      ),
      roleChanged(
        id: 'f-role',
        deviceId: 'bill',
        role: RideRole.tailEndCharlie,
        after: const Duration(seconds: 41),
      ),
    ];

    RiderLocation billAt(DateTime recordedAt) => RiderLocation(
      riderId: 'bill',
      displayName: 'Bill',
      role: RideRole.tailEndCharlie,
      sample: LocationSample(
        position: const GeoPoint(latitude: 51.5, longitude: -0.1),
        recordedAt: recordedAt,
        accuracyMeters: 5,
      ),
      receivedAt: recordedAt,
    );

    test('none before the request, then awaitingLocation once accepted', () {
      final now = start.add(const Duration(minutes: 1));
      expect(
        calculator
            .resolveTecTarget(
              localRiderId: 'leader',
              riderLocations: const [],
              now: now,
            )
            .availability,
        TecAvailability.none,
      );

      final assignment = reduce(askedAndAccepted, now: now);
      final awaiting = calculator.resolveTecTarget(
        localRiderId: 'leader',
        riderLocations: const [],
        // Membership supplies the registered id; the assignment supplies the
        // tie-break. Neither invents a position.
        registeredTecRiderIds: const ['bill'],
        assignedTecRiderId: assignment.acceptedTecRiderId,
        now: now,
      );
      expect(awaiting.availability, TecAvailability.awaitingLocation);
      expect(awaiting.riderId, 'bill');
      expect(awaiting.navigableLocation, isNull);
    });

    test('tracking with a fresh fix, stale once it ages out', () {
      final now = start.add(const Duration(minutes: 2));
      final assignment = reduce(askedAndAccepted, now: now);

      final tracking = calculator.resolveTecTarget(
        localRiderId: 'leader',
        riderLocations: [billAt(now.subtract(const Duration(seconds: 20)))],
        registeredTecRiderIds: const ['bill'],
        assignedTecRiderId: assignment.acceptedTecRiderId,
        now: now,
      );
      expect(tracking.availability, TecAvailability.tracking);
      expect(tracking.navigableLocation, isNotNull);

      final stale = calculator.resolveTecTarget(
        localRiderId: 'leader',
        riderLocations: [billAt(now.subtract(const Duration(minutes: 5)))],
        registeredTecRiderIds: const ['bill'],
        assignedTecRiderId: assignment.acceptedTecRiderId,
        now: now,
      );
      expect(stale.availability, TecAvailability.stale);
      // A stale fix is still withheld from anything that would navigate to it.
      expect(stale.navigableLocation, isNull);
    });

    test('two riders holding the role resolve to the accepted one', () {
      final now = start.add(const Duration(minutes: 2));
      final assignment = reduce(askedAndAccepted, now: now);
      final selfSelected = RiderLocation(
        riderId: 'dave',
        displayName: 'Dave',
        role: RideRole.tailEndCharlie,
        sample: LocationSample(
          position: const GeoPoint(latitude: 51.4, longitude: -0.2),
          // Fresher than Bill's, so without the tie-break Dave would win.
          recordedAt: now,
          accuracyMeters: 5,
        ),
        receivedAt: now,
      );

      final withoutAssignment = calculator.resolveTecTarget(
        localRiderId: 'leader',
        riderLocations: [
          billAt(now.subtract(const Duration(seconds: 30))),
          selfSelected,
        ],
        now: now,
      );
      expect(withoutAssignment.riderId, 'dave');

      final resolved = calculator.resolveTecTarget(
        localRiderId: 'leader',
        riderLocations: [
          billAt(now.subtract(const Duration(seconds: 30))),
          selfSelected,
        ],
        registeredTecRiderIds: const ['bill', 'dave'],
        assignedTecRiderId: assignment.acceptedTecRiderId,
        now: now,
      );
      expect(resolved.riderId, 'bill');
      expect(resolved.availability, TecAvailability.tracking);
    });

    test('an assignment never invents a TEC who is not registered', () {
      final now = start.add(const Duration(minutes: 2));
      final resolved = calculator.resolveTecTarget(
        localRiderId: 'leader',
        riderLocations: const [],
        assignedTecRiderId: 'bill',
        now: now,
      );

      expect(resolved.availability, TecAvailability.none);
      expect(resolved.riderId, isNull);
    });
  });
}

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
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: id,
    rideId: 'ride-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: RideEventAuthenticator.sign(unsigned, secret),
  );
}
