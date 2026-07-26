import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/relay/live_presence.dart';

void main() {
  final now = DateTime.utc(2026, 7, 25, 12);

  group('PresenceFreshnessPolicy', () {
    const policy = PresenceFreshnessPolicy();

    test('classifies documented thresholds inclusively', () {
      expect(policy.classify(Duration.zero), PresenceFreshness.live);
      expect(
        policy.classify(const Duration(seconds: 20)),
        PresenceFreshness.live,
      );
      expect(
        policy.classify(const Duration(seconds: 21)),
        PresenceFreshness.ageing,
      );
      expect(
        policy.classify(const Duration(seconds: 60)),
        PresenceFreshness.ageing,
      );
      expect(
        policy.classify(const Duration(seconds: 61)),
        PresenceFreshness.stale,
      );
      expect(
        policy.classify(const Duration(minutes: 5)),
        PresenceFreshness.stale,
      );
      // Age alone never produces "no position": a stale fix is demoted, not
      // deleted, because where a rider stopped is what the group needs.
      expect(
        policy.classify(const Duration(hours: 3)),
        PresenceFreshness.stale,
      );
    });

    test('treats a clock that runs backwards as live rather than stale', () {
      expect(
        policy.classify(const Duration(seconds: -30)),
        PresenceFreshness.live,
      );
    });
  });

  test('merges both transports and keeps the newest sample per rider', () {
    final result = const LivePresenceReconciler().reconcile(
      now: now,
      localRiderId: 'local',
      journal: [
        _location(
          'alex',
          'Alex',
          recordedAt: now.subtract(const Duration(seconds: 90)),
        ),
      ],
      internetPresence: [
        _location(
          'alex',
          'Alex',
          recordedAt: now.subtract(const Duration(seconds: 5)),
        ),
      ],
      nearbyPresence: [
        _location(
          'alex',
          'Alex',
          recordedAt: now.subtract(const Duration(seconds: 40)),
        ),
      ],
    );

    final alex = result.single;
    expect(alex.freshness, PresenceFreshness.live);
    expect(alex.age, const Duration(seconds: 5));
    expect(alex.sources, {
      LivePresenceSource.journal,
      LivePresenceSource.internetPresence,
      LivePresenceSource.nearbyPresence,
    });
    // The oldest observation still dates when the rider became known, so the
    // roster order does not jitter as fresher samples arrive.
    expect(alex.knownSince, now.subtract(const Duration(seconds: 90)));
  });

  test('an out-of-order or duplicated delivery never rewinds a rider', () {
    final newest = _location(
      'alex',
      'Alex',
      latitude: 52.0,
      recordedAt: now.subtract(const Duration(seconds: 2)),
    );
    final stale = _location(
      'alex',
      'Alex',
      latitude: 51.0,
      recordedAt: now.subtract(const Duration(seconds: 45)),
    );

    final result = const LivePresenceReconciler().reconcile(
      now: now,
      localRiderId: 'local',
      internetPresence: [newest, stale, newest, stale],
    );

    expect(result.single.location!.sample.position.latitude, 52.0);
    expect(result.single.freshness, PresenceFreshness.live);
  });

  test('a stale position is demoted but never dropped', () {
    RiderLocation at(Duration age) =>
        _location('alex', 'Alex', recordedAt: now.subtract(age));

    PresenceFreshness freshnessAfter(Duration age) =>
        const LivePresenceReconciler()
            .reconcile(
              now: now,
              localRiderId: 'local',
              internetPresence: [at(age)],
            )
            .single
            .freshness;

    expect(freshnessAfter(const Duration(seconds: 5)), PresenceFreshness.live);
    expect(
      freshnessAfter(const Duration(seconds: 30)),
      PresenceFreshness.ageing,
    );
    expect(freshnessAfter(const Duration(minutes: 2)), PresenceFreshness.stale);

    final ancient = const LivePresenceReconciler()
        .reconcile(
          now: now,
          localRiderId: 'local',
          internetPresence: [at(const Duration(minutes: 30))],
        )
        .single;
    expect(ancient.freshness, PresenceFreshness.stale);
    expect(ancient.location, isNotNull);
    expect(ancient.age, const Duration(minutes: 30));
    // Demoted in words so it can never read as current.
    expect(ancient.freshnessLabel, 'Stale 30m');
  });

  test('a roster member with no position is reported, not omitted', () {
    final result = const LivePresenceReconciler().reconcile(
      now: now,
      localRiderId: 'local',
      roster: [
        PresenceRosterMember(
          riderId: 'bill',
          displayName: 'Bill',
          role: RideRole.rider,
          joinedAt: now.subtract(const Duration(minutes: 3)),
        ),
      ],
    );

    final bill = result.single;
    expect(bill.riderId, 'bill');
    expect(bill.hasPosition, isFalse);
    expect(bill.freshness, PresenceFreshness.none);
    expect(bill.sources, isEmpty);
    expect(bill.knownSince, now.subtract(const Duration(minutes: 3)));
  });

  test('a rider who has left the roster is not resurrected', () {
    final result = const LivePresenceReconciler().reconcile(
      now: now,
      localRiderId: 'local',
      roster: [
        PresenceRosterMember(
          riderId: 'gone',
          displayName: 'Gone',
          role: RideRole.rider,
          joinedAt: now,
          left: true,
        ),
      ],
    );

    expect(result, isEmpty);
  });

  test('roster identity wins over a self-described position payload', () {
    final result = const LivePresenceReconciler().reconcile(
      now: now,
      localRiderId: 'local',
      internetPresence: [
        _location('bill', 'Impostor', recordedAt: now, role: RideRole.lead),
      ],
      roster: [
        PresenceRosterMember(
          riderId: 'bill',
          displayName: 'Bill',
          role: RideRole.rider,
          joinedAt: now.subtract(const Duration(minutes: 1)),
        ),
      ],
    );

    expect(result.single.displayName, 'Bill');
    expect(result.single.role, RideRole.rider);
  });

  test('the local rider is flagged and gains a local-device source', () {
    final result = const LivePresenceReconciler().reconcile(
      now: now,
      localRiderId: 'local',
      internetPresence: [_location('local', 'Me', recordedAt: now)],
    );

    expect(result.single.isLocal, isTrue);
    expect(
      result.single.sources,
      containsAll([
        LivePresenceSource.localDevice,
        LivePresenceSource.internetPresence,
      ]),
    );
  });

  test('reconcileLocations returns one drawable position per rider', () {
    final locations = const LivePresenceReconciler().reconcileLocations(
      now: now,
      localRiderId: 'local',
      journal: [
        _location(
          'alex',
          'Alex',
          recordedAt: now.subtract(const Duration(seconds: 3)),
        ),
        _location(
          'bill',
          'Bill',
          recordedAt: now.subtract(const Duration(hours: 1)),
        ),
      ],
      internetPresence: [
        _location('alex', 'Alex', latitude: 49, recordedAt: now),
      ],
    );

    // One entry per rider, each the newest known fix. An hour-old fix is still
    // returned: the caller demotes it, it is not silently withheld.
    expect(locations.map((location) => location.riderId), ['alex', 'bill']);
    expect(locations.first.sample.position.latitude, 49);
  });

  test('freshness wording states the age without relying on colour', () {
    final ageing = const LivePresenceReconciler()
        .reconcile(
          now: now,
          localRiderId: 'local',
          internetPresence: [
            _location(
              'alex',
              'Alex',
              recordedAt: now.subtract(const Duration(seconds: 45)),
            ),
          ],
        )
        .single;

    expect(ageing.freshnessLabel, 'Ageing 45s');
    expect(formatPresenceAge(const Duration(seconds: 5)), '5s');
    expect(formatPresenceAge(const Duration(minutes: 3)), '3m');
    expect(formatPresenceAge(const Duration(hours: 2)), '2h');
    expect(formatPresenceAge(const Duration(seconds: -5)), '0s');
  });

  test('a peer limitation names the rider without leaking anything else', () {
    final limitation = PresenceLimitation.peerAppOlder(
      riderId: 'bill',
      displayName: 'Bill',
    );

    expect(limitation.kind, PresenceLimitationKind.peerAppOlder);
    expect(limitation.message, contains('Bill'));
    expect(limitation.message, contains('older'));
    expect(limitation.message, isNot(contains('http')));
  });
}

RiderLocation _location(
  String riderId,
  String displayName, {
  required DateTime recordedAt,
  double latitude = 51.5,
  RideRole role = RideRole.rider,
}) => RiderLocation(
  riderId: riderId,
  displayName: displayName,
  role: role,
  sample: LocationSample(
    position: GeoPoint(latitude: latitude, longitude: -2.4),
    recordedAt: recordedAt,
    accuracyMeters: 5,
  ),
  receivedAt: recordedAt,
);
