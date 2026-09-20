import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/eta_calibration.dart';
import 'package:ride_relay/services/ride_timing_analysis.dart';

void main() {
  test('long nearby gap is a probable break; short traffic stops remain', () {
    final points = [
      point(0, 0),
      point(.001, 60),
      point(.001, 180),
      point(.002, 240),
      point(.0035, 1440),
      point(.01, 1500),
    ];
    final timing = RideTimingAnalysis.fromRoute(route(points))!;
    expect(timing.elapsed, const Duration(minutes: 25));
    expect(timing.probableBreaks, const Duration(minutes: 20));
    expect(timing.travelling, const Duration(minutes: 5));
    expect(timing.observedBreaks, Duration.zero);
  });
  test('observed lunch dwell removed; a moving GPS outage stays uncertain', () {
    final points = [
      point(0, 0),
      for (var i = 1; i <= 12; i++)
        point(.01 + (i.isEven ? .00001 : 0), i * 60),
      point(.04, 1320),
      point(.05, 1380),
    ];
    final timing = RideTimingAnalysis.fromRoute(route(points))!;
    expect(timing.observedBreaks, const Duration(minutes: 11));
    expect(timing.unknownGaps, const Duration(minutes: 10));
    expect(timing.reliable, isFalse);
  });
  test('three matching completed rides start bounded median learning', () {
    final rides = [for (var i = 0; i < 3; i++) calibrationRide('$i')];
    final plan = rides.first.plannedRoute!;
    expect(EtaCalibration.fromRides(rides.take(2)).factorFor(plan), 1);
    final result = EtaCalibration.fromRides(rides);
    expect(result.sampleCount, 3);
    expect(result.factorFor(plan), closeTo(.94545, .0001));
    expect(result.anonymousProfile, {'mixed': .8});
    expect(result.factorFor(plan, populationFactor: .9), closeTo(.8727, .0001));
    // Replaying one archive does not count as three independent rides.
    expect(
      EtaCalibration.fromRides([
        rides.first,
        rides.first,
        rides.first,
      ]).factorFor(plan),
      1,
    );
  });
  test(
    'detours, partial recordings, insufficient timing and reset excluded',
    () {
      final good = calibrationRide('good');
      final wrongCorridor = calibrationRide('detour', detour: true);
      final partial = CompletedRide.fromJson({
        ...good.toJson(),
        'rideId': 'partial',
        'recordingComplete': false,
      });
      final gaps = calibrationRide('outage', gap: true);
      expect(
        EtaCalibration.fromRides([
          good,
          wrongCorridor,
          partial,
          gaps,
        ]).sampleCount,
        1,
      );
      expect(
        EtaCalibration.fromRides([good], since: good.endedAt).sampleCount,
        0,
      );
    },
  );
  test(
    'old archives retain compatibility; incomplete status survives copies',
    () {
      final data = calibrationRide('ride').toJson()
        ..remove('recordingComplete');
      expect(CompletedRide.fromJson(data).recordingComplete, isTrue);
      data['recordingComplete'] = false;
      expect(
        CompletedRide.fromJson(
          data,
        ).copyWith(libraryName: 'Editing').recordingComplete,
        isFalse,
      );
    },
  );
}

GeoPoint point(double longitude, int seconds, {double latitude = 0}) =>
    GeoPoint(
      latitude: latitude,
      longitude: longitude,
      recordedAt: DateTime.utc(2026).add(Duration(seconds: seconds)),
    );
ImportedRoute route(List<GeoPoint> points, {Duration? duration}) =>
    ImportedRoute(
      id: 'route',
      name: 'Test route',
      importedAt: DateTime.utc(2026),
      sourceFileName: 'test.gpx',
      paths: [RoutePath(kind: RoutePathKind.track, points: points)],
      waypoints: const [],
      plannedDuration: duration,
    );
CompletedRide calibrationRide(
  String id, {
  bool detour = false,
  bool gap = false,
}) {
  final points = [
    for (var i = 0; i <= 120; i++)
      point(
        i / 240,
        i * 24 + (gap && i > 60 ? 900 : 0),
        latitude: detour && i > 1 && i < 119 ? .02 : 0,
      ),
  ];
  return CompletedRide(
    rideId: id,
    rideCode: 'LOCAL',
    rideName: 'Test',
    localDisplayName: 'Rider',
    localRole: RideRole.rider,
    startedAt: points.first.recordedAt!,
    endedAt: points.last.recordedAt!,
    archivedAt: points.last.recordedAt!,
    riderCount: 1,
    eventCount: points.length,
    totalDistanceMeters: 55597,
    markerSessions: const [],
    plannedRoute: route([
      point(0, 0),
      point(.5, 3600),
    ], duration: const Duration(hours: 1)),
    traveledRoute: route(points),
  );
}
