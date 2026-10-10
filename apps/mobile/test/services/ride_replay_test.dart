import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/ride_replay.dart';

/// **Replaying a finished ride's own timed track (#305).**
///
/// The model is the part that can be wrong in ways nobody sees on a map: a
/// marker that moves at the wrong pace, a recording gap played as a long
/// stand-still, a fix with no time quietly given one.
void main() {
  final base = DateTime.utc(2026, 10, 4, 9);

  /// One track path per list of `(latitude, longitude, secondsAfterBase)`.
  ImportedRoute route(
    List<List<(double, double, int?)>> paths, {
    DateTime? start,
    RoutePathKind kind = RoutePathKind.track,
  }) => ImportedRoute(
    id: 'ride',
    name: 'Ride',
    importedAt: base,
    sourceFileName: 'ride.gpx',
    paths: [
      for (final path in paths)
        RoutePath(
          kind: kind,
          points: [
            for (final (latitude, longitude, seconds) in path)
              GeoPoint(
                latitude: latitude,
                longitude: longitude,
                recordedAt: seconds == null
                    ? null
                    : (start ?? base).add(Duration(seconds: seconds)),
              ),
          ],
        ),
    ],
    waypoints: const [],
  );

  group('the timeline', () {
    test('has nothing to replay without a timed track', () {
      expect(RideReplayTimeline.fromRoute(null), isNull);
      // Fixes with no times: a ride from before times were kept.
      expect(
        RideReplayTimeline.fromRoute(
          route([
            [(51.0, -2.0, null), (51.1, -2.0, null)],
          ]),
        ),
        isNull,
      );
      // One fix is a point, not a ride.
      expect(
        RideReplayTimeline.fromRoute(
          route([
            [(51.0, -2.0, 0)],
          ]),
        ),
        isNull,
      );
      // A planned route is not a recording, however it is timed.
      expect(
        RideReplayTimeline.fromRoute(
          route([
            [(51.0, -2.0, 0), (51.1, -2.0, 60)],
          ], kind: RoutePathKind.route),
        ),
        isNull,
      );
    });

    test(
      'is as long as the recorded time and starts and ends on the fixes',
      () {
        final timeline = RideReplayTimeline.fromRoute(
          route([
            [(51.0, -2.0, 0), (51.1, -2.0, 60)],
          ]),
        )!;

        expect(timeline.duration, const Duration(seconds: 60));
        expect(timeline.positionAt(Duration.zero).latitude, 51.0);
        expect(timeline.positionAt(const Duration(seconds: 60)).latitude, 51.1);
        // Clamped either side rather than extrapolated off the ride.
        expect(timeline.positionAt(const Duration(seconds: -5)).latitude, 51.0);
        expect(timeline.positionAt(const Duration(hours: 9)).latitude, 51.1);
        expect(
          timeline.positionAt(const Duration(seconds: 30)).latitude,
          closeTo(51.05, 1e-9),
        );
      },
    );

    test('moves by time, not by distance: a slow stretch stays slow', () {
      // 10 s for the first degree, 60 s for the next: the same distance each,
      // very different speeds.
      final timeline = RideReplayTimeline.fromRoute(
        route([
          [(50.0, -2.0, 0), (51.0, -2.0, 10), (52.0, -2.0, 70)],
        ]),
      )!;

      expect(
        timeline.positionAt(const Duration(seconds: 5)).latitude,
        closeTo(50.5, 1e-9),
      );
      expect(
        timeline.positionAt(const Duration(seconds: 10)).latitude,
        closeTo(51.0, 1e-9),
      );
      expect(
        timeline.positionAt(const Duration(seconds: 40)).latitude,
        closeTo(51.5, 1e-9),
      );
    });

    test('skips a recording gap instead of playing it as a stand-still', () {
      // An hour of nothing between two runs. The replay is the 90 s that was
      // recorded, and the second run starts where the first one's time ends.
      final timeline = RideReplayTimeline.fromRoute(
        route([
          [(51.0, -2.0, 0), (51.1, -2.0, 60)],
          [(52.0, -2.0, 3660), (52.1, -2.0, 3690)],
        ]),
      )!;

      expect(timeline.duration, const Duration(seconds: 90));
      expect(timeline.skippedGaps, 1);
      expect(
        timeline.positionAt(const Duration(seconds: 59)).latitude,
        lessThan(51.2),
      );
      expect(
        timeline.positionAt(const Duration(seconds: 75)).latitude,
        closeTo(52.05, 1e-9),
      );
      // The clock of the day jumps with it, so a time label stays true.
      expect(
        timeline.clockTimeAt(const Duration(seconds: 75)),
        base.add(const Duration(seconds: 3675)),
      );
      expect(
        timeline.clockTimeAt(const Duration(seconds: 30)),
        base.add(const Duration(seconds: 30)),
      );
    });

    test('ignores a fix whose time does not move forward', () {
      final timeline = RideReplayTimeline.fromRoute(
        route([
          [
            (51.0, -2.0, 0),
            (51.2, -2.0, 20),
            (50.0, -9.0, 10),
            (51.4, -2.0, 40),
          ],
        ]),
      )!;

      expect(timeline.duration, const Duration(seconds: 40));
      // The out-of-order fix at 10 s is dropped, so 30 s is between 20 and 40.
      expect(
        timeline.positionAt(const Duration(seconds: 30)).latitude,
        closeTo(51.3, 1e-9),
      );
    });
  });

  group('the controller', () {
    RideReplayController controller({double speed = 60}) =>
        RideReplayController(
          RideReplayTimeline.fromRoute(
            route([
              [(51.0, -2.0, 0), (52.0, -2.0, 3600)],
            ]),
          )!,
          speed: speed,
        );

    test('advances only while playing, at the chosen speed', () {
      final replay = controller();
      addTearDown(replay.dispose);

      replay.advance(const Duration(seconds: 1));
      expect(replay.position, Duration.zero, reason: 'paused');

      replay.play();
      replay.advance(const Duration(seconds: 1));
      expect(replay.position, const Duration(seconds: 60));

      replay.setSpeed(120);
      replay.advance(const Duration(seconds: 1));
      expect(replay.position, const Duration(seconds: 180));

      replay.pause();
      replay.advance(const Duration(seconds: 10));
      expect(replay.position, const Duration(seconds: 180));
    });

    test('stops at the end and plays again from the start', () {
      final replay = controller();
      addTearDown(replay.dispose);

      replay.play();
      replay.advance(const Duration(seconds: 120));
      expect(replay.finished, isTrue);
      expect(replay.playing, isFalse);
      expect(replay.position, const Duration(hours: 1));
      expect(replay.location.latitude, 52.0);

      replay.play();
      expect(replay.position, Duration.zero);
      expect(replay.playing, isTrue);
    });

    test('scrubbing moves the marker, clamps, and leaves playback alone', () {
      final replay = controller();
      addTearDown(replay.dispose);

      replay.seekToFraction(0.5);
      expect(replay.position, const Duration(minutes: 30));
      expect(replay.location.latitude, closeTo(51.5, 1e-9));
      expect(replay.playing, isFalse);

      replay.seek(const Duration(hours: 5));
      expect(replay.position, const Duration(hours: 1));
      replay.seek(const Duration(seconds: -1));
      expect(replay.position, Duration.zero);

      replay.play();
      replay.seekToFraction(0.25);
      expect(
        replay.playing,
        isTrue,
        reason: 'scrubbing while playing keeps playing',
      );
    });

    test('speed must be positive, and listeners hear only real changes', () {
      final replay = controller();
      addTearDown(replay.dispose);
      var heard = 0;
      replay.addListener(() => heard += 1);

      replay.setSpeed(0);
      replay.setSpeed(-3);
      replay.setSpeed(60);
      expect(replay.speed, 60);
      expect(heard, 0);

      replay.setSpeed(10);
      expect(replay.speed, 10);
      expect(heard, 1);
    });
  });
}
