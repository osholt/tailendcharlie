import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/location_sharing_guard.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/sharing_dispersal.dart';

const _metresPerDegree = 111194.9;
const _home = GeoPoint(latitude: 51.5, longitude: -2.5);

GeoPoint _north(double metres) => GeoPoint(
  latitude: _home.latitude + metres / _metresPerDegree,
  longitude: _home.longitude,
);

/// A guard on a fake clock, with every effect it performs recorded.
class _Harness {
  _Harness({SharingDispersalPolicy policy = const SharingDispersalPolicy()}) {
    guard = LocationSharingGuard(
      policy: policy,
      clock: () => now,
      onPause: (reason) async {
        pauses.add(reason);
        // The phase has to be paused before the effect runs, so a fix that
        // arrives while it works is already being refused.
        phaseWhenPaused.add(guard.phase);
      },
      onResume: () async {
        resumes += 1;
        return resumeSucceeds;
      },
    );
    addTearDown(guard.dispose);
  }

  late final LocationSharingGuard guard;
  DateTime now = DateTime.utc(2026, 10, 4, 15);
  final pauses = <SharingPauseReason>[];
  final phaseWhenPaused = <SharingGuardPhase>[];
  int resumes = 0;
  bool resumeSucceeds = true;

  bool groupRide = true;
  List<DispersalPeer> peers = const [];
  bool observable = true;
  DispersalRoute? route;
  DispersalMarkerWait? marker;
  DateTime? ridePausedAt;

  /// The ride is under way: the rider has a fix and the first evaluation has
  /// run, so "dispersed for" starts counting from this instant.
  Future<void> begin() async {
    fix();
    await evaluate();
  }

  /// A fix at [position] taken now.
  void fix([GeoPoint position = _home, double accuracy = 5]) =>
      guard.observeFix(
        LocationSample(
          position: position,
          recordedAt: now,
          accuracyMeters: accuracy,
          speedMetersPerSecond: 0,
        ),
      );

  Future<void> evaluate() => guard.evaluate(
    groupRide: groupRide,
    peers: peers,
    peersObservable: observable,
    route: route,
    marker: marker,
    ridePausedAt: ridePausedAt,
  );

  /// Time passing the way production sees it: an evaluation every 30 seconds.
  Future<void> advance(Duration total) async {
    final end = now.add(total);
    while (now.isBefore(end)) {
      final remaining = end.difference(now);
      now = now.add(
        remaining < const Duration(seconds: 30)
            ? remaining
            : const Duration(seconds: 30),
      );
      await evaluate();
    }
  }

  /// Rides [metres] further north, as a moving rider reports.
  void ride(double metres) => fix(_north(metres));
}

DispersalPeer _movingPeer({double metres = 9000}) => DispersalPeer(
  riderId: 'lead',
  freshness: PresenceFreshness.live,
  position: _north(metres),
  age: const Duration(seconds: 3),
  speedMetersPerSecond: 20,
);

DispersalPeer _companion({double metres = 200}) => DispersalPeer(
  riderId: 'friend',
  freshness: PresenceFreshness.live,
  position: _north(metres),
  age: const Duration(seconds: 3),
  speedMetersPerSecond: 0,
);

void main() {
  group('prompting', () {
    test('a dispersed rider is asked after 30 minutes, not before', () async {
      final h = _Harness();
      await h.begin();

      await h.evaluate();
      await h.advance(const Duration(minutes: 29, seconds: 30));
      expect(h.guard.phase, SharingGuardPhase.sharing);

      await h.advance(const Duration(seconds: 30));
      expect(h.guard.phase, SharingGuardPhase.prompting);
      expect(h.guard.promptedAt, h.now);
      expect(h.pauses, isEmpty);
    });

    test(
      'the question stays up and sharing carries on while it is asked',
      () async {
        final h = _Harness();
        await h.begin();

        await h.advance(const Duration(minutes: 40));

        expect(h.guard.phase, SharingGuardPhase.prompting);
        expect(h.guard.isPaused, isFalse);
        expect(h.pauses, isEmpty);
      },
    );

    test(
      'a rider with the group is never asked, however long it lasts',
      () async {
        final h = _Harness()..peers = [_companion()];
        await h.begin();

        await h.advance(const Duration(hours: 8));

        expect(h.guard.phase, SharingGuardPhase.sharing);
      },
    );

    test('a rider whose group is out riding is never asked', () async {
      final h = _Harness()..peers = [_movingPeer()];
      await h.begin();

      await h.advance(const Duration(hours: 8));

      expect(h.guard.phase, SharingGuardPhase.sharing);
    });

    test('a rider on an unfinished route is never asked while on it', () async {
      final h = _Harness()
        ..route = const DispersalRoute(
          withinCorridor: true,
          progressFraction: 0.5,
        );
      await h.begin();

      await h.advance(const Duration(hours: 2));

      expect(h.guard.phase, SharingGuardPhase.sharing);
    });

    test('a marker waiting for the group is not asked, then is', () async {
      final h = _Harness();
      await h.begin();
      h.marker = DispersalMarkerWait(startedAt: h.now, tecPassed: false);

      await h.advance(const Duration(minutes: 89));
      expect(h.guard.phase, SharingGuardPhase.sharing);

      // The 90-minute ceiling passes, and then the usual 30 minutes of being
      // dispersed has to elapse before the question.
      await h.advance(const Duration(minutes: 30));
      expect(h.guard.phase, SharingGuardPhase.sharing);
      await h.advance(const Duration(minutes: 1));
      expect(h.guard.phase, SharingGuardPhase.prompting);
    });

    test('a ride the leader has paused is not asked for two hours', () async {
      final h = _Harness();
      h.ridePausedAt = h.now;
      await h.begin();

      await h.advance(const Duration(hours: 1, minutes: 59));
      expect(h.guard.phase, SharingGuardPhase.sharing);
      expect(h.guard.lastState, DispersalState.groupPaused);

      // The pause protection ends, and then the usual 30 minutes of being
      // dispersed have to elapse before the question.
      await h.advance(const Duration(minutes: 30));
      expect(h.guard.phase, SharingGuardPhase.sharing);
      await h.advance(const Duration(minutes: 2));
      expect(h.guard.phase, SharingGuardPhase.prompting);
    });

    test('a solo ride is never asked', () async {
      final h = _Harness()..groupRide = false;
      await h.begin();

      await h.advance(const Duration(hours: 8));

      expect(h.guard.phase, SharingGuardPhase.sharing);
    });

    test('a phone that cannot see the group is never asked', () async {
      final h = _Harness()..observable = false;
      await h.begin();

      await h.advance(const Duration(hours: 8));

      expect(h.guard.phase, SharingGuardPhase.sharing);
    });

    test('nothing is judged before the first fix', () async {
      final h = _Harness();

      await h.advance(const Duration(hours: 2));

      expect(h.guard.phase, SharingGuardPhase.sharing);
      expect(h.guard.lastState, DispersalState.unknown);
    });

    test('a break in being dispersed starts the 30 minutes again', () async {
      final h = _Harness();
      await h.begin();

      await h.advance(const Duration(minutes: 25));
      h.peers = [_companion()];
      await h.advance(const Duration(minutes: 1));
      expect(h.guard.dispersedFor, isNull);

      // The 25 minutes before the break are forgotten: being dispersed starts
      // counting again at the first evaluation after the group has gone.
      h.peers = const [];
      await h.advance(const Duration(minutes: 29));
      expect(h.guard.phase, SharingGuardPhase.sharing);

      await h.advance(const Duration(minutes: 2));
      expect(h.guard.phase, SharingGuardPhase.prompting);
    });

    test('the question is withdrawn when the group comes back', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 31));
      expect(h.guard.phase, SharingGuardPhase.prompting);

      h.peers = [_companion()];
      await h.evaluate();

      expect(h.guard.phase, SharingGuardPhase.sharing);
      expect(h.guard.promptedAt, isNull);
      expect(h.guard.promptDeadline, isNull);
    });

    test(
      'the question is withdrawn when the group can no longer be seen',
      () async {
        final h = _Harness();
        await h.begin();
        await h.advance(const Duration(minutes: 31));
        expect(h.guard.phase, SharingGuardPhase.prompting);

        h.observable = false;
        await h.evaluate();

        expect(h.guard.phase, SharingGuardPhase.sharing);
      },
    );

    test(
      'listeners hear about the question and about its withdrawal',
      () async {
        final h = _Harness();
        await h.begin();
        var heard = 0;
        h.guard.addListener(() => heard += 1);

        await h.advance(const Duration(minutes: 31));
        expect(heard, 1);

        h.peers = [_companion()];
        await h.evaluate();
        expect(heard, 2);
      },
    );
  });

  group('the answer', () {
    test('unanswered, sharing stops 15 minutes after the question', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 30));
      expect(h.guard.phase, SharingGuardPhase.prompting);
      final deadline = h.guard.promptDeadline!;
      expect(deadline, h.now.add(const Duration(minutes: 15)));

      await h.advance(const Duration(minutes: 14, seconds: 30));
      expect(h.guard.phase, SharingGuardPhase.prompting);
      expect(h.pauses, isEmpty);

      await h.advance(const Duration(seconds: 30));
      expect(h.guard.phase, SharingGuardPhase.paused);
      expect(h.guard.pauseReason, SharingPauseReason.unanswered);
      expect(h.guard.pausedAt, h.now);
      expect(h.guard.promptDeadline, isNull);
      expect(h.pauses, [SharingPauseReason.unanswered]);
    });

    test('a rider who is moving is never stopped, only asked', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 30));
      expect(h.guard.phase, SharingGuardPhase.prompting);

      // Two hours on the road with the question up and nobody to read it.
      for (var minute = 0; minute < 120; minute += 1) {
        h.ride(1000.0 * (minute + 1));
        await h.advance(const Duration(minutes: 1));
      }

      expect(h.guard.phase, SharingGuardPhase.prompting);
      expect(h.pauses, isEmpty);
    });

    test('the countdown starts again from the moment they stop', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 30));
      expect(h.guard.phase, SharingGuardPhase.prompting);

      // Ten minutes parked, then they ride off for an hour.
      await h.advance(const Duration(minutes: 10));
      for (var minute = 0; minute < 60; minute += 1) {
        h.ride(1000.0 * (minute + 1));
        await h.advance(const Duration(minutes: 1));
      }
      expect(h.guard.phase, SharingGuardPhase.prompting);
      final stoppedAt = h.now.subtract(const Duration(minutes: 1));

      // Parked again: the ten minutes before do not count, and the 15 start
      // from the last time they moved.
      await h.advance(const Duration(minutes: 13, seconds: 30));
      expect(h.guard.phase, SharingGuardPhase.prompting);
      await h.advance(const Duration(minutes: 1));
      expect(h.guard.phase, SharingGuardPhase.paused);
      expect(h.guard.pausedAt, stoppedAt.add(const Duration(minutes: 15)));
    });

    test('keep sharing holds the question off for two hours', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 30));
      expect(h.guard.phase, SharingGuardPhase.prompting);

      h.guard.keepSharing();
      expect(h.guard.phase, SharingGuardPhase.sharing);
      expect(h.guard.promptedAt, isNull);

      await h.advance(const Duration(hours: 1, minutes: 59));
      expect(h.guard.phase, SharingGuardPhase.sharing);

      await h.advance(const Duration(minutes: 1));
      expect(h.guard.phase, SharingGuardPhase.prompting);
      expect(h.pauses, isEmpty);
    });

    test('keep sharing does nothing when nobody has asked', () async {
      final h = _Harness();
      await h.begin();
      var heard = 0;
      h.guard.addListener(() => heard += 1);

      h.guard.keepSharing();

      expect(h.guard.phase, SharingGuardPhase.sharing);
      expect(heard, 0);
    });

    test('stop sharing pauses at once and says it was the rider', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 30));

      await h.guard.stopSharing();

      expect(h.guard.phase, SharingGuardPhase.paused);
      expect(h.guard.pauseReason, SharingPauseReason.rider);
      expect(h.pauses, [SharingPauseReason.rider]);
    });

    test('a rider can stop sharing without ever having been asked', () async {
      final h = _Harness();
      await h.begin();

      await h.guard.stopSharing();

      expect(h.guard.isPaused, isTrue);
      expect(h.pauses, [SharingPauseReason.rider]);
    });

    test('the phase is already paused when the effect runs', () async {
      final h = _Harness();
      await h.begin();

      await h.guard.stopSharing();

      expect(h.phaseWhenPaused, [SharingGuardPhase.paused]);
    });

    test('pausing twice does the work once', () async {
      final h = _Harness();
      await h.begin();

      await h.guard.stopSharing();
      await h.guard.stopSharing();
      await h.advance(const Duration(hours: 2));

      expect(h.pauses, hasLength(1));
    });

    test('nothing is evaluated once paused', () async {
      final h = _Harness();
      await h.begin();
      await h.guard.stopSharing();

      h.peers = [_companion()];
      await h.advance(const Duration(hours: 1));

      expect(h.guard.phase, SharingGuardPhase.paused);
      expect(h.guard.dispersedFor, isNull);
    });
  });

  group('resuming', () {
    test(
      'resumes sharing, clears the pause and holds the question off',
      () async {
        final h = _Harness();
        await h.begin();
        await h.advance(const Duration(minutes: 45));
        expect(h.guard.phase, SharingGuardPhase.paused);

        final resumed = await h.guard.resume();

        expect(resumed, isTrue);
        expect(h.resumes, 1);
        expect(h.guard.phase, SharingGuardPhase.sharing);
        expect(h.guard.pauseReason, isNull);
        expect(h.guard.pausedAt, isNull);

        await h.advance(const Duration(hours: 1, minutes: 59));
        expect(h.guard.phase, SharingGuardPhase.sharing);
        await h.advance(const Duration(minutes: 1));
        expect(h.guard.phase, SharingGuardPhase.prompting);
      },
    );

    test('stays paused when sharing could not start again', () async {
      final h = _Harness()..resumeSucceeds = false;
      await h.begin();
      await h.guard.stopSharing();

      final resumed = await h.guard.resume();

      expect(resumed, isFalse);
      expect(h.guard.phase, SharingGuardPhase.paused);
      expect(h.guard.pauseReason, SharingPauseReason.rider);
    });

    test('a second tap while it is starting does not start it twice', () async {
      final h = _Harness();
      await h.begin();
      await h.guard.stopSharing();

      final first = h.guard.resume();
      final second = h.guard.resume();

      expect(await second, isFalse);
      expect(await first, isTrue);
      expect(h.resumes, 1);
    });

    test('does nothing unless sharing is paused', () async {
      final h = _Harness();
      await h.begin();

      expect(await h.guard.resume(), isFalse);
      expect(h.resumes, 0);
    });

    test('can be stopped again after resuming', () async {
      final h = _Harness();
      await h.begin();
      await h.guard.stopSharing();
      await h.guard.resume();

      await h.guard.stopSharing();

      expect(h.pauses, [SharingPauseReason.rider, SharingPauseReason.rider]);
    });
  });

  group('continuity', () {
    test('a gap longer than five minutes means "away" starts again', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 25));

      // The app is suspended for ten minutes: nothing can be said about it.
      h.now = h.now.add(const Duration(minutes: 10));
      await h.evaluate();
      expect(h.guard.phase, SharingGuardPhase.sharing);

      await h.advance(const Duration(minutes: 29));
      expect(h.guard.phase, SharingGuardPhase.sharing);
      await h.advance(const Duration(minutes: 1));
      expect(h.guard.phase, SharingGuardPhase.prompting);
    });

    test('a gap of up to five minutes is still continuous', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 25));

      // A slow tick, not a suspension.
      h.now = h.now.add(const Duration(minutes: 4));
      await h.evaluate();
      expect(h.guard.phase, SharingGuardPhase.sharing);

      await h.advance(const Duration(minutes: 1));
      expect(h.guard.phase, SharingGuardPhase.prompting);
    });

    test('a gap of six minutes is not', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 25));

      h.now = h.now.add(const Duration(minutes: 6));
      await h.evaluate();

      expect(h.guard.dispersedFor, Duration.zero);
      await h.advance(const Duration(minutes: 29));
      expect(h.guard.phase, SharingGuardPhase.sharing);
    });

    test('a question that was up is given a fresh answer window', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 40));
      expect(h.guard.phase, SharingGuardPhase.prompting);

      // Suspended past the deadline. Not having been reachable is not refusing.
      h.now = h.now.add(const Duration(minutes: 30));
      await h.evaluate();

      expect(h.guard.phase, SharingGuardPhase.prompting);
      expect(h.pauses, isEmpty);
      expect(h.guard.promptDeadline, h.now.add(const Duration(minutes: 15)));
    });
  });

  group('knowing whether the rider is parked', () {
    test('a rider is parked for as long as they stay in one place', () async {
      final h = _Harness();
      await h.begin();

      await h.advance(const Duration(minutes: 20));

      expect(h.guard.parkedFor, const Duration(minutes: 20));
    });

    test('wander within 150 m does not read as moving', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 10));

      h.fix(_north(140));
      await h.advance(const Duration(minutes: 10));

      expect(h.guard.parkedFor, const Duration(minutes: 20));
    });

    test('going further than 150 m, however slowly, is moving', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 10));

      h.fix(_north(160));

      expect(h.guard.parkedFor, Duration.zero);
    });

    test('a poor fix has to clear its own error as well', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 10));

      // 400 m away but 300 m uncertain: the phone could still be where it was.
      h.fix(_north(400), 300);
      expect(h.guard.parkedFor, const Duration(minutes: 10));

      h.fix(_north(500), 300);
      expect(h.guard.parkedFor, Duration.zero);
    });

    test('a rider has moved lately for five minutes after they stop', () async {
      final h = _Harness();
      expect(h.guard.movedRecently, isFalse, reason: 'no fix, no movement');

      await h.begin();
      await h.advance(const Duration(minutes: 4, seconds: 30));
      expect(h.guard.movedRecently, isTrue);

      await h.advance(const Duration(minutes: 1));
      expect(h.guard.movedRecently, isFalse);

      h.ride(1000);
      expect(h.guard.movedRecently, isTrue);
    });

    test('nothing is parked before there is a fix', () {
      final h = _Harness();

      expect(h.guard.parkedFor, Duration.zero);
    });
  });

  group('disposal', () {
    test('nothing happens after the guard is disposed', () async {
      final h = _Harness();
      await h.begin();
      await h.advance(const Duration(minutes: 31));
      h.guard.dispose();

      h.guard.keepSharing();
      await h.guard.stopSharing();
      await h.evaluate();

      expect(h.pauses, isEmpty);
    });
  });
}
