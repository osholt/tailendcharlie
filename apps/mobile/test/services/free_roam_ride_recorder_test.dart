import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/free_roam_ride_recorder.dart';

void main() {
  late DateTime now;
  late FreeRoamRideRecorder recorder;

  setUp(() {
    now = DateTime.utc(2026, 8, 23, 9);
    recorder = FreeRoamRideRecorder(
      localDisplayName: 'Oliver',
      clock: () => now,
      idFactory: () => 'test-id',
    );
  });

  test('turns a Where To navigation into an exportable completed ride', () {
    recorder.start(_route('To Tuckers Grave'));
    recorder.record(_point(51.4627, -2.5084, now));
    now = now.add(const Duration(seconds: 10));
    recorder.record(_point(51.4627, -2.5064, now));
    now = now.add(const Duration(minutes: 42));

    final ride = recorder.finish()!;

    expect(ride.rideId, 'free-roam-test-id');
    expect(ride.title, 'To Tuckers Grave');
    expect(ride.localDisplayName, 'Oliver');
    expect(ride.riderCount, 1);
    expect(ride.eventCount, 2);
    expect(ride.duration, const Duration(minutes: 42, seconds: 10));
    expect(ride.plannedRoute?.name, 'To Tuckers Grave');
    expect(ride.traveledRoute?.paths, hasLength(1));
    expect(ride.traveledRoute?.paths.single.points, hasLength(2));
    expect(ride.totalDistanceMeters, greaterThan(100));
    expect(recorder.active, isFalse);
  });

  test('keeps location outages as honest GPX gaps', () {
    recorder.start(_route('A ride with a gap'));
    recorder.record(_point(51.46, -2.50, now));
    now = now.add(const Duration(seconds: 10));
    recorder.record(_point(51.46, -2.499, now));
    // Keep recording this same navigation; the tear in time, not a new start,
    // is what must split the track.
    now = now.add(const Duration(minutes: 3));
    recorder.record(_point(51.48, -2.45, now));
    now = now.add(const Duration(seconds: 10));
    recorder.record(_point(51.48, -2.449, now));

    final ride = recorder.finish()!;

    expect(ride.hasRecordingGaps, isTrue);
    expect(ride.traveledRoute?.paths, hasLength(2));
    expect(
      ride.totalDistanceMeters,
      lessThan(500),
      reason: 'the unknown jump during the outage is not invented as distance',
    );
  });

  test('ignores fixes outside an active navigation', () {
    recorder.record(_point(51.46, -2.50, now));

    expect(recorder.finish(), isNull);
  });
}

ImportedRoute _route(String name) => ImportedRoute(
  id: 'plan',
  name: name,
  importedAt: DateTime.utc(2026, 8, 23),
  sourceFileName: 'where-to.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.route,
      points: [
        GeoPoint(latitude: 51.46, longitude: -2.50),
        GeoPoint(latitude: 51.30, longitude: -2.35),
      ],
    ),
  ],
  waypoints: const [],
);

GeoPoint _point(double latitude, double longitude, DateTime recordedAt) =>
    GeoPoint(latitude: latitude, longitude: longitude, recordedAt: recordedAt);
