// Profiles the end-of-ride flow (#165) on a physical phone, at the scale a
// real ride reaches.
//
// Run in release mode so the numbers are the ones a rider gets:
//
//   flutter test integration_test/ride_end_profile_test.dart \
//     -d <device-id> --release
//
// This is a measurement harness, not an assertion test - it prints a table and
// only fails if the harness itself breaks. The regression test that guards the
// fix lives in test/services/ride_end_cost_test.dart and runs on the host.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/geo_point.dart' as sample_geo;
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/ride/ride_recap_card.dart';
import 'package:ride_relay/services/completed_ride_archiver.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/ride_lifecycle.dart';
import 'package:ride_relay/services/ride_route_reducer.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_summary_exporter.dart';

/// A two-hour ride at `geolocator`'s configured `distanceFilter: 10` and an
/// average 50 km/h is ~10,000 fixes for the local rider alone; every other
/// rider's fixes arrive as journal events too. 4 riders is a small group.
const _ridersInGroup = 4;
const _scales = <int>[500, 2000, 8000, 40000];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final session = RideSession(
    rideId: 'ride-profile',
    rideCode: '123456',
    inviteSecret: 'profile-secret',
    joinToken: 'profile-token',
    localRiderId: 'rider-0',
    displayName: 'Oliver',
    role: RideRole.lead,
    joinedAt: DateTime.utc(2026, 7, 27, 9),
  );

  testWidgets(
    'journal-walk cost by ride length',
    (tester) async {
      final rows = <String>[];
      for (final scale in _scales) {
        final events = _journal(session, locationEvents: scale);
        final lifecycle = _time(
          () => RideLifecycleReducer.fromEvents(
            rideId: session.rideId,
            inviteSecret: session.inviteSecret,
            events: events,
          ),
        );
        final route = _time(
          () => const RideRouteReducer().fromEvents(
            rideId: session.rideId,
            inviteSecret: session.inviteSecret,
            events: events,
          ),
        );
        // The first walk of a journal also pays to verify every signature in
        // it. What matters for responsiveness is the second and every walk
        // after: that is what _rebuildLifecycle() costs on each appended
        // event, and what a rebuild costs on rotation.
        final coldRebuild = lifecycle + route;
        final rebuild =
            _time(
              () => RideLifecycleReducer.fromEvents(
                rideId: session.rideId,
                inviteSecret: session.inviteSecret,
                events: events,
              ),
            ) +
            _time(
              () => const RideRouteReducer().fromEvents(
                rideId: session.rideId,
                inviteSecret: session.inviteSecret,
                events: events,
              ),
            );
        const exporter = RideSummaryExporter();
        final summarize = _time(
          () => exporter.summarize(
            session,
            events,
            generatedAt: DateTime.utc(2026, 7, 27, 11),
          ),
        );
        final archive = _time(
          () => const CompletedRideArchiver().create(
            session: session,
            events: events,
            archivedAt: DateTime.utc(2026, 7, 27, 11),
          ),
        );
        final snapshot = const CompletedRideArchiver().create(
          session: session,
          events: events,
          archivedAt: DateTime.utc(2026, 7, 27, 11),
        );
        final encode = _time(() => jsonEncode(snapshot.toJson()));
        rows.add(
          '${_pad(scale)}  coldRebuild=${_ms(coldRebuild)}  '
          'warmRebuild=${_ms(rebuild)}  summarize=${_ms(summarize)}  '
          'archive=${_ms(archive)}  jsonEncode=${_ms(encode)}',
        );
        debugPrint('PROFILE #165 ${rows.last}');
      }
      debugPrint('PROFILE #165 ==== journal walks (events, ms) ====');
      for (final row in rows) {
        debugPrint('PROFILE #165 $row');
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  // The path the device actually takes: a live controller holding a
  // ride-length journal, doing what it does on every menu build and on every
  // appended event.
  testWidgets(
    'live controller cost at ride length',
    (tester) async {
      for (final scale in <int>[500, 8000, 40000]) {
        final eventStore = InMemoryEventStore();
        for (final event in _journal(session, locationEvents: scale)) {
          await eventStore.append(event);
        }
        final sessionStore = InMemorySessionStore();
        await sessionStore.save(session);
        final controller = RideController(
          eventStore,
          sessionStore,
          NearbyBridge(),
          clock: () => DateTime.utc(2026, 7, 27, 11, 30),
          idFactory: () => 'profile-id-${_sequence++}',
          completedRideStore: InMemoryCompletedRideStore(),
        );
        final initialize = await _timeAsync(controller.initialize);
        // What the dashboard and its menus read during build, twice - a
        // rebuild pays it again.
        final marking = _time(() => controller.markingSummary);
        final markingAgain = _time(() => controller.markingSummary);
        final clear = await _timeAsync(controller.clearEndedRide);
        debugPrint(
          'PROFILE #165 ${_pad(scale)}  initialize=${_ms(initialize)}  '
          'markingSummary=${_ms(marking)} (again=${_ms(markingAgain)})  '
          'clearEndedRide=${_ms(clear)}',
        );
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  testWidgets(
    'recap card paint and 3x rasterise',
    (tester) async {
      for (final scale in <int>[500, 8000, 40000]) {
        final events = _journal(session, locationEvents: scale);
        const exporter = RideSummaryExporter();
        final generatedAt = DateTime.utc(2026, 7, 27, 11);
        // What _openRecap() does before the screen even appears.
        final prepare = _time(() {
          exporter.summarize(session, events, generatedAt: generatedAt);
          exporter.traveledRoute(session, events, generatedAt: generatedAt);
        });
        final summary = exporter.summarize(
          session,
          events,
          generatedAt: generatedAt,
        );
        final points =
            exporter
                .traveledRoute(session, events, generatedAt: generatedAt)
                ?.paths
                .single
                .points ??
            const <GeoPoint>[];
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: RideRecapCard(
                  summary: summary,
                  routePoints: points,
                  distanceUnit: DistanceUnit.kilometres,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final stopwatch = Stopwatch()..start();
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        stopwatch.stop();
        debugPrint(
          'PROFILE #165 ${_pad(scale)}  recapPrepare=${_ms(prepare)}  '
          'points=${points.length}  toImage+png=${_ms(stopwatch.elapsedMicroseconds)}'
          '  bytes=${bytes!.lengthInBytes}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

var _sequence = 0;

Future<int> _timeAsync(Future<void> Function() body) async {
  final stopwatch = Stopwatch()..start();
  await body();
  stopwatch.stop();
  return stopwatch.elapsedMicroseconds;
}

int _time(void Function() body) {
  final stopwatch = Stopwatch()..start();
  body();
  stopwatch.stop();
  return stopwatch.elapsedMicroseconds;
}

String _ms(int microseconds) => '${(microseconds / 1000).toStringAsFixed(1)}ms';

String _pad(int value) => value.toString().padLeft(6);

/// A signed journal shaped like a real ride: lifecycle events, then position
/// fixes from every rider in the group along a plausible track.
List<RideEvent> _journal(RideSession session, {required int locationEvents}) {
  final events = <RideEvent>[
    _signed(
      session,
      id: 'created',
      deviceId: session.localRiderId,
      type: RideEventType.rideCreated,
      createdAt: session.joinedAt,
      payload: {'role': RideRole.lead.name, 'displayName': 'Oliver'},
    ),
    for (var rider = 1; rider < _ridersInGroup; rider += 1)
      _signed(
        session,
        id: 'joined-$rider',
        deviceId: 'rider-$rider',
        type: RideEventType.riderJoined,
        createdAt: session.joinedAt.add(Duration(minutes: rider)),
        payload: {'role': RideRole.rider.name, 'displayName': 'Rider $rider'},
      ),
    _signed(
      session,
      id: 'started',
      deviceId: session.localRiderId,
      type: RideEventType.rideStarted,
      createdAt: session.joinedAt.add(const Duration(minutes: 10)),
      payload: {'leaderRiderId': session.localRiderId},
    ),
  ];
  final startedAt = session.joinedAt.add(const Duration(minutes: 10));
  final perRider = math.max(1, locationEvents ~/ _ridersInGroup);
  for (var rider = 0; rider < _ridersInGroup; rider += 1) {
    for (var index = 0; index < perRider; index += 1) {
      // ~10 m apart, the configured distanceFilter, tracking north-east.
      final latitude = 51.4600 + index * 0.00006 + rider * 0.0001;
      final longitude = -2.5000 + index * 0.00009;
      final recordedAt = startedAt.add(Duration(milliseconds: 720 * index));
      events.add(
        _signed(
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
                position: sample_geo.GeoPoint(
                  latitude: latitude,
                  longitude: longitude,
                ),
                recordedAt: recordedAt,
                accuracyMeters: 5,
                speedMetersPerSecond: 13.8,
                headingDegrees: 45,
              ),
              receivedAt: recordedAt,
            ).toJson(),
          },
        ),
      );
    }
  }
  events.add(
    _signed(
      session,
      id: 'ended',
      deviceId: session.localRiderId,
      type: RideEventType.rideEnded,
      createdAt: startedAt.add(const Duration(hours: 2)),
      payload: const {},
    ),
  );
  return events;
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
