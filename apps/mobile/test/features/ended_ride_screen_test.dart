// Ties the end-of-ride copy to automatic Ride Library persistence (#542).

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness;
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/ended_ride_screen.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/situation_event_factory.dart';

void main() {
  late InMemoryEventStore events;
  late InMemorySessionStore sessions;
  late InMemoryCompletedRideStore archive;
  late RideController controller;

  setUp(() async {
    events = InMemoryEventStore();
    sessions = InMemorySessionStore();
    archive = InMemoryCompletedRideStore();
    var id = 0;
    controller = RideController(
      events,
      sessions,
      NearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 27, 12),
      idFactory: () => 'id-${id++}',
      random: Random(7),
      rideCodeDirectory: _OfflineRideCodeDirectory(),
      completedRideStore: archive,
    );
    await controller.initialize();
    await controller.createRide('Oliver');
    await controller.startRide();
    await controller.endRide();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpScreen(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: EndedRideScreen(
        controller: controller,
        distanceUnits: DistanceUnitController.forLocale(
          const Locale('en', 'GB'),
        ),
      ),
    ),
  );

  testWidgets('no copy claims the ride leaves the phone', (tester) async {
    await pumpScreen(tester);

    final forbidden = RegExp(
      r'remove|delete|erase|wipe|lose|permanent',
      caseSensitive: false,
    );
    final offending = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .where(forbidden.hasMatch)
        .toList();

    expect(
      offending,
      isEmpty,
      reason: 'the ride is archived, so nothing may describe it as destroyed',
    );
    expect(
      find.textContaining('already saved in Previous rides'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('file-ended-ride-button')), findsNothing);
  });

  // #206/#207: the tester was stranded here by an automatic end she did not
  // ask for, so the screen has to offer the way back into the ride.
  testWidgets('the leader can resume a ride that ended', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('reopen-ended-ride-button')));
    await tester.pumpAndSettle();
    expect(find.text('Resume this ride?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-reopen-ride-button')));
    await tester.pumpAndSettle();
    expect(controller.rideEnded, isTrue);

    await tester.tap(find.byKey(const Key('reopen-ended-ride-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reopen-ride-button')));
    await tester.pumpAndSettle();

    expect(controller.rideEnded, isFalse);
  });

  testWidgets('a relay that cannot carry a resume does not offer one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EndedRideScreen(
          controller: controller,
          distanceUnits: DistanceUnitController.forLocale(
            const Locale('en', 'GB'),
          ),
          relayCanCarryReopen: false,
        ),
      ),
    );

    expect(find.byKey(const Key('reopen-ended-ride-button')), findsNothing);
    // The way out is still there; only the resume is withheld.
    expect(find.byKey(const Key('leave-ended-ride-button')), findsOneWidget);
  });

  // #207: this screen replaces the whole app, so without an exit of its own the
  // only way off it was to file the ride and stop relay recovery.
  testWidgets('offers two exits that give nothing up', (tester) async {
    await pumpScreen(tester);

    for (final exit in [
      const Key('leave-ended-ride-button'),
      const Key('leave-ended-ride-screen-button'),
    ]) {
      controller.reopenEndedRide();
      expect(controller.endedRideSetAside, isFalse);

      await tester.tap(find.byKey(exit));
      await tester.pump();

      expect(controller.endedRideSetAside, isTrue, reason: '$exit');
      expect(controller.hasActiveRide, isTrue);
      expect(controller.rideEnded, isTrue);
    }
  });

  // #849: the group's alerts, listed where a rider lands when the ride is over,
  // each with the time to the second so it can be found in dash-cam footage.
  group('alerts raised during the ride', () {
    RideEvent alert(
      String id, {
      required String riderId,
      required String name,
      required DateTime at,
    }) {
      final session = controller.session!;
      final hazard = HazardReport(
        id: id,
        rideId: session.rideId,
        type: HazardType.alert,
        severity: HazardSeverity.serious,
        position: const awareness.GeoPoint(latitude: 54.15, longitude: -4.48),
        reportedAt: at,
        updatedAt: at,
        expiresAt: at.add(const Duration(hours: 1)),
        reporterId: riderId,
        reporterName: name,
        source: HazardSource.rider,
      );
      return SituationEventFactory(
        session: session,
        clock: () => at,
        idFactory: () => 'event-$id',
      ).create(
        type: RideEventType.hazardReported,
        payload: {'hazard': hazard.toJson()},
        priority: EventPriority.important,
        expiresAt: hazard.expiresAt,
      );
    }

    testWidgets('are listed with their times, who raised them and where', (
      tester,
    ) async {
      controller.ingestStoredEvent(
        alert(
          'a1',
          riderId: 'nigel',
          name: 'Nigel',
          at: DateTime(2026, 7, 27, 12, 30, 5),
        ),
      );
      controller.ingestStoredEvent(
        alert(
          'a2',
          riderId: controller.session!.localRiderId,
          name: 'Oliver',
          at: DateTime(2026, 7, 27, 12, 41, 9),
        ),
      );
      await pumpScreen(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('ride-alerts-card')),
        300,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('2 alerts'), findsOneWidget);
      expect(find.text('12:30:05'), findsOneWidget);
      expect(find.text('12:41:09'), findsOneWidget);
      expect(find.text('Nigel · 54.15000, -4.48000'), findsOneWidget);
      expect(find.text('Oliver (you) · 54.15000, -4.48000'), findsOneWidget);
    });

    testWidgets('are not listed when the ride raised none', (tester) async {
      await pumpScreen(tester);

      expect(find.byKey(const Key('ride-alerts-card')), findsNothing);
    });

    test('are archived with the ride, for the previous rides screen', () async {
      // Its own controller: the shared one has already ended, and an alert is
      // raised during a ride, not after it.
      final liveArchive = InMemoryCompletedRideStore();
      var id = 0;
      final live = RideController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        NearbyBridge(),
        clock: () => DateTime.utc(2026, 7, 27, 12),
        idFactory: () => 'live-${id++}',
        random: Random(7),
        rideCodeDirectory: _OfflineRideCodeDirectory(),
        completedRideStore: liveArchive,
      );
      addTearDown(live.dispose);
      await live.initialize();
      await live.createRide('Oliver');
      await live.startRide();
      final session = live.session!;
      final at = DateTime(2026, 7, 27, 12, 30, 5);
      final hazard = HazardReport(
        id: 'a1',
        rideId: session.rideId,
        type: HazardType.alert,
        severity: HazardSeverity.serious,
        position: const awareness.GeoPoint(latitude: 54.15, longitude: -4.48),
        reportedAt: at,
        updatedAt: at,
        expiresAt: at.add(const Duration(hours: 1)),
        reporterId: 'nigel',
        reporterName: 'Nigel',
        source: HazardSource.rider,
      );
      live.ingestStoredEvent(
        SituationEventFactory(
          session: session,
          clock: () => at,
          idFactory: () => 'event-a1',
        ).create(
          type: RideEventType.hazardReported,
          payload: {'hazard': hazard.toJson()},
          priority: EventPriority.important,
          expiresAt: hazard.expiresAt,
        ),
      );

      await live.endRide();

      final saved = (await liveArchive.list()).single;
      expect(saved.alerts.map((record) => record.raisedBy), ['Nigel']);
      expect(saved.alerts.single.raisedAt.isAtSameMomentAs(at), isTrue);
    });
  });

  testWidgets('ending automatically archives the ride without a save prompt', (
    tester,
  ) async {
    final rideId = controller.session!.rideId;
    await pumpScreen(tester);

    final archived = await archive.list();
    expect(archived.map((ride) => ride.rideId), contains(rideId));
    expect(controller.session, isNotNull);
    expect(find.byKey(const Key('file-ended-ride-button')), findsNothing);
  });
}

class _OfflineRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Offline in tests.');

  @override
  void close() {}
}
