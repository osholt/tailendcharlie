import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/ride_completion_detector.dart';
import 'package:ride_relay/services/route_progress.dart';
import 'package:ride_relay/services/sharing_dispersal.dart';

/// Metres per degree of latitude on the sphere `GeoCalculations` uses, so a
/// position placed this many degrees north is that many metres away.
const _metresPerDegree = 111194.9;

final _now = DateTime.utc(2026, 10, 4, 15);
const _here = GeoPoint(latitude: 51.5, longitude: -2.5);

GeoPoint _north(double metres, [GeoPoint from = _here]) => GeoPoint(
  latitude: from.latitude + metres / _metresPerDegree,
  longitude: from.longitude,
);

LocationSample _fix([GeoPoint position = _here]) => LocationSample(
  position: position,
  recordedAt: _now,
  accuracyMeters: 5,
  speedMetersPerSecond: 0,
);

DispersalPeer _peer({
  String id = 'peer',
  required double metres,
  PresenceFreshness freshness = PresenceFreshness.live,
  Duration age = const Duration(seconds: 5),
  double? speed = 0,
}) => DispersalPeer(
  riderId: id,
  freshness: freshness,
  position: _north(metres),
  age: age,
  speedMetersPerSecond: speed,
);

DispersalAssessment _assess({
  List<DispersalPeer> peers = const [],
  bool groupRide = true,
  LocationSample? local,
  bool useLocal = true,
  bool observable = true,
  Duration parkedFor = const Duration(hours: 1),
  DispersalRoute? route,
  DispersalMarkerWait? marker,
  DateTime? ridePausedAt,
  SharingDispersalPolicy policy = const SharingDispersalPolicy(),
}) => assessDispersal(
  DispersalInput(
    now: _now,
    groupRide: groupRide,
    local: useLocal ? (local ?? _fix()) : null,
    localParkedFor: parkedFor,
    peers: peers,
    peersObservable: observable,
    route: route,
    marker: marker,
    ridePausedAt: ridePausedAt,
  ),
  policy: policy,
);

void main() {
  group('a group that has dispersed', () {
    test('riders at their own homes, all still, are dispersed', () {
      final assessment = _assess(
        peers: [
          _peer(id: 'a', metres: 9000),
          _peer(id: 'b', metres: 30000),
          _peer(id: 'c', metres: 60000),
        ],
      );

      expect(assessment.state, DispersalState.dispersed);
      expect(assessment.dispersed, isTrue);
    });

    test('a leader with nobody else in the ride is dispersed', () {
      expect(_assess().state, DispersalState.dispersed);
    });

    test('everyone else stopped reporting and went far away', () {
      final assessment = _assess(
        peers: [
          _peer(
            id: 'a',
            metres: 40000,
            freshness: PresenceFreshness.stale,
            age: const Duration(hours: 5),
            speed: 25,
          ),
        ],
      );

      expect(assessment.state, DispersalState.dispersed);
    });

    test('a rider with no position at all counts for nothing', () {
      final assessment = _assess(
        peers: const [
          DispersalPeer(riderId: 'ghost', freshness: PresenceFreshness.none),
        ],
      );

      expect(assessment.state, DispersalState.dispersed);
    });
  });

  group('being with the group', () {
    test('a fresh rider just inside 2 km is company', () {
      final assessment = _assess(peers: [_peer(metres: 1990)]);

      expect(assessment.state, DispersalState.withGroup);
      expect(assessment.dispersed, isFalse);
    });

    test('a fresh rider just outside 2 km is not', () {
      final assessment = _assess(peers: [_peer(metres: 2010)]);

      expect(assessment.state, DispersalState.dispersed);
    });

    test('company wins over everything else, including being off route', () {
      final assessment = _assess(
        peers: [_peer(metres: 100)],
        route: const DispersalRoute(withinCorridor: false, progressFraction: 1),
      );

      expect(assessment.state, DispersalState.withGroup);
    });

    test('a quiet phone near here is still company for two hours', () {
      // Fixes follow distance travelled, so a group at a long lunch goes quiet
      // on each other's screens. Silence is not departure.
      final remembered = _assess(
        peers: [
          _peer(
            metres: 300,
            freshness: PresenceFreshness.stale,
            age: const Duration(hours: 1, minutes: 59),
          ),
        ],
      );
      final forgotten = _assess(
        peers: [
          _peer(
            metres: 300,
            freshness: PresenceFreshness.stale,
            age: const Duration(hours: 2, minutes: 1),
          ),
        ],
      );

      expect(remembered.state, DispersalState.withGroup);
      expect(forgotten.state, DispersalState.dispersed);
    });

    test('a position exactly two hours old still counts', () {
      final assessment = _assess(
        peers: [
          _peer(
            metres: 300,
            freshness: PresenceFreshness.stale,
            age: const Duration(hours: 2),
          ),
        ],
      );

      expect(assessment.state, DispersalState.withGroup);
    });

    test('a rider whose position never arrived cannot be company', () {
      final assessment = _assess(
        peers: const [
          DispersalPeer(
            riderId: 'ghost',
            freshness: PresenceFreshness.none,
            age: Duration.zero,
          ),
        ],
      );

      expect(assessment.state, DispersalState.dispersed);
    });
  });

  group('a group still out riding', () {
    test('a TEC far behind but still riding is not dispersed', () {
      // The leader is 8 km up the road and moving. The TEC is nowhere near
      // anyone, and the rest of the group is still out there.
      final assessment = _assess(
        peers: [_peer(id: 'lead', metres: 8000, speed: 24)],
      );

      expect(assessment.state, DispersalState.groupRiding);
      expect(assessment.dispersed, isFalse);
    });

    test(
      'a rider who has broken down is not dispersed while the group rides',
      () {
        // Parked for hours, far from everyone, with the group moving on: this is
        // a rider the group may need to find, not a ride that has ended.
        final assessment = _assess(
          parkedFor: const Duration(hours: 4),
          peers: [_peer(metres: 12000, speed: 20)],
        );

        expect(assessment.state, DispersalState.groupRiding);
      },
    );

    test('a moving rider just inside 25 km counts, just outside does not', () {
      expect(
        _assess(peers: [_peer(metres: 24900, speed: 20)]).state,
        DispersalState.groupRiding,
      );
      expect(
        _assess(peers: [_peer(metres: 25100, speed: 20)]).state,
        DispersalState.dispersed,
      );
    });

    test('2 m/s is moving and 1.9 m/s is not', () {
      expect(
        _assess(peers: [_peer(metres: 9000, speed: 2)]).state,
        DispersalState.groupRiding,
      );
      expect(
        _assess(peers: [_peer(metres: 9000, speed: 1.9)]).state,
        DispersalState.dispersed,
      );
    });

    test(
      'a speed from a rider we have not heard from lately means nothing',
      () {
        final assessment = _assess(
          peers: [
            _peer(
              metres: 9000,
              speed: 25,
              freshness: PresenceFreshness.stale,
              age: const Duration(minutes: 3),
            ),
          ],
        );

        expect(assessment.state, DispersalState.dispersed);
      },
    );

    test('an ageing position still counts as heard from', () {
      final assessment = _assess(
        peers: [
          _peer(
            metres: 9000,
            speed: 25,
            freshness: PresenceFreshness.ageing,
            age: const Duration(seconds: 50),
          ),
        ],
      );

      expect(assessment.state, DispersalState.groupRiding);
    });

    test('a rider with no speed reading is not taken to be moving', () {
      final assessment = _assess(peers: [_peer(metres: 9000, speed: null)]);

      expect(assessment.state, DispersalState.dispersed);
    });
  });

  group('a pause the leader declared', () {
    DispersalAssessment pausedFor(Duration pausedFor) =>
        _assess(ridePausedAt: _now.subtract(pausedFor));

    test('is the group stopped on purpose, not a ride nobody ended', () {
      final assessment = pausedFor(const Duration(minutes: 45));

      expect(assessment.state, DispersalState.groupPaused);
      expect(assessment.dispersed, isFalse);
    });

    test('is protected for two hours and no longer', () {
      expect(
        pausedFor(const Duration(hours: 1, minutes: 59)).state,
        DispersalState.groupPaused,
      );
      expect(
        pausedFor(const Duration(hours: 2, minutes: 1)).state,
        DispersalState.dispersed,
      );
    });

    test('a ride that is not paused gets no such protection', () {
      expect(_assess().state, DispersalState.dispersed);
    });

    test('protects a rider scattered from the group during the stop', () {
      // Apart from everyone, parked for an hour, off route: exactly what would
      // be dispersed in a ride that was moving.
      final assessment = _assess(
        parkedFor: const Duration(hours: 1),
        peers: [_peer(metres: 6000)],
        ridePausedAt: _now.subtract(const Duration(minutes: 50)),
      );

      expect(assessment.state, DispersalState.groupPaused);
    });

    test('company still comes first', () {
      final assessment = _assess(
        peers: [_peer(metres: 100)],
        ridePausedAt: _now.subtract(const Duration(minutes: 5)),
      );

      expect(assessment.state, DispersalState.withGroup);
    });
  });

  group('a marker waiting at a junction', () {
    final started = _now.subtract(const Duration(minutes: 40));

    test('is not dispersed while the group is still expected', () {
      final assessment = _assess(
        marker: DispersalMarkerWait(startedAt: started, tecPassed: false),
      );

      expect(assessment.state, DispersalState.markerWaiting);
      expect(assessment.dispersed, isFalse);
    });

    test('is dispersed once the Tail End Charlie has passed', () {
      final assessment = _assess(
        marker: DispersalMarkerWait(startedAt: started, tecPassed: true),
      );

      expect(assessment.state, DispersalState.dispersed);
    });

    test('stops being protected after 90 minutes of waiting', () {
      DispersalAssessment waited(Duration waitedFor) => _assess(
        marker: DispersalMarkerWait(
          startedAt: _now.subtract(waitedFor),
          tecPassed: false,
        ),
      );

      expect(
        waited(const Duration(minutes: 89)).state,
        DispersalState.markerWaiting,
      );
      expect(
        waited(const Duration(minutes: 91)).state,
        DispersalState.dispersed,
      );
    });
  });

  group('a rider on the route', () {
    test('is not dispersed while the route is unfinished', () {
      final assessment = _assess(
        route: const DispersalRoute(
          withinCorridor: true,
          progressFraction: 0.4,
        ),
      );

      expect(assessment.state, DispersalState.onRoute);
    });

    test('is dispersed once 90% of it is behind them', () {
      DispersalAssessment at(double progress) => _assess(
        route: DispersalRoute(withinCorridor: true, progressFraction: progress),
      );

      expect(at(0.899).state, DispersalState.onRoute);
      expect(at(0.9).state, DispersalState.dispersed);
    });

    test('the finish line is the completion detector\'s, not a copy', () {
      expect(
        const SharingDispersalPolicy().routeCompleteFraction,
        RideCompletionDetector.defaultMinimumRouteProgressFraction,
      );
      expect(
        const SharingDispersalPolicy().routeCorridorMeters,
        RouteProgressTracker.defaultMaximumTrackingDistanceMeters,
      );
    });

    test('is dispersed when nowhere near the route', () {
      final assessment = _assess(
        route: const DispersalRoute(
          withinCorridor: false,
          progressFraction: 0.4,
        ),
      );

      expect(assessment.state, DispersalState.dispersed);
    });

    test('a long stop on the route is protected for three hours, no more', () {
      DispersalAssessment parked(Duration parkedFor) => _assess(
        parkedFor: parkedFor,
        route: const DispersalRoute(
          withinCorridor: true,
          progressFraction: 0.4,
        ),
      );

      expect(
        parked(const Duration(hours: 2, minutes: 59)).state,
        DispersalState.onRoute,
      );
      expect(
        parked(const Duration(hours: 3, minutes: 1)).state,
        DispersalState.dispersed,
      );
    });

    test('a TEC far behind on the route, with everyone else parked', () {
      final assessment = _assess(
        peers: [_peer(metres: 14000, speed: 0)],
        route: const DispersalRoute(
          withinCorridor: true,
          progressFraction: 0.5,
        ),
      );

      expect(assessment.state, DispersalState.onRoute);
    });
  });

  group('a rider alone on a long stop', () {
    test('is dispersed however long they have been parked', () {
      for (final hours in [1, 6, 24]) {
        expect(
          _assess(parkedFor: Duration(hours: hours)).state,
          DispersalState.dispersed,
          reason: 'parked for $hours h with nobody else in the ride',
        );
      }
    });

    test('is not touched on a solo ride, which has no group to leave', () {
      final assessment = _assess(groupRide: false);

      expect(assessment.state, DispersalState.soloRide);
      expect(assessment.dispersed, isFalse);
    });
  });

  group('when there is nothing to judge by', () {
    test('no fix of our own is no verdict', () {
      expect(_assess(useLocal: false).state, DispersalState.unknown);
    });

    test('a group this phone cannot see is no verdict', () {
      // "I see nobody" is evidence of an empty ride only if the phone can see.
      expect(_assess(observable: false).state, DispersalState.unknown);
      expect(
        _assess(observable: false, peers: [_peer(metres: 30000)]).state,
        DispersalState.unknown,
      );
    });
  });

  group('DispersalRoute.fromProgress', () {
    DispersalRoute? route({
      double off = 10,
      double progress = 400,
      double total = 1000,
    }) => DispersalRoute.fromProgress(
      distanceOffRouteMeters: off,
      progressMeters: progress,
      totalMeters: total,
    );

    test('150 m from the route is on it and 151 m is not', () {
      expect(route(off: 150)!.withinCorridor, isTrue);
      expect(route(off: 151)!.withinCorridor, isFalse);
    });

    test('progress is a fraction of the route', () {
      expect(route(progress: 250, total: 1000)!.progressFraction, 0.25);
    });

    test('a route with no length is no route', () {
      expect(route(total: 0), isNull);
      expect(route(total: double.nan), isNull);
      expect(route(off: double.infinity), isNull);
    });
  });

  group('what the shell hands the rule', () {
    LiveRiderPresence presence(String id, {bool isLocal = false}) =>
        LiveRiderPresence(
          riderId: id,
          displayName: id,
          role: RideRole.rider,
          freshness: PresenceFreshness.live,
          sources: const {LivePresenceSource.internetPresence},
          isLocal: isLocal,
          knownSince: _now,
          age: Duration.zero,
          location: RiderLocation(
            riderId: id,
            displayName: id,
            role: RideRole.rider,
            sample: _fix(_north(100)),
            receivedAt: _now,
          ),
        );

    test('this rider is not their own company', () {
      final peers = dispersalPeersFrom(
        [presence('me', isLocal: true), presence('alex')],
        liveRiderIds: {'me', 'alex'},
      );

      expect(peers.map((peer) => peer.riderId), ['alex']);
    });

    test('a rider who has left is not company, however recent their fix', () {
      final peers = dispersalPeersFrom(
        [presence('alex'), presence('sam')],
        liveRiderIds: {'alex'},
      );

      expect(peers.map((peer) => peer.riderId), ['alex']);
      expect(
        _assess(
          peers: dispersalPeersFrom([presence('sam')], liveRiderIds: {}),
        ).state,
        DispersalState.dispersed,
      );
    });

    test('a marker session becomes a wait, and the TEC passing is carried', () {
      final started = _now.subtract(const Duration(minutes: 10));
      MarkerSessionSummary session({DateTime? tecPassedAt}) =>
          MarkerSessionSummary(
            sessionId: 's',
            markerDeviceId: 'me',
            startedAt: started,
            mode: 'manual',
            uniquePassCount: 0,
            uniqueRiderIds: const [],
            verifiedPassCount: 0,
            verifiedRiderIds: const [],
            tecPassedAt: tecPassedAt,
          );

      expect(dispersalMarkerFrom(null), isNull);
      expect(dispersalMarkerFrom(session())!.startedAt, started);
      expect(dispersalMarkerFrom(session())!.tecPassed, isFalse);
      expect(
        dispersalMarkerFrom(session(tecPassedAt: _now))!.tecPassed,
        isTrue,
      );
    });
  });

  group('DispersalPeer.fromPresence', () {
    test('carries position, age, speed and freshness from the live model', () {
      final sample = LocationSample(
        position: _north(500),
        recordedAt: _now,
        accuracyMeters: 4,
        speedMetersPerSecond: 12,
      );
      final presence = LiveRiderPresence(
        riderId: 'alex',
        displayName: 'Alex',
        role: RideRole.tailEndCharlie,
        freshness: PresenceFreshness.ageing,
        sources: const {LivePresenceSource.internetPresence},
        isLocal: false,
        knownSince: _now,
        location: RiderLocation(
          riderId: 'alex',
          displayName: 'Alex',
          role: RideRole.tailEndCharlie,
          sample: sample,
          receivedAt: _now,
        ),
        age: const Duration(seconds: 40),
      );

      final peer = DispersalPeer.fromPresence(presence);

      expect(peer.riderId, 'alex');
      expect(peer.freshness, PresenceFreshness.ageing);
      expect(peer.isFresh, isTrue);
      expect(peer.position, sample.position);
      expect(peer.age, const Duration(seconds: 40));
      expect(peer.speedMetersPerSecond, 12);
    });

    test('a rider with no position has none and is not fresh', () {
      final peer = DispersalPeer.fromPresence(
        LiveRiderPresence(
          riderId: 'sam',
          displayName: 'Sam',
          role: RideRole.rider,
          freshness: PresenceFreshness.none,
          sources: const {},
          isLocal: false,
          knownSince: _now,
        ),
      );

      expect(peer.position, isNull);
      expect(peer.age, isNull);
      expect(peer.isFresh, isFalse);
    });
  });
}
