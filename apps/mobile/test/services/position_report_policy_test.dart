import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/imported_route.dart' as route_domain;
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/geo_calculations.dart';
import 'package:ride_relay/services/position_report_policy.dart';
import 'package:ride_relay/services/route_deviation_detector.dart';
import 'package:ride_relay/services/trail_display_simplifier.dart';

/// Issue #166: position reports follow distance travelled, and presence follows
/// a keep-alive timer that does not care whether the rider has moved.
///
/// The measurements here are the evidence the issue asks for, and every one of
/// them measures *this* layer: how many durable position reports a path
/// produces, how far the reported trail sits from the road the rider actually
/// rode, and how long off-course confirmation takes. Battery cannot be measured
/// from a test and is not claimed anywhere in this file.
///
/// Three tests exist because the first implementation failed them, and their
/// numbers are what chose the thresholds. Do not relax them without measuring
/// again:
///
///  - `a travel threshold is what holds a 30 m hairpin` — reporting on
///    straight-line displacement let the chord overshoot and cut the bend by
///    16 m.
///  - `20 m lands on the platform filter boundary and 18 m does not` — the
///    reason the threshold is not the 20 m the field request suggested.
///  - `GPS wander on a stationary phone produces no movement report` — a
///    bearing-change rule guarded only by displacement reported 60 of 300
///    stationary fixes as movement at a 6 m wander radius, and 150 of 300 at
///    10 m.
void main() {
  group('the gate', () {
    test('the first fix always reports, because there is no baseline', () {
      final gate = PositionReportGate();

      expect(
        gate.consider(_sample(0, 0, atSeconds: 0)),
        PositionReportReason.firstFix,
      );
    });

    test('a fix short of the threshold is withheld, and 18 m of travel '
        'reports', () {
      final gate = PositionReportGate();
      gate.consider(_sample(0, 0, atSeconds: 0, speed: 10));

      expect(gate.consider(_sample(0, 9, atSeconds: 1, speed: 10)), isNull);
      expect(
        gate.consider(_sample(0, 18, atSeconds: 2, speed: 10)),
        PositionReportReason.movedFarEnough,
      );
      // Measured from the last *reported* position, so the withheld fix has not
      // moved the goalposts, and the accumulator restarts on a report.
      expect(gate.travelledSinceReportMeters, 0);
      expect(
        GeoCalculations.distanceMeters(gate.lastReportedPosition!, _at(0, 18)),
        lessThan(0.1),
      );
    });

    test('travel accumulates across withheld fixes', () {
      final gate = PositionReportGate();
      gate.consider(_sample(0, 0, atSeconds: 0, speed: 10));
      gate.consider(_sample(0, 10, atSeconds: 1, speed: 10));

      // 10 m plus 10 m of travel, but only 14.1 m of displacement, because the
      // second leg turns east. Travel is what fires; a displacement threshold
      // would not have, and that difference is what the hairpin exposed.
      expect(
        gate.consider(_sample(10, 10, atSeconds: 2, speed: 10)),
        PositionReportReason.movedFarEnough,
      );
    });

    test('travel alone is not enough — the rider has to end up somewhere', () {
      final gate = PositionReportGate();
      gate.consider(_sample(0, 0, atSeconds: 0, speed: 10));

      // 9 m out and 9 m back: 18 m of travel, no displacement, and nothing
      // whatsoever to report.
      expect(gate.consider(_sample(0, 9, atSeconds: 1, speed: 10)), isNull);
      expect(gate.consider(_sample(0, 0, atSeconds: 2, speed: 10)), isNull);
      expect(gate.travelledSinceReportMeters, closeTo(18, 0.2));
    });

    test('a withheld fix off the line between reports forces a report', () {
      final gate = PositionReportGate();
      gate.consider(_sample(0, 0, atSeconds: 0, speed: 10));
      // A dog-leg round an obstruction: 16 m of travel, short of the threshold,
      // but this fix sits 6 m east of the line the trail would be drawn along if
      // it were dropped.
      expect(gate.consider(_sample(6, 4, atSeconds: 1, speed: 10)), isNull);

      expect(
        gate.consider(_sample(0, 11, atSeconds: 2, speed: 10)),
        PositionReportReason.changedShape,
      );
    });

    test('a withheld fix on the line between reports does not', () {
      final gate = PositionReportGate();
      gate.consider(_sample(0, 0, atSeconds: 0, speed: 10));
      // 2 m off a straight run: inside the tolerance the renderer would simplify
      // away anyway, so reporting it would buy nothing.
      expect(gate.consider(_sample(2, 8, atSeconds: 1, speed: 10)), isNull);
      expect(gate.consider(_sample(0, 15, atSeconds: 2, speed: 10)), isNull);
    });

    test('the shape tolerance is the renderer’s own tolerance', () {
      // Reporting and drawing have to agree about what "close enough" means, or
      // one of them is wasting the other's work (#165).
      expect(
        PositionReportPolicy().shapeToleranceMeters,
        TrailDisplaySimplifier.defaultToleranceMeters,
      );
    });

    test('GPS wander on a stationary phone produces no movement report', () {
      // The measured failure this guards. Wander accumulates travel indefinitely
      // while going nowhere and produces large, random direction changes; the
      // platform reporting a speed of about zero is what settles it.
      final gate = PositionReportGate()
        ..consider(_sample(0, 0, atSeconds: 0, speed: 13));
      final reasons = <PositionReportReason>[];

      for (var second = 1; second <= 60; second += 1) {
        final angle = second * 1.9;
        final reason = gate.consider(
          _sample(
            10 * math.cos(angle),
            10 * math.sin(angle),
            atSeconds: second,
            speed: 0,
          ),
        );
        if (reason != null) reasons.add(reason);
      }

      // Whatever comes out is a keep-alive, never a claim of movement — even at
      // a 10 m wander radius, which is well beyond what a 5 m-accuracy fix
      // should show.
      expect(reasons.where((reason) => reason.isMovement), isEmpty);
      expect(reasons.length, 4);
    });

    test('a fix with no speed is still allowed to be movement', () {
      // Older platforms and some simulators supply no speed. Refusing those
      // fixes would stop a whole platform reporting at all, so they fall back to
      // the displacement guard.
      final gate = PositionReportGate();
      gate.consider(_sample(0, 0, atSeconds: 0));
      gate.consider(_sample(0, 9, atSeconds: 1));

      expect(
        gate.consider(_sample(0, 18, atSeconds: 2)),
        PositionReportReason.movedFarEnough,
      );
    });

    test('the keep-alive reports a stationary rider on the timer alone', () {
      final gate = PositionReportGate()..consider(_sample(0, 0, atSeconds: 0));
      final reasons = <PositionReportReason>[];

      // A phone that has not moved a metre for two minutes.
      for (var second = 1; second <= 120; second += 1) {
        final reason = gate.consider(_sample(0, 0, atSeconds: second));
        if (reason != null) reasons.add(reason);
      }

      expect(reasons, everyElement(PositionReportReason.keepAlive));
      // 15 s apart, so eight in two minutes: presence never depends on movement,
      // and the rate does not depend on it either.
      expect(reasons.length, 8);
      expect(reasons.first.isMovement, isFalse);
    });

    test('the keep-alive stays inside the thresholds it must not cross', () {
      const policy = PositionReportPolicy();
      const deviation = RouteDeviationConfig();
      const freshness = PresenceFreshnessPolicy();

      // A position older than `staleAfter` is reported as "no recent GPS
      // position", and at `coordinatorStaleAfter` it escalates to the
      // coordinators. A rider standing still with a working receiver must never
      // produce either.
      expect(policy.keepAliveAfter, lessThan(deviation.staleAfter));
      expect(policy.keepAliveAfter, lessThan(deviation.coordinatorStaleAfter));
      // Under `liveWithin`, so a stationary rider's marker stays "Live" instead
      // of flickering to "Ageing" between keep-alives.
      expect(policy.keepAliveAfter, lessThan(freshness.liveWithin));
      // And far enough inside the membership reducer's `inactiveAfter` that
      // several consecutive missed keep-alives still do not describe a present
      // rider as absent.
      expect(policy.keepAliveAfter * 7, lessThan(const Duration(minutes: 2)));
    });

    test('the threshold sits strictly between one and two platform filters', () {
      const policy = PositionReportPolicy();
      // The platform filter, from `DeviceLocationSource`.
      const platformFilter = 10.0;

      // Above one filter, or the app is not thinning anything. Strictly below
      // two, or the threshold lands on a delivery boundary and slips to the
      // third fix — which is the measured difference between a 3.2 m and a 6.9 m
      // error on a 30 m hairpin.
      expect(policy.distanceMeters, greaterThan(platformFilter));
      expect(policy.distanceMeters, lessThan(2 * platformFilter));
      expect(policy.minimumDisplacementMeters, lessThan(policy.distanceMeters));
    });

    test('an out-of-order fix cannot rewind the baseline', () {
      final gate = PositionReportGate()
        ..consider(_sample(0, 0, atSeconds: 0))
        ..consider(_sample(0, 40, atSeconds: 4, speed: 10));

      expect(gate.consider(_sample(0, 20, atSeconds: 2, speed: 10)), isNull);
      expect(gate.lastReportedAt, _time(4));
    });

    test('a reset makes the next fix report, because a gap is not travel', () {
      final gate = PositionReportGate()..consider(_sample(0, 0, atSeconds: 0));
      expect(gate.consider(_sample(0, 5, atSeconds: 1, speed: 10)), isNull);

      gate.reset();

      expect(
        gate.consider(_sample(0, 5, atSeconds: 2, speed: 10)),
        PositionReportReason.firstFix,
      );
    });
  });

  group('measured position-report volume', () {
    // The input to every measurement below is the platform fix stream, modelled
    // as `DeviceLocationSource` configures it: a fix every 10 m of travel, and —
    // for a stationary phone whose receiver wanders enough to keep the OS
    // delivering — a fix a second. That input model is a stated assumption, not
    // a field capture, and these numbers are only as good as it is.
    //
    // "Before" is one durable `riderLocationUpdated` event per platform fix,
    // which is what this code did prior to the change.

    test('a stationary rider drops from 300 events to 20 over five '
        'minutes', () {
      final fixes = _stationaryFixes(seconds: 300);

      expect(fixes.length, 300);
      expect(_reportCount(fixes), 20);
      // 15 s of keep-alive across five minutes and nothing else said: 93% fewer
      // durable events for the case the field report was about.
      expect(_savedFraction(fixes), closeTo(0.93, 0.005));
    });

    test('a stationary rider costs the same whatever the receiver does', () {
      // The saving must not depend on how badly the receiver wanders, or a phone
      // with a poor view of the sky pays for it.
      for (final wander in [3.0, 6.0, 10.0]) {
        expect(
          _reportCount(_stationaryFixes(seconds: 300, wander: wander)),
          20,
          reason: 'wander radius $wander m',
        );
      }
    });

    test('a town leg at 30 km/h halves the events', () {
      final fixes = _fixesAlong(_straight(metres: 2000), speed: 8.33);

      expect(fixes.length, 200);
      expect(_reportCount(fixes), 100);
    });

    test('a twisty road at 47 km/h also halves them', () {
      final fixes = _fixesAlong(_hairpins(count: 40), speed: 13);

      expect(fixes.length, 351);
      expect(_reportCount(fixes), 176);
      expect(_savedFraction(fixes), closeTo(0.50, 0.01));
    });

    test(
      'a fast A-road leg is unchanged, because the fixes are already 25 m apart',
      () {
        // At 25 m/s the platform's 10 m filter is not the binding constraint;
        // its ~1 Hz delivery is, and every delivered fix is already past 18 m.
        // This is the honest limit of the change: at speed it saves nothing.
        final fixes = _fixesAtInterval(
          _straight(metres: 5000),
          speed: 25,
          interval: const Duration(seconds: 1),
        );

        expect(fixes.length, 200);
        expect(_reportCount(fixes), 200);
        expect(_savedFraction(fixes), 0);
      },
    );

    test('a mixed ride hour saves about 40% of the durable events', () {
      // 20 minutes of A-road at 25 m/s, 20 minutes of town at 8.33 m/s, 10
      // minutes of twisty road at 13 m/s, 10 minutes stopped.
      final fixes = <LocationSample>[
        ..._fixesAtInterval(
          _straight(metres: 30000),
          speed: 25,
          interval: const Duration(seconds: 1),
        ),
        ..._fixesAlong(_straight(metres: 10000), speed: 8.33, fromSecond: 1200),
        ..._fixesAlong(_hairpins(count: 60), speed: 13, fromSecond: 2400),
        ..._stationaryFixes(seconds: 600, fromSecond: 3000),
      ];

      expect(fixes.length, 3325);
      expect(_reportCount(fixes), 2003);
      expect(_savedFraction(fixes), closeTo(0.40, 0.01));
    });

    test('the payload, not just the count, is what shrinks', () {
      // A signed `riderLocationUpdated` event is roughly 480 bytes on the wire
      // once the location payload, the event envelope and the signature are
      // counted. Stated in bytes because bytes are what the issue asks about.
      const bytesPerEvent = 480;
      final stationary = _stationaryFixes(seconds: 3600);

      // 1.73 MB an hour down to 0.12 MB an hour for a phone that is not moving.
      expect(stationary.length * bytesPerEvent, 1728000);
      expect(_reportCount(stationary) * bytesPerEvent, 115200);
    });
  });

  group('trail fidelity', () {
    test('a travel threshold is what holds a 30 m hairpin', () {
      // The measured failure this guards. Reporting on straight-line
      // displacement let the chord overshoot and cut the bend by 16 m; reporting
      // on distance travelled keeps the error inside the tolerance the renderer
      // already applies.
      final path = _hairpins(count: 6);

      final deviation = _maximumDeviationMeters(
        path,
        _reportedPositions(_fixesAlong(path, speed: 13)),
      );

      expect(deviation, closeTo(3.2, 0.2));
      expect(
        deviation,
        lessThan(TrailDisplaySimplifier.defaultToleranceMeters),
      );
    });

    test('20 m lands on the platform filter boundary and 18 m does not', () {
      // The measurement that chose the threshold, kept so nobody rounds it back
      // up to the number in the original request. At 20 m the accumulator
      // reaches 19.8 m after two 10 m fixes and slips to the third, so the
      // reported chord becomes 30 m — the whole diameter of a 15 m-radius bend.
      final path = _hairpins(count: 6);
      final fixes = _fixesAlong(path, speed: 13);

      final at18 = _maximumDeviationMeters(path, _reportedPositions(fixes));
      final at20 = _maximumDeviationMeters(
        path,
        _reportedPositions(
          fixes,
          policy: const PositionReportPolicy(distanceMeters: 20),
        ),
      );

      expect(at20, greaterThan(TrailDisplaySimplifier.defaultToleranceMeters));
      expect(at20, closeTo(6.9, 0.3));
      expect(at18, lessThan(at20));
      // And 18 m costs nothing for the fidelity it buys: on a straight town leg
      // both report exactly half the fixes, because both sit between one and two
      // platform filters.
      final town = _fixesAlong(_straight(metres: 2000), speed: 8.33);
      expect(_reportCount(town), 100);
      expect(
        _reportCount(
          town,
          policy: const PositionReportPolicy(distanceMeters: 20),
        ),
        100,
      );
    });

    test('the simplifier does not undo the fidelity the threshold kept', () {
      // Sparser reports must not push the drawn trail past the renderer's own
      // tolerance once simplification has also had its say (#100, #165).
      final path = _hairpins(count: 6);
      final reported = _reportedPositions(_fixesAlong(path, speed: 13));

      final drawn = const TrailDisplaySimplifier().simplify([
        for (final point in reported)
          route_domain.GeoPoint(
            latitude: point.latitude,
            longitude: point.longitude,
          ),
      ]);

      expect(
        _maximumDeviationMeters(path, [
          for (final point in drawn)
            GeoPoint(latitude: point.latitude, longitude: point.longitude),
        ]),
        lessThan(2 * TrailDisplaySimplifier.defaultToleranceMeters),
      );
    });

    test('a long twisty road keeps more trail in the same memory', () {
      // `RiderTrailRecorder` keeps 120 points per rider. Measured on 40
      // hairpins, those 120 points hold 1,181 m of raw platform fixes and
      // 2,300 m of reported positions, so the sparser stream buys roughly twice
      // the visible trail rather than a worse one.
      final path = _hairpins(count: 40);
      final fixes = _fixesAlong(path, speed: 13);

      expect(_pathLengthMeters(_lastPositions(fixes, 120)), closeTo(1181, 40));
      expect(
        _pathLengthMeters(_lastPositions(_reportedSamples(fixes), 120)),
        closeTo(2300, 60),
      );
    });
  });

  group('off-course detection', () {
    // The interaction, stated rather than assumed. `samplesToConfirmOffRoute` is
    // 3, so confirmation used to take three fixes at whatever rate the platform
    // delivered them — including three fixes of the same place in stopped
    // traffic. It now takes three *reported* positions: slower in seconds at low
    // speed, and a stronger piece of evidence, because the three samples are
    // 18 m apart rather than 3 m apart.
    test('a wrong turn is still confirmed, and the added latency is '
        'measured', () {
      final route = _straight(metres: 2000);
      final path = _wrongTurnPath();

      final before = _confirmOffRoute(route, _fixesAlong(path, speed: 13));
      final after = _confirmOffRoute(
        route,
        _reportedSamples(_fixesAlong(path, speed: 13)),
      );

      // Measured at 13 m/s (about 30 mph): 33.9 s and 440 m before, 35.4 s and
      // 454 m after. `enterOffRouteMeters` (120 m) dominates confirmation, not
      // the sample rate, so the cost of the change is 1.5 s and 14 m.
      expect(before.confirmed, isTrue);
      expect(after.confirmed, isTrue);
      expect(
        after.confirmedAfter - before.confirmedAfter,
        lessThan(const Duration(seconds: 2)),
      );
      expect(
        after.confirmedAfterMeters - before.confirmedAfterMeters,
        lessThan(20),
      );
    });

    test('a stationary rider off the route is confirmed by keep-alives '
        'alone', () {
      final route = _straight(metres: 2000);
      // Parked 300 m off the route and not moving: the only samples are
      // keep-alives, and they still have to reach a verdict.
      final fixes = _stationaryFixes(seconds: 120, east: 300);

      final outcome = _confirmOffRoute(route, _reportedSamples(fixes));

      // Nothing pretends the rider has stopped reporting: `gpsStale` never
      // fires, because the keep-alive refreshes the position well inside the
      // 30 s staleness window.
      expect(outcome.confirmed, isTrue);
      expect(outcome.sawGpsStale, isFalse);
      // Three samples at 15 s. Slower than three 1 Hz fixes, and this is the
      // trade: a parked rider off the route is flagged in tens of seconds rather
      // than a few.
      expect(outcome.confirmedAfter, const Duration(seconds: 30));
    });

    test('without the keep-alive a parked rider is reported as having no '
        'GPS', () {
      final route = _straight(metres: 2000);
      final fixes = _stationaryFixes(seconds: 120, east: 300);

      // The regression the keep-alive exists to prevent, kept as a test so the
      // coupling between the keep-alive interval and `staleAfter` cannot be
      // broken silently. Evaluated the way the ride shell does it — the newest
      // reported position, re-assessed on a 15 s timer — because that is what
      // produces the "No recent GPS position is available" alarm.
      final withKeepAlive = _refreshStaleness(route, _reportedSamples(fixes));
      final withoutKeepAlive = _refreshStaleness(
        route,
        _reportedSamples(
          fixes,
          policy: const PositionReportPolicy(
            keepAliveAfter: Duration(hours: 1),
          ),
        ),
      );

      expect(withKeepAlive, isFalse);
      expect(withoutKeepAlive, isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// A local metre frame around a point in the West Country, so a path can be
// described in metres and measured in metres.
// ---------------------------------------------------------------------------

const _originLatitude = 51.5;
const _originLongitude = -2.4;
const _metresPerDegreeLatitude = 111132.0;
final _metresPerDegreeLongitude =
    _metresPerDegreeLatitude * math.cos(_originLatitude * math.pi / 180);
final _epoch = DateTime.utc(2026, 7, 27, 10);

GeoPoint _at(double east, double north) => GeoPoint(
  latitude: _originLatitude + north / _metresPerDegreeLatitude,
  longitude: _originLongitude + east / _metresPerDegreeLongitude,
);

DateTime _time(num seconds) =>
    _epoch.add(Duration(milliseconds: (seconds * 1000).round()));

LocationSample _sample(
  double east,
  double north, {
  required num atSeconds,
  double accuracyMeters = 5,
  double? speed,
}) => LocationSample(
  position: _at(east, north),
  recordedAt: _time(atSeconds),
  accuracyMeters: accuracyMeters,
  speedMetersPerSecond: speed,
);

/// A straight northward path, sampled every metre.
List<GeoPoint> _straight({required int metres}) => [
  for (var north = 0; north <= metres; north += 1) _at(0, north.toDouble()),
];

/// [count] consecutive 180-degree bends of 15 m radius — a 30 m hairpin, the
/// tightest case the field report names — joined by 40 m straights, sampled
/// about every metre of arc.
List<GeoPoint> _hairpins({required int count}) {
  const radius = 15.0;
  const straight = 40.0;
  final points = <GeoPoint>[];
  var north = 0.0;
  var east = 0.0;
  var heading = 1.0; // +1 northbound, -1 southbound.
  for (var bend = 0; bend < count; bend += 1) {
    for (var step = 0; step < straight; step += 1) {
      points.add(_at(east, north));
      north += heading;
    }
    final centreEast = east + radius;
    final steps = (math.pi * radius).round();
    for (var step = 0; step <= steps; step += 1) {
      final angle = math.pi * step / steps;
      points.add(
        _at(
          centreEast - radius * math.cos(angle),
          north + heading * radius * math.sin(angle),
        ),
      );
    }
    east = centreEast + radius;
    heading = -heading;
  }
  for (var step = 0; step < straight; step += 1) {
    points.add(_at(east, north));
    north += heading;
  }
  return points;
}

/// A rider who follows the route for 300 m and then turns 90 degrees off it.
List<GeoPoint> _wrongTurnPath() => [
  for (var north = 0; north <= 300; north += 1) _at(0, north.toDouble()),
  for (var east = 1; east <= 400; east += 1) _at(east.toDouble(), 300),
];

/// The platform fix stream for [path]: one fix per [distanceFilter] metres of
/// travel, timed at [speed] metres a second. This is how `DeviceLocationSource`
/// configures the OS.
List<LocationSample> _fixesAlong(
  List<GeoPoint> path, {
  required double speed,
  double distanceFilter = 10,
  double fromSecond = 0,
}) {
  final fixes = <LocationSample>[];
  var travelled = 0.0;
  var sinceLastFix = 0.0;
  for (var index = 1; index < path.length; index += 1) {
    final step = GeoCalculations.distanceMeters(path[index - 1], path[index]);
    travelled += step;
    sinceLastFix += step;
    if (sinceLastFix < distanceFilter) continue;
    sinceLastFix = 0;
    fixes.add(
      LocationSample(
        position: path[index],
        recordedAt: _time(fromSecond + travelled / speed),
        accuracyMeters: 5,
        speedMetersPerSecond: speed,
      ),
    );
  }
  return fixes;
}

/// The platform fix stream when delivery, not the distance filter, is the
/// binding constraint: a fix per [interval] at [speed].
List<LocationSample> _fixesAtInterval(
  List<GeoPoint> path, {
  required double speed,
  required Duration interval,
  double fromSecond = 0,
}) => _fixesAlong(
  path,
  speed: speed,
  distanceFilter: speed * interval.inMilliseconds / 1000,
  fromSecond: fromSecond,
);

/// A phone that is not moving but whose receiver wanders enough to keep the OS
/// delivering: the pessimistic case, and the one that produced today's duplicate
/// positions.
List<LocationSample> _stationaryFixes({
  required int seconds,
  double fromSecond = 0,
  double east = 0,
  double north = 0,
  double wander = 6,
}) => [
  for (var second = 0; second < seconds; second += 1)
    _sample(
      east + wander * math.cos(second * 1.9),
      north + wander * math.sin(second * 1.9),
      atSeconds: fromSecond + second,
      speed: 0,
    ),
];

List<LocationSample> _reportedSamples(
  List<LocationSample> fixes, {
  PositionReportPolicy policy = const PositionReportPolicy(),
}) {
  final gate = PositionReportGate(policy: policy);
  return [
    for (final fix in fixes)
      if (gate.consider(fix) != null) fix,
  ];
}

List<GeoPoint> _reportedPositions(
  List<LocationSample> fixes, {
  PositionReportPolicy policy = const PositionReportPolicy(),
}) => [
  for (final sample in _reportedSamples(fixes, policy: policy)) sample.position,
];

int _reportCount(
  List<LocationSample> fixes, {
  PositionReportPolicy policy = const PositionReportPolicy(),
}) => _reportedSamples(fixes, policy: policy).length;

double _savedFraction(
  List<LocationSample> fixes, {
  PositionReportPolicy policy = const PositionReportPolicy(),
}) => 1 - _reportCount(fixes, policy: policy) / fixes.length;

/// The furthest any point of the road the rider actually rode sits from the
/// polyline drawn through [drawn]. This is the visible error of a threshold.
///
/// Only the stretch the trail covers is measured: the path before the first
/// delivered fix precedes the trail's own start, so no threshold can draw it.
double _maximumDeviationMeters(List<GeoPoint> path, List<GeoPoint> drawn) {
  if (drawn.length < 2) return double.infinity;
  final first = path.indexWhere((point) => point == drawn.first);
  final last = path.lastIndexWhere((point) => point == drawn.last);
  var worst = 0.0;
  for (final point in path.sublist(
    first < 0 ? 0 : first,
    (last < 0 ? path.length - 1 : last) + 1,
  )) {
    final distance = GeoCalculations.distanceToPolylineMeters(point, drawn);
    if (distance > worst) worst = distance;
  }
  return worst;
}

double _pathLengthMeters(List<GeoPoint> points) {
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    total += GeoCalculations.distanceMeters(points[index - 1], points[index]);
  }
  return total;
}

List<GeoPoint> _lastPositions(List<LocationSample> samples, int count) {
  final positions = [for (final sample in samples) sample.position];
  return positions.length <= count
      ? positions
      : positions.sublist(positions.length - count);
}

class _OffRouteOutcome {
  const _OffRouteOutcome({
    required this.confirmed,
    required this.confirmedAfter,
    required this.confirmedAfterMeters,
    required this.sawGpsStale,
  });

  final bool confirmed;
  final Duration confirmedAfter;
  final double confirmedAfterMeters;
  final bool sawGpsStale;
}

/// Feeds [samples] to a detector and reports when it confirmed an off-route
/// state, measured from the first sample. `now` is each sample's own timestamp,
/// so the elapsed figures are the rider's clock and nothing else.
_OffRouteOutcome _confirmOffRoute(
  List<GeoPoint> route,
  List<LocationSample> samples,
) {
  final detector = RouteDeviationDetector(route);
  var sawGpsStale = false;
  var travelled = 0.0;
  Duration? confirmedAfter;
  var confirmedAfterMeters = 0.0;
  for (var index = 0; index < samples.length; index += 1) {
    if (index > 0) {
      travelled += GeoCalculations.distanceMeters(
        samples[index - 1].position,
        samples[index].position,
      );
    }
    final assessment = detector.evaluate(
      samples[index],
      samples[index].recordedAt,
    );
    if (assessment.state == RouteTrackingState.gpsStale) sawGpsStale = true;
    if (assessment.state == RouteTrackingState.offRoute &&
        confirmedAfter == null) {
      confirmedAfter = samples[index].recordedAt.difference(
        samples.first.recordedAt,
      );
      confirmedAfterMeters = travelled;
    }
  }
  return _OffRouteOutcome(
    confirmed: confirmedAfter != null,
    confirmedAfter: confirmedAfter ?? const Duration(days: 1),
    confirmedAfterMeters: confirmedAfterMeters,
    sawGpsStale: sawGpsStale,
  );
}

/// Whether the ride shell's own staleness refresh would ever report `gpsStale`.
///
/// The shell re-assesses the newest held position every 15 s rather than only
/// when a fix arrives, which is what turns an ageing position into a visible
/// "No recent GPS position is available" and, at 90 s, a coordinator alert.
bool _refreshStaleness(List<GeoPoint> route, List<LocationSample> reported) {
  if (reported.isEmpty) return false;
  final detector = RouteDeviationDetector(route);
  final until = reported.first.recordedAt.add(const Duration(minutes: 2));
  var now = reported.first.recordedAt;
  var next = 0;
  LocationSample? newest;
  while (!now.isAfter(until)) {
    while (next < reported.length && !reported[next].recordedAt.isAfter(now)) {
      newest = reported[next];
      next += 1;
    }
    if (newest != null &&
        detector.evaluate(newest, now).state == RouteTrackingState.gpsStale) {
      return true;
    }
    now = now.add(const Duration(seconds: 15));
  }
  return false;
}
