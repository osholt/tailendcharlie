import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

/// A join must reach the leader's roster without waiting for the bulk event
/// batch: the field report in issue #99 had a joiner the leader never saw at all.
void main() {
  final now = DateTime.utc(2026, 7, 25, 9);
  late RideController controller;
  late int id;

  setUp(() async {
    id = 0;
    controller = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(42),
      rideCodeDirectory: _UnusedRideCodeDirectory(),
    );
    await controller.initialize();
    await controller.createRide('Oliver');
  });

  tearDown(() => controller.dispose());

  test('a presence-only rider joins the roster and notifies listeners', () {
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([_presence('bill', 'Bill', now)]);

    expect(notifications, 1);
    final bill = controller.participants.firstWhere(
      (participant) => participant.riderId == 'bill',
    );
    expect(bill.displayName, 'Bill');
    expect(bill.knownFromRelayOnly, isTrue);
    expect(controller.liveParticipants.length, 2);
  });

  test('an unchanged observation does not churn listeners', () {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([_presence('bill', 'Bill', now)]);

    expect(notifications, 0);
    expect(controller.livePresence.single.riderId, 'bill');
  });

  test('a freshness change is observed and stated in the roster', () {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([
      _presence('bill', 'Bill', now, freshness: PresenceFreshness.stale),
    ]);

    expect(notifications, 1);
    final bill = controller.participants.firstWhere(
      (participant) => participant.riderId == 'bill',
    );
    expect(bill.positionFreshness, PresenceFreshness.stale);
    expect(bill.stateLabel, contains('position stale'));
  });

  test('a newer sample for the same rider is observed', () {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([
      _presence('bill', 'Bill', now.add(const Duration(seconds: 4))),
    ]);

    expect(notifications, 1);
  });

  test('presence is discarded when the ride is left', () async {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    expect(controller.livePresence, isNotEmpty);

    await controller.leaveRide();

    expect(controller.livePresence, isEmpty);
    expect(controller.participants, isEmpty);
  });
}

LiveRiderPresence _presence(
  String riderId,
  String displayName,
  DateTime recordedAt, {
  PresenceFreshness freshness = PresenceFreshness.live,
}) => LiveRiderPresence(
  riderId: riderId,
  displayName: displayName,
  role: RideRole.rider,
  freshness: freshness,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: recordedAt,
  location: RiderLocation(
    riderId: riderId,
    displayName: displayName,
    role: RideRole.rider,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.5, longitude: -2.4),
      recordedAt: recordedAt,
      accuracyMeters: 5,
    ),
    receivedAt: recordedAt,
  ),
  age: Duration.zero,
);

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _UnusedRideCodeDirectory implements RideCodeDirectory {
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
