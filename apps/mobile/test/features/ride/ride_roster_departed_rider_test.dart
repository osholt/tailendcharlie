import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/ride/ride_roster_sheet.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// Issue #144 from the leader's side. The field report is about this screen:
/// "It also removed the data from the ride roster list. It would be good to keep
/// that until at least the end of the ride just in case something came up like a
/// lost item etc."
///
/// So the row survives the departure, reads as its own state with a time, and
/// carries the rider's last known position — while the live count on the same
/// screen still excludes them.
void main() {
  late InMemoryEventStore eventStore;
  late RideController controller;
  final startedAt = DateTime.utc(2026, 7, 26, 14);

  setUp(() async {
    eventStore = InMemoryEventStore();
    var id = 0;
    controller = RideController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => startedAt.add(const Duration(minutes: 40)),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(11),
      rideCodeDirectory: _NullRideCodeDirectory(),
    );
    await controller.initialize();
    await controller.createRide('Lead');
    final session = controller.session!;
    for (final event in [
      _signed(
        session: session,
        id: 'join-bill',
        deviceId: 'bill',
        type: RideEventType.riderJoined,
        createdAt: startedAt,
        payload: const {'displayName': 'Bill', 'role': 'tailEndCharlie'},
      ),
      _signed(
        session: session,
        id: 'location-bill',
        deviceId: 'bill',
        type: RideEventType.riderLocationUpdated,
        createdAt: startedAt.add(const Duration(minutes: 20)),
        payload: {
          'location': RiderLocation(
            riderId: 'bill',
            displayName: 'Bill',
            role: RideRole.tailEndCharlie,
            sample: LocationSample(
              position: const GeoPoint(latitude: 51.20011, longitude: -2.40022),
              recordedAt: startedAt.add(const Duration(minutes: 20)),
              accuracyMeters: 6,
            ),
            receivedAt: startedAt.add(const Duration(minutes: 20)),
          ).toJson(),
        },
      ),
      _signed(
        session: session,
        id: 'left-bill',
        deviceId: 'bill',
        type: RideEventType.riderLeft,
        createdAt: startedAt.add(const Duration(minutes: 32)),
        payload: const {
          'riderId': 'bill',
          'displayName': 'Bill',
          'reason': 'left',
        },
      ),
    ]) {
      await eventStore.append(event);
    }
    await controller.reloadEvents();
  });

  tearDown(() => controller.dispose());

  Widget harness() => MaterialApp(
    home: Scaffold(body: RideRosterSheet(controller: controller)),
  );

  testWidgets('a departed rider is kept, and said to be kept', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // The live count excludes them the moment they leave; the record does not.
    expect(find.text('1 currently included · 2 recorded'), findsOneWidget);
    expect(find.byKey(const Key('roster-rider-bill')), findsNothing);
    expect(find.byKey(const Key('roster-departed-notice')), findsOneWidget);
    expect(
      find.textContaining('record is kept until this ride ends'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('roster-show-departed')));
    await tester.pumpAndSettle();

    // The row itself: its own state with a time, the retained role, and where
    // Bill was last known to be.
    expect(find.byKey(const Key('roster-rider-bill')), findsOneWidget);
    expect(
      find.textContaining('Tail End Charlie · Left the ride at 14:32'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Last known position 51.20011, -2.40022'),
      findsOneWidget,
    );
    // Nothing on a departed row invites an action on a rider who is not there.
    expect(find.byKey(const Key('ask-tec-bill')), findsNothing);
    // Now that they are on screen, the notice has nothing left to say.
    expect(find.byKey(const Key('roster-departed-notice')), findsNothing);
  });

  testWidgets('the departed row is in the full roster too, and last', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('All joined'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('roster-rider-bill')), findsOneWidget);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles, hasLength(2));
    expect(
      (tiles.last.key as ValueKey<String>).value,
      'roster-rider-bill',
      reason: 'riders still in the ride come first',
    );
  });

  testWidgets('the accessible label states the departure, not a colour', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-show-departed')));
    await tester.pumpAndSettle();

    final semantics = tester.getSemantics(
      find.byKey(const Key('roster-rider-bill')),
    );
    expect(semantics.label, contains('Left the ride at 14:32'));
    expect(semantics.label, contains('Last known position'));
  });
}

RideEvent _signed({
  required RideSession session,
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
    id: id,
    rideId: session.rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: RideEventAuthenticator.sign(unsigned, session.inviteSecret),
  );
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _NullRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Not used in this test.');

  @override
  void close() {}
}
