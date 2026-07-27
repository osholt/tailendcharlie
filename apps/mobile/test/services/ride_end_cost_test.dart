// Guards the end-of-ride cost that made the app unresponsive on a real ride
// (#165).
//
// These assertions count work rather than measure time. The bug was quadratic —
// every appended event re-authenticated the whole journal — and a count catches
// that exactly, on any machine, where a millisecond threshold on shared CI
// would either flake or be set so loose it proves nothing.
//
// The measured numbers behind the thresholds, from a physical iPhone in profile
// mode at 40,000 events (a two-hour ride for a group of four):
//
//   _rebuildLifecycle   2,992 ms -> 20 ms   (it runs on every appended event)
//   markingSummary      1,595 ms -> 45 ms   (the dashboard reads it in build)
//   clearEndedRide      3,133 ms -> 42 ms
//
// The full profile harness is integration_test/ride_end_profile_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/ride_lifecycle.dart';
import 'package:ride_relay/services/ride_route_reducer.dart';
import 'package:ride_relay/services/ride_summary_exporter.dart';
import 'package:ride_relay/services/trail_display_simplifier.dart';
import 'package:ride_relay/domain/imported_route.dart' as route_domain;

void main() {
  final session = RideSession(
    rideId: 'ride-cost',
    rideCode: '123456',
    inviteSecret: 'cost-secret',
    joinToken: 'cost-token',
    localRiderId: 'rider-0',
    displayName: 'Oliver',
    role: RideRole.lead,
    joinedAt: DateTime.utc(2026, 7, 27, 9),
  );

  setUp(() => RideEventAuthenticator.verificationsComputed = 0);

  group('journal authentication', () {
    test('authenticates each event once however often it is walked', () {
      final events = _journal(session, locationEvents: 400);
      for (var pass = 0; pass < 10; pass += 1) {
        RideLifecycleReducer.fromEvents(
          rideId: session.rideId,
          inviteSecret: session.inviteSecret,
          events: events,
        );
        const RideRouteReducer().fromEvents(
          rideId: session.rideId,
          inviteSecret: session.inviteSecret,
          events: events,
        );
      }

      // Twenty walks of the journal, one authentication per event. Before the
      // fix this was events.length * 20.
      expect(RideEventAuthenticator.verificationsComputed, events.length);
    });

    test('appending an event authenticates only what is new', () {
      final events = _journal(session, locationEvents: 400);
      RideLifecycleReducer.fromEvents(
        rideId: session.rideId,
        inviteSecret: session.inviteSecret,
        events: events,
      );
      RideEventAuthenticator.verificationsComputed = 0;

      // What _record() does: append, then rebuild over the whole journal.
      final appended = [
        ...events,
        _locationEvent(session, rider: 0, index: 400),
      ];
      RideLifecycleReducer.fromEvents(
        rideId: session.rideId,
        inviteSecret: session.inviteSecret,
        events: appended,
      );

      // The cost of a position fix late in a ride must be the cost of that fix,
      // not of the ride so far. This is the quadratic term, and it is what made
      // the phone unusable by the end of a two-hour ride.
      expect(RideEventAuthenticator.verificationsComputed, 1);
    });

    test('a forged event never inherits a verdict', () {
      final authentic = _locationEvent(session, rider: 0, index: 1);
      expect(
        RideEventAuthenticator.verify(authentic, session.inviteSecret),
        isTrue,
      );

      // Same id and same signature, different payload: a different object, so
      // the identity-keyed memo cannot answer for it.
      final forged = RideEvent(
        id: authentic.id,
        rideId: authentic.rideId,
        deviceId: authentic.deviceId,
        type: authentic.type,
        priority: authentic.priority,
        createdAt: authentic.createdAt,
        expiresAt: authentic.expiresAt,
        payload: const {'location': 'tampered'},
        signature: authentic.signature,
      );

      expect(
        RideEventAuthenticator.verify(forged, session.inviteSecret),
        isFalse,
      );
    });

    test('the same event under a different secret is re-authenticated', () {
      final event = _locationEvent(session, rider: 0, index: 1);
      expect(
        RideEventAuthenticator.verify(event, session.inviteSecret),
        isTrue,
      );
      expect(RideEventAuthenticator.verify(event, 'a-different-ride'), isFalse);
      expect(
        RideEventAuthenticator.verify(event, session.inviteSecret),
        isTrue,
      );
    });
  });

  group('ride end', () {
    test('archiving a ride walks the journal without re-authenticating it', () {
      final events = _journal(session, locationEvents: 400);
      const exporter = RideSummaryExporter();
      final generatedAt = DateTime.utc(2026, 7, 27, 11);
      exporter.summarize(session, events, generatedAt: generatedAt);
      RideEventAuthenticator.verificationsComputed = 0;

      // What clearEndedRide() reaches: a summary and the travelled route, each
      // of which runs a lifecycle reduction of its own.
      exporter.summarize(session, events, generatedAt: generatedAt);
      exporter.traveledRoute(session, events, generatedAt: generatedAt);

      expect(RideEventAuthenticator.verificationsComputed, 0);
    });
  });

  group('trail display bound', () {
    test('a ride-length trail is bounded, and endpoints are kept', () {
      final points = [
        for (var index = 0; index < 12000; index += 1)
          route_domain.GeoPoint(
            latitude: 51.46 + index * 0.00006,
            longitude: -2.5 + index * 0.00009,
          ),
      ];

      final simplified = const TrailDisplaySimplifier().simplify(points);

      expect(
        simplified.length,
        lessThanOrEqualTo(TrailDisplaySimplifier.defaultMaximumPoints),
      );
      expect(simplified.first, points.first);
      expect(simplified.last, points.last);
      // A straight run collapses to almost nothing: the cost of drawing a trail
      // must not track how long the rider has been riding.
      expect(simplified.length, lessThan(50));
    });

    test('a hairpin keeps its shape', () {
      // ~30 m limbs, the tightest case #166 raises. Simplifying must not turn
      // this into a straight line through the apex.
      const metre = 1 / 111132.0;
      final points = <route_domain.GeoPoint>[
        for (var index = 0; index < 15; index += 1)
          route_domain.GeoPoint(
            latitude: 51.46 + index * 2 * metre,
            longitude: -2.5,
          ),
        for (var index = 0; index < 15; index += 1)
          route_domain.GeoPoint(
            latitude: 51.46 + 30 * metre - index * 2 * metre,
            longitude: -2.5 + 30 * metre,
          ),
      ];

      final simplified = const TrailDisplaySimplifier().simplify(points);

      // The apex and the return leg both survive: a straight-line reduction
      // would leave two or three points.
      expect(simplified.length, greaterThanOrEqualTo(4));
      final apex = simplified
          .map((point) => point.latitude)
          .reduce((left, right) => left > right ? left : right);
      expect(apex, closeTo(51.46 + 30 * metre, 3 * metre));
    });

    test('a trail too short to simplify is returned untouched', () {
      final points = [
        const route_domain.GeoPoint(latitude: 51.46, longitude: -2.5),
        const route_domain.GeoPoint(latitude: 51.47, longitude: -2.5),
      ];

      expect(const TrailDisplaySimplifier().simplify(points), same(points));
    });
  });
}

List<RideEvent> _journal(RideSession session, {required int locationEvents}) =>
    [
      _signed(
        session,
        id: 'created',
        deviceId: session.localRiderId,
        type: RideEventType.rideCreated,
        createdAt: session.joinedAt,
        payload: {'role': RideRole.lead.name, 'displayName': 'Oliver'},
      ),
      _signed(
        session,
        id: 'started',
        deviceId: session.localRiderId,
        type: RideEventType.rideStarted,
        createdAt: session.joinedAt.add(const Duration(minutes: 10)),
        payload: {'leaderRiderId': session.localRiderId},
      ),
      for (var index = 0; index < locationEvents; index += 1)
        _locationEvent(session, rider: index % 4, index: index),
      _signed(
        session,
        id: 'ended',
        deviceId: session.localRiderId,
        type: RideEventType.rideEnded,
        createdAt: session.joinedAt.add(const Duration(hours: 2)),
        payload: const {},
      ),
    ];

RideEvent _locationEvent(
  RideSession session, {
  required int rider,
  required int index,
}) {
  final recordedAt = session.joinedAt.add(
    Duration(minutes: 10, milliseconds: 720 * index),
  );
  return _signed(
    session,
    id: 'loc-$rider-$index',
    deviceId: 'rider-$rider',
    type: RideEventType.riderLocationUpdated,
    createdAt: recordedAt,
    payload: {
      'location': RiderLocation(
        riderId: 'rider-$rider',
        displayName: rider == 0 ? 'Oliver' : 'Rider $rider',
        role: rider == 0 ? RideRole.lead : RideRole.rider,
        sample: LocationSample(
          position: GeoPoint(
            latitude: 51.46 + index * 0.00006,
            longitude: -2.5 + index * 0.00009,
          ),
          recordedAt: recordedAt,
          accuracyMeters: 5,
        ),
        receivedAt: recordedAt,
      ).toJson(),
    },
  );
}

RideEvent _signed(
  RideSession session, {
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: session.rideId,
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
    signature: RideEventAuthenticator.sign(unsigned, session.inviteSecret),
  );
}
