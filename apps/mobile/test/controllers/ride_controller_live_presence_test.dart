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

  /// Issue #144: the departure propagated correctly and then erased the record.
  /// The relay's roster keeps naming a rider who has left, which is how the row
  /// survives even when their membership events never reached this journal.
  group('a departed rider stays in the roster', () {
    test('the row remains, out of the live count, and says when', () {
      controller.observeLivePresence([_presence('bill', 'Bill', now)]);
      expect(controller.liveParticipants.length, 2);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      // What the relay reports the moment Bill leaves: no live presence for
      // him, and a roster that still names him as departed.
      controller.observeLivePresence(
        const [],
        roster: [
          _rosterMember(
            'bill',
            'Bill',
            joinedAt: now,
            left: true,
            leftAt: now.add(const Duration(minutes: 12)),
          ),
        ],
      );

      expect(notifications, 1);
      final bill = controller.participants.singleWhere(
        (participant) => participant.riderId == 'bill',
      );
      expect(bill.hasLeft, isTrue);
      expect(bill.stateLabel, 'Left the ride at 09:12');
      expect(bill.displayName, 'Bill');
      // Out of the live group immediately, and off the map with it.
      expect(controller.liveParticipants.length, 1);
      expect(controller.liveView.renderedPositions, isEmpty);
      expect(controller.liveView.isReconciled, isTrue);
    });

    test('a roster-only departure still reaches the roster', () {
      controller.observeLivePresence([_presence('bill', 'Bill', now)]);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      // The positions are unchanged; only the roster moved. The old no-churn
      // check compared positions alone, so this notified nobody.
      controller.observeLivePresence(
        [_presence('bill', 'Bill', now)],
        roster: [
          _rosterMember(
            'bill',
            'Bill',
            joinedAt: now,
            left: true,
            leftAt: now.add(const Duration(minutes: 12)),
          ),
        ],
      );

      expect(notifications, 1);
    });

    test('the record goes when the ride goes, and not before', () async {
      controller.observeLivePresence(
        const [],
        roster: [
          _rosterMember(
            'bill',
            'Bill',
            joinedAt: now,
            left: true,
            leftAt: now.add(const Duration(minutes: 12)),
          ),
        ],
      );
      expect(
        controller.participants.where(
          (participant) => participant.riderId == 'bill',
        ),
        hasLength(1),
      );

      await controller.startRide();
      await controller.endRide();

      // Ending the ride does not remove the record: the ride's own data is still
      // here for its retention window, and so is the rider who left.
      expect(
        controller.participants.where(
          (participant) => participant.riderId == 'bill',
        ),
        hasLength(1),
        reason: 'the lost-item lookup happens after the ride, not during it',
      );

      await controller.clearEndedRide();

      // Removing the ride removes the record with it. There is nowhere else it
      // is kept.
      expect(controller.participants, isEmpty);
      expect(controller.session, isNull);
    });
  });
}

PresenceRosterMember _rosterMember(
  String riderId,
  String displayName, {
  required DateTime joinedAt,
  bool left = false,
  DateTime? leftAt,
}) => PresenceRosterMember(
  riderId: riderId,
  displayName: displayName,
  role: RideRole.rider,
  joinedAt: joinedAt,
  left: left,
  leftAt: leftAt,
);

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
