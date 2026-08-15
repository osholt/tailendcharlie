import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/carplay_tec_status.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/tec_gap_trend.dart';

void main() {
  final now = DateTime.utc(2026, 8, 2, 12);

  RiderLocation tecLocation({
    String riderId = 'bill',
    String displayName = 'Bill',
    Duration age = Duration.zero,
  }) => RiderLocation(
    riderId: riderId,
    displayName: displayName,
    role: RideRole.tailEndCharlie,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.45, longitude: -2.58),
      recordedAt: now.subtract(age),
      accuracyMeters: 6,
    ),
    receivedAt: now,
  );

  // The four availability states are the whole point of this type. A car
  // screen that blurs any two of them tells a leader the back is covered when
  // it is not, which is the failure the TEC role exists to prevent.
  test('names the ride with no back-marker rather than staying silent', () {
    final status = CarPlayTecStatus.from(
      target: const TecTarget(availability: TecAvailability.none),
      now: now,
    );

    expect(status.hasRegisteredTec, isFalse);
    expect(status.headline, 'No TEC');
    expect(status.detail, 'Nobody is covering the back');
    expect(status.toSnapshot()['state'], 'none');
  });

  test('separates a TEC who has never reported from one who has', () {
    final status = CarPlayTecStatus.from(
      target: const TecTarget(
        availability: TecAvailability.awaitingLocation,
        riderId: 'bill',
      ),
      now: now,
    );

    expect(status.headline, 'TEC · waiting');
    expect(status.detail, 'Tail End Charlie · waiting for location');
    expect(status.distanceMeters, isNull);
  });

  test('states the age of a fix too old to trust, and withholds the gap', () {
    final status = CarPlayTecStatus.from(
      target: TecTarget(
        availability: TecAvailability.stale,
        riderId: 'bill',
        location: tecLocation(age: const Duration(minutes: 4)),
      ),
      leaderStatus: LeaderRideStatus(
        tecAvailability: TecAvailability.stale,
        tecRiderId: 'bill',
        tecName: 'Bill',
        tecLocationAge: const Duration(minutes: 4),
        offCourseAlerts: const [],
      ),
      now: now,
    );

    expect(status.headline, 'TEC · 4 min ago');
    expect(status.detail, 'Bill · last update 4 min ago');
    expect(status.distanceMeters, isNull);
    expect(status.toSnapshot()['etaSeconds'], isNull);
  });

  test('carries the gap and its trend for a leader, in the rider units', () {
    final status = CarPlayTecStatus.from(
      target: TecTarget(
        availability: TecAvailability.tracking,
        riderId: 'bill',
        location: tecLocation(),
      ),
      leaderStatus: LeaderRideStatus(
        tecAvailability: TecAvailability.tracking,
        tecRiderId: 'bill',
        tecName: 'Bill',
        distanceToTecMeters: 1931,
        estimatedTimeToTec: const Duration(minutes: 3),
        tecLocationAge: Duration.zero,
        offCourseAlerts: const [],
      ),
      trend: TecGapTrend.opening,
      distanceUnit: DistanceUnit.miles,
      now: now,
    );

    expect(status.headline, 'TEC · 1.2 mi · ~3 min ↑');
    expect(status.detail, 'Bill · 1.2 mi · about 3 min · ↑ Opening');
    expect(status.toSnapshot()['trendLabel'], 'Opening');
  });

  // A rider who is not the leader has no gap to state. Reporting "0" or a dash
  // there would read as "the TEC is right behind me".
  test('says the position is current when there is no gap to measure', () {
    final status = CarPlayTecStatus.from(
      target: TecTarget(
        availability: TecAvailability.tracking,
        riderId: 'bill',
        location: tecLocation(),
      ),
      now: now,
    );

    expect(status.headline, 'TEC · reporting');
    expect(status.detail, 'Bill · position current');
    expect(status.distanceMeters, isNull);
  });

  // The tracker and the leader status update on different frames. A gap
  // measured to the previous back-marker must never be shown against the new
  // one's name.
  test('ignores a leader status describing a different rider', () {
    final status = CarPlayTecStatus.from(
      target: TecTarget(
        availability: TecAvailability.tracking,
        riderId: 'dave',
        location: tecLocation(riderId: 'dave', displayName: 'Dave'),
      ),
      leaderStatus: LeaderRideStatus(
        tecAvailability: TecAvailability.tracking,
        tecRiderId: 'bill',
        tecName: 'Bill',
        distanceToTecMeters: 1931,
        estimatedTimeToTec: const Duration(minutes: 3),
        offCourseAlerts: const [],
      ),
      trend: TecGapTrend.opening,
      now: now,
    );

    expect(status.name, 'Dave');
    expect(status.distanceMeters, isNull);
    expect(status.trend, TecGapTrend.unknown);
    expect(status.detail, 'Dave · position current');
  });
}
