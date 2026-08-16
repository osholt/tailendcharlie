// Ties the end-of-ride copy to automatic Ride Library persistence (#542).

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/ended_ride_screen.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

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
