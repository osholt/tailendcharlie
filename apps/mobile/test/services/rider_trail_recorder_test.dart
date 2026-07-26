import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/rider_trail_recorder.dart';

/// Regression cover for #100: a rider's travelled trail is recorded from
/// position history alone, so it survives leaving the planned route, having no
/// planned route, and an app restart mid-ride.
void main() {
  test('records a trail for a leader who has ridden off the planned route', () {
    final recorder = RiderTrailRecorder();

    final trails = recorder.update([
      _update('leader', _point(0, 0), isLeader: true),
    ]);
    final later = recorder.update([
      // Kilometres away from any plan, and still not flagged off route because
      // the leader's own trail counts as a valid route.
      _update('leader', _point(0.02, 0.02), isLeader: true),
    ]);

    expect(trails.single.isRenderable, isFalse);
    expect(later.single.kind, RiderTrailKind.leader);
    expect(later.single.points, hasLength(2));
    expect(later.single.isRenderable, isTrue);
  });

  test('records a trail for a follower flagged off route', () {
    final recorder = RiderTrailRecorder();

    recorder.update([_update('sam', _point(0, 0))]);
    final trails = recorder.update([
      _update('sam', _point(0.01, 0), isOffRoute: true),
    ]);

    expect(trails.single.kind, RiderTrailKind.offRoute);
    expect(trails.single.points, hasLength(2));
  });

  test('records trails when no route has been imported at all', () {
    final recorder = RiderTrailRecorder();

    recorder.update([
      _update('leader', _point(0, 0), isLeader: true),
      _update('sam', _point(0.1, 0)),
    ]);
    final trails = recorder.update([
      _update('leader', _point(0, 0.01), isLeader: true),
      _update('sam', _point(0.1, 0.01)),
    ]);

    expect(trails, hasLength(2));
    expect(trails.every((trail) => trail.isRenderable), isTrue);
    expect(trails.map((trail) => trail.kind), [
      RiderTrailKind.leader,
      RiderTrailKind.rider,
    ]);
  });

  test('an excursion and rejoin stay one continuous trail', () {
    final recorder = RiderTrailRecorder();
    final route = [
      _point(0, 0),
      _point(0, 0.001),
      _point(0, 0.002),
      _point(0, 0.003),
    ];
    final excursion = [_point(0.01, 0.0015), _point(0.012, 0.002)];

    // On route, off route, then back on route: the alert state changes, the
    // recorded history does not restart.
    for (final point in route.take(2)) {
      recorder.update([_update('sam', point)]);
    }
    for (final point in excursion) {
      recorder.update([_update('sam', point, isOffRoute: true)]);
    }
    final rejoined = recorder.update([
      _update('sam', route[2], isOffRoute: true),
    ]);
    final settled = recorder.update([_update('sam', route[3])]);

    expect(rejoined.single.kind, RiderTrailKind.offRoute);
    expect(settled.single.kind, RiderTrailKind.rider);
    expect(settled.single.points, hasLength(6));
    expect(settled.single.points.first.latitude, 0);
    expect(settled.single.points[2].latitude, closeTo(0.01, 1e-9));
    expect(settled.single.points.last.longitude, closeTo(0.003, 1e-9));
  });

  test('journal history restores a trail after an app restart mid-ride', () {
    // A restart starts with an empty recorder; the leader's history is replayed
    // from the durable journal instead.
    final recorder = RiderTrailRecorder();
    final journal = [_point(0, 0), _point(0, 0.001), _point(0, 0.002)];

    final restored = recorder.update([
      _update(
        'leader',
        _point(0, 0.003),
        isLeader: true,
        journalTrail: journal,
      ),
    ]);
    final live = recorder.update([
      _update('leader', _point(0, 0.004), isLeader: true),
    ]);

    expect(restored.single.points, hasLength(3));
    expect(restored.single.isRenderable, isTrue);
    // Once this device has recorded more than the journal replayed, its own
    // history wins, so the trail keeps extending rather than jumping back.
    expect(live.single.points.length, greaterThanOrEqualTo(2));
    expect(live.single.points.last.longitude, closeTo(0.004, 1e-9));
  });

  test('bounds every rider identically, including the local rider', () {
    final recorder = RiderTrailRecorder(maximumPointsPerRider: 4);

    for (var index = 0; index < 10; index += 1) {
      recorder.update([
        _update('me', _point(0, index * 0.001)),
        _update('leader', _point(0.05, index * 0.001), isLeader: true),
      ]);
    }

    expect(recorder.trailFor('me'), hasLength(4));
    expect(recorder.trailFor('leader'), hasLength(4));
    expect(
      recorder.trailFor('me').first.longitude,
      closeTo(0.006, 1e-9),
      reason: 'the oldest points are dropped, not the newest',
    );
    expect(
      RiderTrailRecorder.defaultMaximumPointsPerRider,
      120,
      reason: 'the documented per-rider bound',
    );
  });

  test('bounds a journal trail with the same cap', () {
    final recorder = RiderTrailRecorder(maximumPointsPerRider: 3);

    final trails = recorder.update([
      _update(
        'leader',
        _point(0, 0.01),
        isLeader: true,
        journalTrail: [
          for (var index = 0; index < 40; index += 1) _point(0, index * 0.0001),
        ],
      ),
    ]);

    expect(trails.single.points, hasLength(3));
  });

  test('ignores repeated and out-of-order fixes', () {
    final recorder = RiderTrailRecorder();
    final start = DateTime.utc(2026, 7, 25, 9);

    recorder.record(
      riderId: 'sam',
      point: _point(0, 0, recordedAt: start),
    );
    recorder.record(
      riderId: 'sam',
      point: _point(0, 0, recordedAt: start),
    );
    recorder.record(
      riderId: 'sam',
      point: _point(
        0,
        0.001,
        recordedAt: start.add(const Duration(minutes: 2)),
      ),
    );
    final stale = recorder.record(
      riderId: 'sam',
      point: _point(
        0,
        0.0005,
        recordedAt: start.add(const Duration(minutes: 1)),
      ),
    );

    expect(stale, isTrue, reason: 'a late fix is inserted in recorded order');
    expect(recorder.trailFor('sam'), hasLength(3));
    expect(recorder.trailFor('sam')[1].longitude, closeTo(0.0005, 1e-9));
    expect(recorder.trailFor('sam').last.longitude, closeTo(0.001, 1e-9));
  });

  test('drops history for a rider who is no longer eligible', () {
    final recorder = RiderTrailRecorder();

    recorder.update([_update('guest', _point(0, 0))]);
    recorder.update([_update('guest', _point(0, 0.001))]);
    final trails = recorder.update([
      _update('guest', _point(0, 0.002), isEligible: false),
    ]);

    expect(trails, isEmpty);
    expect(recorder.trailFor('guest'), isEmpty);
  });

  test('the leader kind wins over an off-route flag', () {
    expect(
      RiderTrailRecorder.kindFor(isLeader: true, isOffRoute: true),
      RiderTrailKind.leader,
    );
    expect(
      RiderTrailRecorder.kindFor(isLeader: false, isOffRoute: true),
      RiderTrailKind.offRoute,
    );
    expect(
      RiderTrailRecorder.kindFor(isLeader: false, isOffRoute: false),
      RiderTrailKind.rider,
    );
  });
}

GeoPoint _point(double latitude, double longitude, {DateTime? recordedAt}) =>
    GeoPoint(latitude: latitude, longitude: longitude, recordedAt: recordedAt);

RiderTrailUpdate _update(
  String riderId,
  GeoPoint position, {
  bool isLeader = false,
  bool isOffRoute = false,
  bool isEligible = true,
  List<GeoPoint>? journalTrail,
}) => RiderTrailUpdate(
  riderId: riderId,
  displayName: riderId,
  position: position,
  isLeader: isLeader,
  isOffRoute: isOffRoute,
  isEligible: isEligible,
  journalTrail: journalTrail,
);
