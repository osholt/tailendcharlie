import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/pre_start_presence_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/relay/relay_presence.dart';
import 'package:ride_relay/services/transport_evidence_ledger.dart';

void main() {
  final session = RideSession(
    rideId: 'ride-presence',
    rideCode: '123456',
    inviteSecret: '0123456789abcdef0123456789abcdef',
    joinToken: 'test-join-token-0123456789',
    localRiderId: 'local',
    displayName: 'Oliver',
    role: RideRole.lead,
    joinedAt: DateTime.utc(2026, 7, 23, 10),
  );

  test(
    'keeps only fresh latest positions and clears without a journal',
    () async {
      var now = DateTime.utc(2026, 7, 23, 10);
      final remote = _location(
        riderId: 'remote',
        displayName: 'Alex',
        latitude: 51.1,
        receivedAt: now,
      );
      final api = _FakePresenceApi([
        PreStartPresenceResult(
          locations: [remote],
          ttl: const Duration(seconds: 45),
        ),
        PreStartPresenceResult(
          locations: [remote],
          ttl: const Duration(seconds: 45),
        ),
        const PreStartPresenceResult(locations: [], ttl: Duration(seconds: 45)),
      ]);
      final controller = PreStartPresenceController(
        api,
        pollInterval: const Duration(days: 1),
        clock: () => now,
      );
      addTearDown(controller.close);

      await controller.start(session);
      expect(controller.locations.single.riderId, 'remote');

      final local = _location(
        riderId: 'local',
        displayName: 'Oliver',
        latitude: 51.2,
        receivedAt: now,
      );
      controller.updateLocalPosition(local);
      await Future<void>.delayed(Duration.zero);

      expect(api.calls.last.position?.sample.position.latitude, 51.2);
      expect(api.calls.last.clear, isFalse);

      // Past the relay TTL a position is demoted, not deleted: a marker that
      // silently vanishes is indistinguishable from one that was never there.
      now = now.add(const Duration(seconds: 46));
      expect(
        controller.presenceAt(now).map((entry) => entry.freshness),
        everyElement(PresenceFreshness.ageing),
      );
      now = now.add(const Duration(minutes: 6));
      expect(controller.locations, isEmpty);

      await controller.clearLocalPosition();
      expect(api.calls.last.position, isNull);
      expect(api.calls.last.clear, isTrue);
    },
  );

  test(
    'merges authenticated nearby snapshots without persisting history',
    () async {
      var now = DateTime.utc(2026, 7, 23, 10);
      final api = _FakePresenceApi([
        const PreStartPresenceResult(locations: [], ttl: Duration(seconds: 45)),
        const PreStartPresenceResult(locations: [], ttl: Duration(seconds: 45)),
      ]);
      final nearby = _FakePresenceGateway();
      final controller = PreStartPresenceController(
        api,
        pollInterval: const Duration(days: 1),
        clock: () => now,
      );
      addTearDown(controller.close);
      addTearDown(nearby.close);
      await controller.start(session);
      await controller.attachNearby(nearby);
      final remote = _location(
        riderId: 'remote',
        displayName: 'Alex',
        latitude: 51.3,
        receivedAt: now,
      );

      nearby.emit(
        RelayPresenceUpdate(
          riderId: 'remote',
          sentAt: now,
          expiresAt: now.add(const Duration(seconds: 45)),
          clear: false,
          position: remote,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.locations.single.sample.position.latitude, 51.3);
      controller.updateLocalPosition(
        _location(
          riderId: 'local',
          displayName: 'Oliver',
          latitude: 51.4,
          receivedAt: now,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(nearby.published.last.position?.riderId, 'local');

      now = now.add(const Duration(seconds: 46));
      expect(
        controller
            .presenceAt(now)
            .firstWhere((entry) => entry.riderId == 'remote')
            .freshness,
        PresenceFreshness.ageing,
      );
      now = now.add(const Duration(minutes: 6));
      expect(
        controller.locations.where((value) => value.riderId == 'remote'),
        isEmpty,
      );
    },
  );

  // #855: which route delivered a live position, and how often.
  group('transport evidence', () {
    late DateTime now;
    late TransportEvidenceLedger ledger;

    setUp(() {
      now = DateTime.utc(2026, 10, 4, 10);
      ledger = TransportEvidenceLedger(localRiderId: 'local', clock: () => now);
    });

    PreStartPresenceController controllerFor(
      List<PreStartPresenceResult> results,
    ) {
      final controller = PreStartPresenceController(
        _FakePresenceApi(results),
        pollInterval: const Duration(days: 1),
        clock: () => now,
        evidence: ledger,
      );
      addTearDown(controller.close);
      return controller;
    }

    PreStartPresenceResult polled(RiderLocation location) =>
        PreStartPresenceResult(
          locations: [location],
          ttl: const Duration(seconds: 45),
        );

    RiderLocation remoteAt(DateTime recordedAt) => _location(
      riderId: 'remote',
      displayName: 'Alex',
      latitude: 51.1,
      receivedAt: recordedAt,
    );

    test(
      'a new position over the internet is counted, a repeat is not',
      () async {
        final first = remoteAt(now);
        final controller = controllerFor([
          polled(first),
          // The relay hands the same position back on every poll until the rider
          // sends another: that is the poll working, not the rider being heard.
          polled(first),
          polled(remoteAt(now.add(const Duration(seconds: 10)))),
        ]);

        await controller.start(session);
        expect(ledger.evidenceFor('remote')!.internet.presenceUpdates, 1);

        await controller.synchronizeNow();
        expect(ledger.evidenceFor('remote')!.internet.presenceUpdates, 1);

        now = now.add(const Duration(seconds: 10));
        await controller.synchronizeNow();
        expect(ledger.evidenceFor('remote')!.internet.presenceUpdates, 2);
        expect(ledger.evidenceFor('remote')!.internet.lastPresenceAt, now);
      },
    );

    test(
      'a position over the direct link is counted when it is newer',
      () async {
        final nearby = _FakePresenceGateway();
        addTearDown(nearby.close);
        final controller = controllerFor([
          const PreStartPresenceResult(
            locations: [],
            ttl: Duration(seconds: 45),
          ),
        ]);
        await controller.start(session);
        await controller.attachNearby(nearby);

        RelayPresenceUpdate update(DateTime sentAt, {bool clear = false}) =>
            RelayPresenceUpdate(
              riderId: 'remote',
              sentAt: sentAt,
              expiresAt: sentAt.add(const Duration(seconds: 45)),
              clear: clear,
              position: clear ? null : remoteAt(sentAt),
            );

        final first = now;
        nearby.emit(update(first));
        await Future<void>.delayed(Duration.zero);
        expect(ledger.evidenceFor('remote')!.bluetooth.presenceUpdates, 1);

        // The same snapshot again, and an older one: neither is a new position.
        nearby.emit(update(first));
        nearby.emit(update(first.subtract(const Duration(seconds: 5))));
        await Future<void>.delayed(Duration.zero);
        expect(ledger.evidenceFor('remote')!.bluetooth.presenceUpdates, 1);

        now = now.add(const Duration(seconds: 6));
        nearby.emit(update(now));
        await Future<void>.delayed(Duration.zero);
        expect(ledger.evidenceFor('remote')!.bluetooth.presenceUpdates, 2);
        expect(ledger.evidenceFor('remote')!.bluetooth.lastPresenceAt, now);

        // A rider who stops sharing sends a clear. That is not a position.
        now = now.add(const Duration(seconds: 6));
        nearby.emit(update(now, clear: true));
        await Future<void>.delayed(Duration.zero);
        expect(ledger.evidenceFor('remote')!.bluetooth.presenceUpdates, 2);
      },
    );

    test(
      'the same position arriving by both routes is credited to each',
      () async {
        final nearby = _FakePresenceGateway();
        addTearDown(nearby.close);
        final position = remoteAt(now);
        final controller = controllerFor([polled(position)]);
        await controller.start(session);
        await controller.attachNearby(nearby);

        nearby.emit(
          RelayPresenceUpdate(
            riderId: 'remote',
            sentAt: now,
            expiresAt: now.add(const Duration(seconds: 45)),
            clear: false,
            position: position,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final remote = ledger.evidenceFor('remote')!;
        expect(remote.internet.presenceUpdates, 1);
        expect(remote.bluetooth.presenceUpdates, 1);
      },
    );

    test('this phone\'s own position is never counted as evidence', () async {
      final nearby = _FakePresenceGateway();
      addTearDown(nearby.close);
      final controller = controllerFor([
        const PreStartPresenceResult(locations: [], ttl: Duration(seconds: 45)),
        const PreStartPresenceResult(locations: [], ttl: Duration(seconds: 45)),
      ]);
      await controller.start(session);
      await controller.attachNearby(nearby);

      controller.updateLocalPosition(
        _location(
          riderId: 'local',
          displayName: 'Oliver',
          latitude: 51.2,
          receivedAt: now,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(ledger.riders, isEmpty);
    });
  });
}

RiderLocation _location({
  required String riderId,
  required String displayName,
  required double latitude,
  required DateTime receivedAt,
}) => RiderLocation(
  riderId: riderId,
  displayName: displayName,
  role: riderId == 'local' ? RideRole.lead : RideRole.rider,
  sample: LocationSample(
    position: GeoPoint(latitude: latitude, longitude: -2.4),
    recordedAt: receivedAt,
    accuracyMeters: 4,
  ),
  receivedAt: receivedAt,
);

class _FakePresenceApi implements PreStartPresenceApi {
  _FakePresenceApi(this._results);

  final List<PreStartPresenceResult> _results;
  final List<({RideSession session, RiderLocation? position, bool clear})>
  calls = [];

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<PreStartPresenceResult> synchronizePreStartPresence({
    required RideSession session,
    required RiderLocation? position,
    required bool clear,
  }) async {
    calls.add((session: session, position: position, clear: clear));
    return _results.removeAt(0);
  }

  @override
  void close() {}
}

class _FakePresenceGateway implements RelayPresenceGateway {
  final _updates = StreamController<RelayPresenceUpdate>.broadcast();
  final List<({RiderLocation? position, bool clear, Duration ttl})> published =
      [];

  @override
  Stream<RelayPresenceUpdate> get presenceUpdates => _updates.stream;

  void emit(RelayPresenceUpdate update) => _updates.add(update);

  @override
  Future<void> publishPresence(
    RiderLocation? position, {
    bool clear = false,
    Duration ttl = const Duration(seconds: 45),
  }) async {
    published.add((position: position, clear: clear, ttl: ttl));
  }

  Future<void> close() => _updates.close();
}
