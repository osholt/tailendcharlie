import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/marker_assistance_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/ride/marker_assistance_widgets.dart';
import 'package:ride_relay/services/marker_suggestion_detector.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/situation_event_factory.dart';

void main() {
  test(
    'authenticated approach counts one TEC passage for current session',
    () async {
      final fixture = await _Fixture.create();
      await fixture.awareness.recordLocalLocation(
        fixture.sample(longitude: -1, speed: 0),
      );
      await fixture.ride.startMarker();
      final assistance = MarkerAssistanceController(
        fixture.ride,
        fixture.awareness,
        route: _Fixture.route,
        decisionPoints: const [],
        clock: () => fixture.now,
      );
      await assistance.evaluateNow();

      await fixture.ingestRemoteLocation(
        riderId: 'tec',
        role: RideRole.tailEndCharlie,
        longitude: -1.001,
        speed: 5,
        eventId: 'far',
      );
      await assistance.evaluateNow();
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await fixture.ingestRemoteLocation(
        riderId: 'tec',
        role: RideRole.tailEndCharlie,
        longitude: -1.0001,
        speed: 5,
        eventId: 'near',
      );
      await assistance.evaluateNow();

      expect(fixture.ride.verifiedMarkerPassCount, 1);
      expect(fixture.ride.markerPassCount, 1);
      expect(fixture.ride.tecPassedCurrentMarker, isTrue);
      final pass = fixture.ride.events.singleWhere(
        (event) => event.type == RideEventType.markerPass,
      );
      expect(pass.payload['evidenceEventId'], 'near');
      expect(pass.payload['authenticated'], isTrue);
      expect(pass.payload['role'], RideRole.tailEndCharlie.name);

      await fixture.ingestRemoteLocation(
        riderId: 'tec',
        role: RideRole.tailEndCharlie,
        longitude: -1.0001,
        speed: 5,
        eventId: 'near-again',
      );
      await assistance.evaluateNow();
      expect(fixture.ride.markerPassCount, 1);

      assistance.dispose();
      fixture.dispose();
    },
  );

  testWidgets('suggestion requires review and explicit start confirmation', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await fixture.awareness.recordLocalLocation(
      fixture.sample(longitude: -0.999, speed: 0),
    );
    await fixture.ingestRemoteLocation(
      riderId: 'rider-a',
      role: RideRole.rider,
      longitude: -0.996,
      speed: 5,
      eventId: 'ahead',
    );
    final assistance = MarkerAssistanceController(
      fixture.ride,
      fixture.awareness,
      route: _Fixture.route,
      decisionPoints: const [
        RouteDecisionPoint(
          id: 'junction',
          position: GeoPoint(latitude: 51, longitude: -0.999),
          source: DecisionPointSource.waypoint,
        ),
      ],
      clock: () => fixture.now,
      suggestionConfig: const MarkerSuggestionConfig(
        stoppedDwell: Duration.zero,
      ),
    );
    await assistance.evaluateNow();
    expect(assistance.hasSuggestion, isTrue);
    expect(fixture.ride.markerActive, isFalse);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: AnimatedBuilder(
            animation: assistance,
            builder: (_, _) => MarkerAssistancePrompt(controller: assistance),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('marker-assistance-prompt')), findsOneWidget);

    await tester.tap(find.byKey(const Key('review-marker-suggestion')));
    await tester.pumpAndSettle();
    expect(find.text('Start marker mode?'), findsOneWidget);
    expect(fixture.ride.markerActive, isFalse);

    await tester.tap(find.byKey(const Key('confirm-assisted-marker')));
    await tester.pumpAndSettle();
    expect(fixture.ride.markerActive, isTrue);
    final started = fixture.ride.events.singleWhere(
      (event) => event.type == RideEventType.markerStarted,
    );
    expect(started.payload['mode'], 'assisted-confirmed');
    expect(started.payload['decisionPointId'], 'junction');

    assistance.dispose();
    fixture.dispose();
  });
}

class _Fixture {
  _Fixture(this.ride, this.awareness, this._clock);

  static const route = [
    GeoPoint(latitude: 51, longitude: -1),
    GeoPoint(latitude: 51, longitude: -0.99),
  ];

  final RideController ride;
  final SituationalAwarenessController awareness;
  final _TestClock _clock;

  DateTime get now => _clock.now;
  set now(DateTime value) => _clock.now = value;

  static Future<_Fixture> create() async {
    final clock = _TestClock(DateTime.utc(2026, 7, 16, 12));
    var id = 0;
    final store = InMemoryEventStore();
    final ride = RideController(
      store,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: clock.call,
      idFactory: () => 'ride-id-${id++}',
      random: Random(42),
    );
    await ride.initialize();
    await ride.createRide('Oliver');
    final awareness = SituationalAwarenessController(
      store,
      ride.session!,
      route: route,
      clock: clock.call,
      idFactory: () => 'awareness-id-${id++}',
    );
    await awareness.initialize();
    return _Fixture(ride, awareness, clock);
  }

  LocationSample sample({required double longitude, required double speed}) =>
      LocationSample(
        position: GeoPoint(latitude: 51, longitude: longitude),
        recordedAt: now,
        accuracyMeters: 4,
        speedMetersPerSecond: speed,
      );

  Future<void> ingestRemoteLocation({
    required String riderId,
    required RideRole role,
    required double longitude,
    required double speed,
    required String eventId,
  }) async {
    final localSession = ride.session!;
    final remoteSession = RideSession(
      rideId: localSession.rideId,
      rideCode: localSession.rideCode,
      inviteSecret: localSession.inviteSecret,
      joinToken: 'test-join-token-0123456789',
      localRiderId: riderId,
      displayName: riderId,
      role: role,
      joinedAt: now,
    );
    final event =
        SituationEventFactory(
          session: remoteSession,
          clock: () => now,
          idFactory: () => eventId,
        ).create(
          type: RideEventType.riderLocationUpdated,
          payload: {
            'location': RiderLocation(
              riderId: riderId,
              displayName: riderId,
              role: role,
              sample: sample(longitude: longitude, speed: speed),
              receivedAt: now,
            ).toJson(),
          },
        );
    await awareness.ingestRemoteEvent(event);
  }

  void dispose() {
    awareness.dispose();
    ride.dispose();
  }
}

class _TestClock {
  _TestClock(this.now);

  DateTime now;

  DateTime call() => now;
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async => const NearbyCapabilities(
    platform: 'test',
    nativeBridgeReady: true,
    nearbyApiLinked: false,
    status: 'phase0',
  );
}
