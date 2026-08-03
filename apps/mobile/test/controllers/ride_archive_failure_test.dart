import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/ended_ride_screen.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

/// "A ride that cannot be saved says so, loudly, rather than ending silently."
///
/// #299's requirement, and the acceptance criterion "a deliberately failed save
/// surfaces an error instead of completing quietly". Neither was met: a store
/// that threw produced the generic "that action could not be saved", which does
/// not say *what* was lost, and it abandoned the rest of `endRide` on the way
/// out.
void main() {
  late _FailingArchive archive;
  late RideController controller;
  late InMemoryEventStore events;
  late InMemorySessionStore sessions;
  late DateTime now;
  String? rideId;

  Future<void> startAndEnd() async {
    await controller.initialize();
    await controller.createRide('Oliver');
    await controller.startRide();
    rideId = controller.session?.rideId;
    await controller.endRide();
  }

  void buildController({required bool failing}) {
    archive = _FailingArchive()..failing = failing;
    events = InMemoryEventStore();
    sessions = InMemorySessionStore();
    now = DateTime.utc(2026, 8, 2, 12);
    var id = 0;
    controller = RideController(
      events,
      sessions,
      NearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${id++}',
      random: Random(11),
      rideCodeDirectory: _OfflineRideCodeDirectory(),
      completedRideStore: archive,
    );
  }

  setUp(() => buildController(failing: false));

  tearDown(() => controller.dispose());

  test('a failed save is reported in words about the ride', () async {
    buildController(failing: true);

    await startAndEnd();

    expect(controller.rideArchiveError, isNotNull);
    expect(
      controller.rideArchiveError,
      RideController.rideArchiveFailedMessage,
    );
    expect(
      controller.rideArchiveError,
      contains('Previous rides'),
      reason:
          'the generic "that action could not be saved" never said what '
          'had been lost',
    );
  });

  test('a ride that saves says nothing', () async {
    await startAndEnd();

    expect(controller.rideArchiveError, isNull);
    expect(archive.saved, hasLength(1));
  });

  test('the ride still ends when the save fails', () async {
    // The event is recorded before the archive is attempted, so a write failure
    // must not leave the ride neither ended nor saved.
    buildController(failing: true);

    await startAndEnd();

    expect(controller.rideEnded, isTrue);
  });

  test('a later successful save clears the warning', () async {
    // `initialize` retries while the journal survives, so the message states a
    // risk rather than a certainty — and has to stop being shown once the risk
    // is gone.
    buildController(failing: true);
    await startAndEnd();
    expect(controller.rideArchiveError, isNotNull);

    archive.failing = false;
    await controller.initialize();

    expect(controller.rideArchiveError, isNull);
    expect(archive.saved, isNotEmpty);
  });

  test('the 24-hour cleanup never deletes a ride it could not archive', () async {
    // The cleanup exists to reclaim space. Reclaiming it by destroying the only
    // copy of a ride is the exact data loss #299 is about, and it was reachable:
    // the archive attempt and the delete sat one after the other with nothing
    // between them.
    buildController(failing: true);
    await startAndEnd();
    expect(controller.rideArchiveError, isNotNull);

    // A day later, with the write still failing.
    now = now.add(const Duration(hours: 25));
    await controller.initialize();

    expect(
      controller.session,
      isNotNull,
      reason: 'the ride must survive so the next launch can try again',
    );
    expect(await events.eventsForRide(rideId!), isNotEmpty);

    // And once the write succeeds it is archived and then cleaned up as normal.
    archive.failing = false;
    await controller.initialize();

    expect(archive.saved, hasLength(1));
    expect(controller.session, isNull);
  });

  group('the ended-ride screen', () {
    // The ride is ended in `setUp`, outside the widget test's fake-async zone.
    // Ending it inside deadlocks: `endRide` arms the 24-hour cleanup timer, and
    // a real `await` waiting behind a fake clock that never advances does not
    // return.
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

    group('after a failed save', () {
      setUp(() async {
        buildController(failing: true);
        await startAndEnd();
      });

      testWidgets('leads with the failure', (tester) async {
        await pumpScreen(tester);

        expect(
          find.byKey(const Key('ride-archive-failed-notice')),
          findsOneWidget,
        );
        expect(find.text('This ride was not saved'), findsOneWidget);
      });
    });

    group('after a successful save', () {
      setUp(() async {
        buildController(failing: false);
        await startAndEnd();
      });

      testWidgets('says nothing', (tester) async {
        await pumpScreen(tester);

        expect(
          find.byKey(const Key('ride-archive-failed-notice')),
          findsNothing,
        );
      });
    });
  });
}

class _FailingArchive implements CompletedRideStore {
  bool failing = false;
  final List<CompletedRide> saved = [];

  @override
  Future<List<CompletedRide>> list() async => List.unmodifiable(saved);

  @override
  Future<void> save(CompletedRide ride) async {
    if (failing) throw StateError('disk full');
    // Upsert by ride, as a real store does: the same ride is archived by both
    // `initialize` and the expiry sweep, and two rows for one ride would be a
    // bug in the fake rather than in the controller.
    saved.removeWhere((existing) => existing.rideId == ride.rideId);
    saved.add(ride);
  }

  @override
  Future<void> delete(String rideId) async =>
      saved.removeWhere((ride) => ride.rideId == rideId);
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
