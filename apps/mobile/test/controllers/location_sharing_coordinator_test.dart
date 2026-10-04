import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/location_sharing_coordinator.dart';
import 'package:ride_relay/controllers/location_sharing_guard.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/imported_route.dart' as route_domain;
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/sharing_reminder_notifier.dart';

const _metresPerDegree = 111194.9;
const _home = GeoPoint(latitude: 51.5, longitude: -2.5);

GeoPoint _north(double metres, {double east = 0}) => GeoPoint(
  latitude: _home.latitude + metres / _metresPerDegree,
  longitude: _home.longitude + east / (_metresPerDegree * 0.62),
);

/// 20 km due north from home, a point every kilometre.
final _route = route_domain.ImportedRoute(
  id: 'route',
  name: 'North',
  importedAt: DateTime.utc(2026, 10, 4),
  sourceFileName: 'north.gpx',
  paths: [
    route_domain.RoutePath(
      kind: route_domain.RoutePathKind.route,
      points: [
        for (var km = 0; km <= 20; km += 1)
          route_domain.GeoPoint(
            latitude: _home.latitude + km * 1000 / _metresPerDegree,
            longitude: _home.longitude,
          ),
      ],
    ),
  ],
  waypoints: const [],
);

class _FakeNotifier implements SharingReminderNotifier {
  final shown = <String>[];
  final bodies = <String>[];
  int cleared = 0;

  @override
  Future<bool> show({required String title, required String body}) async {
    shown.add(title);
    bodies.add(body);
    return true;
  }

  @override
  Future<void> clear() async => cleared += 1;
}

/// A coordinator on a fake clock with a fake ride behind it.
class _Ride {
  _Ride() {
    coordinator = LocationSharingCoordinator(
      hooks: LocationSharingHooks(
        rideRunning: () {
          rideRunningChecks += 1;
          return running;
        },
        isGroupRide: () => group,
        reconciledPresence: () {
          if (presenceThrows) throw StateError('model not ready');
          return presence;
        },
        liveRiderIds: () => liveIds,
        peersObservable: () => observable,
        activeRoute: () => route,
        activeMarker: () => marker,
        ridePausedAt: () => pausedAt,
        watchersActive: () => watchers,
        suspendPublishing: () async {
          if (suspendThrows) throw StateError('relay unreachable');
          log.add('suspend publishing');
        },
        resumePublishing: () => log.add('resume publishing'),
        stopLocation: () async {
          if (stopThrows) throw StateError('plugin gone');
          log.add('stop location');
        },
        startLocation: () async {
          log.add('start location');
          await startGate?.future;
          if (startThrows) throw StateError('permission revoked');
          return locationStarts;
        },
        note: notes.add,
      ),
      rideName: 'Sunday run',
      notifier: notifier,
      clock: () => now,
    );
    addTearDown(coordinator.dispose);
  }

  late final LocationSharingCoordinator coordinator;
  final notifier = _FakeNotifier();
  DateTime now = DateTime.utc(2026, 10, 4, 15);
  final log = <String>[];
  final notes = <String>[];
  int rideRunningChecks = 0;

  bool running = true;
  bool group = true;
  List<LiveRiderPresence> presence = const [];
  Set<String> liveIds = {};
  bool observable = true;
  route_domain.ImportedRoute? route;
  MarkerSessionSummary? marker;
  DateTime? pausedAt;
  bool watchers = false;
  bool locationStarts = true;
  Completer<void>? startGate;
  bool suspendThrows = false;
  bool stopThrows = false;
  bool startThrows = false;
  bool presenceThrows = false;

  Future<void> begin([GeoPoint at = _home]) async {
    fix(at);
    await coordinator.evaluate();
  }

  void fix(GeoPoint position, {double speed = 0}) => coordinator.observeFix(
    LocationSample(
      position: position,
      recordedAt: now,
      accuracyMeters: 5,
      speedMetersPerSecond: speed,
    ),
  );

  Future<void> advance(Duration total) async {
    final end = now.add(total);
    while (now.isBefore(end)) {
      final remaining = end.difference(now);
      now = now.add(
        remaining < const Duration(seconds: 30)
            ? remaining
            : const Duration(seconds: 30),
      );
      await coordinator.evaluate();
    }
  }
}

LiveRiderPresence _rider(
  String id, {
  required double metres,
  bool isLocal = false,
  PresenceFreshness freshness = PresenceFreshness.live,
  Duration age = const Duration(seconds: 3),
  double speed = 0,
}) {
  final sample = LocationSample(
    position: _north(metres),
    recordedAt: DateTime.utc(2026, 10, 4, 15),
    accuracyMeters: 5,
    speedMetersPerSecond: speed,
  );
  return LiveRiderPresence(
    riderId: id,
    displayName: id,
    role: RideRole.rider,
    freshness: freshness,
    sources: const {LivePresenceSource.internetPresence},
    isLocal: isLocal,
    knownSince: DateTime.utc(2026, 10, 4, 12),
    age: age,
    location: RiderLocation(
      riderId: id,
      displayName: id,
      role: RideRole.rider,
      sample: sample,
      receivedAt: sample.recordedAt,
    ),
  );
}

void main() {
  const thirtyOne = Duration(minutes: 31);

  group('what the coordinator reads from the ride', () {
    test('a rider who is still in the ride and close by is company', () async {
      final ride = _Ride()
        ..presence = [_rider('alex', metres: 300)]
        ..liveIds = {'alex'};
      await ride.begin();

      await ride.advance(const Duration(hours: 3));

      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
    });

    test(
      'a rider who has left is not company, however close they were',
      () async {
        final ride = _Ride()
          ..presence = [_rider('alex', metres: 300)]
          ..liveIds = {};
        await ride.begin();

        await ride.advance(thirtyOne);

        expect(ride.coordinator.phase, SharingGuardPhase.prompting);
      },
    );

    test('this rider\'s own entry is not their company', () async {
      final ride = _Ride()
        ..presence = [_rider('me', metres: 0, isLocal: true)]
        ..liveIds = {'me'};
      await ride.begin();

      await ride.advance(thirtyOne);

      expect(ride.coordinator.phase, SharingGuardPhase.prompting);
    });

    test(
      'a group out riding keeps a rider who is far from them unasked',
      () async {
        final ride = _Ride()
          ..presence = [_rider('lead', metres: 9000, speed: 22)]
          ..liveIds = {'lead'};
        await ride.begin();

        await ride.advance(const Duration(hours: 3));

        expect(ride.coordinator.phase, SharingGuardPhase.sharing);
      },
    );

    test('nothing is judged while the group cannot be seen', () async {
      final ride = _Ride()..observable = false;
      await ride.begin();

      await ride.advance(const Duration(hours: 3));

      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
    });

    test(
      'nothing is judged before the ride has started or after it has ended',
      () async {
        final ride = _Ride()..running = false;
        await ride.begin();

        await ride.advance(const Duration(hours: 3));

        expect(ride.coordinator.phase, SharingGuardPhase.sharing);
        expect(ride.rideRunningChecks, greaterThan(0));
      },
    );

    test('a solo ride is never asked', () async {
      final ride = _Ride()..group = false;
      await ride.begin();

      await ride.advance(const Duration(hours: 3));

      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
    });

    test(
      'a ride the leader has paused is not asked while the pause is recent',
      () async {
        final ride = _Ride();
        ride.pausedAt = ride.now;
        await ride.begin();

        await ride.advance(const Duration(hours: 1, minutes: 30));

        expect(ride.coordinator.phase, SharingGuardPhase.sharing);
      },
    );

    test('a marker waiting for the group is not asked', () async {
      final ride = _Ride();
      ride.marker = MarkerSessionSummary(
        sessionId: 's',
        markerDeviceId: 'me',
        startedAt: ride.now,
        mode: 'manual',
        uniquePassCount: 0,
        uniqueRiderIds: const [],
        verifiedPassCount: 0,
        verifiedRiderIds: const [],
      );
      await ride.begin();

      await ride.advance(const Duration(hours: 1, minutes: 20));

      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
    });
  });

  group('the planned route', () {
    test('a rider on an unfinished route is not asked', () async {
      final ride = _Ride()..route = _route;
      await ride.begin(_north(5000));

      await ride.advance(const Duration(hours: 2));

      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
    });

    test('a rider who has left the route is asked', () async {
      final ride = _Ride()..route = _route;
      await ride.begin(_north(5000, east: 5000));

      await ride.advance(thirtyOne);

      expect(ride.coordinator.phase, SharingGuardPhase.prompting);
    });

    test('a rider who has finished the route is asked', () async {
      final ride = _Ride()..route = _route;
      await ride.begin(_north(20000));

      await ride.advance(thirtyOne);

      expect(ride.coordinator.phase, SharingGuardPhase.prompting);
    });

    test('no route at all means no protection from one', () async {
      final ride = _Ride();
      await ride.begin(_north(5000));

      await ride.advance(thirtyOne);

      expect(ride.coordinator.phase, SharingGuardPhase.prompting);
    });
  });

  group('stopping', () {
    test(
      'takes the position off the channels, then stops the stream',
      () async {
        final ride = _Ride();
        await ride.begin();

        await ride.coordinator.stopByRider();

        expect(ride.log, ['suspend publishing', 'stop location']);
        expect(ride.coordinator.isPaused, isTrue);
        expect(ride.coordinator.pauseReason, SharingPauseReason.rider);
      },
    );

    test(
      'leaves the stream running for a watcher link the rider granted',
      () async {
        final ride = _Ride()..watchers = true;
        await ride.begin();

        await ride.coordinator.stopByRider();

        expect(ride.log, ['suspend publishing']);
      },
    );

    test('happens on its own after an unanswered question', () async {
      final ride = _Ride();
      await ride.begin();

      await ride.advance(const Duration(minutes: 45));

      expect(ride.coordinator.isPaused, isTrue);
      expect(ride.coordinator.pauseReason, SharingPauseReason.unanswered);
      expect(ride.log, ['suspend publishing', 'stop location']);
    });

    test('keep sharing answers the question and nothing is stopped', () async {
      final ride = _Ride();
      await ride.begin();
      await ride.advance(thirtyOne);
      expect(ride.coordinator.phase, SharingGuardPhase.prompting);

      ride.coordinator.keepSharing();
      await ride.advance(const Duration(hours: 1));

      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
      expect(ride.log, isEmpty);
    });
  });

  group('resuming', () {
    test('starts the stream first, then lets positions out', () async {
      final ride = _Ride();
      await ride.begin();
      await ride.coordinator.stopByRider();
      ride.log.clear();

      await ride.coordinator.resumeByRider();

      expect(ride.log, ['start location', 'resume publishing']);
      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
    });

    test('lets nothing out when the stream could not start', () async {
      final ride = _Ride()..locationStarts = false;
      await ride.begin();
      await ride.coordinator.stopByRider();
      ride.log.clear();

      await ride.coordinator.resumeByRider();

      expect(ride.log, ['start location']);
      expect(ride.coordinator.isPaused, isTrue);
    });

    test(
      'a second tap keeps it resuming until the first has finished',
      () async {
        final ride = _Ride();
        await ride.begin();
        await ride.coordinator.stopByRider();

        ride.startGate = Completer<void>();
        final first = ride.coordinator.resumeByRider();
        final second = ride.coordinator.resumeByRider();
        await second;

        expect(ride.coordinator.resuming, isTrue);
        ride.startGate!.complete();
        await first;
        expect(ride.coordinator.resuming, isFalse);
      },
    );

    test('is reported while it is under way', () async {
      final ride = _Ride();
      await ride.begin();
      await ride.coordinator.stopByRider();
      final seen = <bool>[];
      ride.coordinator.addListener(() => seen.add(ride.coordinator.resuming));

      await ride.coordinator.resumeByRider();

      expect(seen, containsAllInOrder([true, false]));
      expect(ride.coordinator.resuming, isFalse);
    });

    test('an alert switches sharing back on', () async {
      final ride = _Ride();
      await ride.begin();
      await ride.coordinator.stopByRider();

      ride.coordinator.resumeForSafety();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(ride.coordinator.phase, SharingGuardPhase.sharing);
      expect(ride.log, contains('resume publishing'));
    });

    test('an alert changes nothing while sharing is already on', () async {
      final ride = _Ride();
      await ride.begin();

      ride.coordinator.resumeForSafety();
      await Future<void>.delayed(Duration.zero);

      expect(ride.log, isEmpty);
    });
  });

  group('when a step goes wrong', () {
    test('a failing step does not stop the next one', () async {
      final ride = _Ride()..suspendThrows = true;
      await ride.begin();

      await ride.coordinator.stopByRider();

      // The pause had already happened; the stream is still stopped.
      expect(ride.coordinator.isPaused, isTrue);
      expect(ride.log, ['stop location']);
      expect(ride.notes.last, contains('suspending publishing failed'));
    });

    test('a stream that will not stop is noted, not thrown', () async {
      final ride = _Ride()..stopThrows = true;
      await ride.begin();

      await ride.coordinator.stopByRider();

      expect(ride.coordinator.isPaused, isTrue);
      expect(ride.notes.last, contains('stopping location failed'));
    });

    test('a stream that will not start leaves the rider paused', () async {
      final ride = _Ride()..startThrows = true;
      await ride.begin();
      await ride.coordinator.stopByRider();
      ride.log.clear();

      await ride.coordinator.resumeByRider();

      expect(ride.coordinator.isPaused, isTrue);
      expect(ride.log, isNot(contains('resume publishing')));
      expect(
        ride.notes.any((note) => note.contains('starting location failed')),
        isTrue,
      );
    });

    test(
      'a tick that cannot read the ride does not break the next one',
      () async {
        final ride = _Ride();
        await ride.begin();
        ride.presenceThrows = true;

        await ride.coordinator.evaluate();
        expect(ride.notes.last, contains('could not look at the ride'));

        ride.presenceThrows = false;
        await ride.advance(thirtyOne);
        expect(ride.coordinator.phase, SharingGuardPhase.prompting);
      },
    );
  });

  group('the question on screen', () {
    test('is redrawn when the rider starts and stops moving', () async {
      final ride = _Ride();
      await ride.begin();
      await ride.advance(thirtyOne);
      expect(ride.coordinator.phase, SharingGuardPhase.prompting);
      var redraws = 0;
      ride.coordinator.addListener(() => redraws += 1);

      // Parked: nothing to say.
      await ride.advance(const Duration(minutes: 1));
      expect(redraws, 0);

      // On the road: "will not stop while you are riding".
      ride.fix(_north(2000), speed: 25);
      await ride.advance(const Duration(minutes: 1));
      expect(redraws, 1);
      expect(ride.coordinator.movedRecently, isTrue);

      // Parked again, five minutes on: back to "in 15 minutes".
      await ride.advance(const Duration(minutes: 5));
      expect(redraws, 2);
      expect(ride.coordinator.movedRecently, isFalse);
    });
  });

  group('the notification', () {
    test(
      'is shown for a question that arrives while the app is in the background',
      () async {
        final ride = _Ride();
        await ride.begin();
        ride.coordinator.onLifecycleChanged(AppLifecycleState.paused);

        await ride.advance(thirtyOne);
        await Future<void>.delayed(Duration.zero);

        expect(ride.notifier.shown, ['Still riding with Sunday run?']);
      },
    );

    test(
      'is shown when the app goes to the background with the question up',
      () async {
        final ride = _Ride();
        await ride.begin();
        await ride.advance(thirtyOne);
        await Future<void>.delayed(Duration.zero);
        expect(ride.notifier.shown, isEmpty);

        ride.coordinator.onLifecycleChanged(AppLifecycleState.hidden);
        await Future<void>.delayed(Duration.zero);

        expect(ride.notifier.shown, hasLength(1));
      },
    );

    test('tells a parked rider when sharing will stop', () async {
      final ride = _Ride();
      await ride.begin();
      ride.coordinator.onLifecycleChanged(AppLifecycleState.paused);

      await ride.advance(thirtyOne);
      await Future<void>.delayed(Duration.zero);

      expect(ride.notifier.bodies.single, contains('stops in 15 minutes'));
    });

    test(
      'tells a rider on the road that nothing stops while they ride',
      () async {
        final ride = _Ride();
        await ride.begin();
        ride.coordinator.onLifecycleChanged(AppLifecycleState.paused);
        await ride.advance(const Duration(minutes: 29));
        ride.fix(_north(3000), speed: 25);

        await ride.advance(const Duration(minutes: 2));
        await Future<void>.delayed(Duration.zero);

        expect(
          ride.notifier.bodies.single,
          contains('will not stop while you are riding'),
        );
      },
    );

    test('is taken down when the rider comes back to the app', () async {
      final ride = _Ride();
      await ride.begin();
      ride.coordinator.onLifecycleChanged(AppLifecycleState.paused);
      await ride.advance(thirtyOne);
      await Future<void>.delayed(Duration.zero);

      ride.coordinator.onLifecycleChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(ride.notifier.cleared, 1);
    });

    test('is not shown for a switch that is only transient', () async {
      final ride = _Ride();
      await ride.begin();
      await ride.advance(thirtyOne);

      ride.coordinator.onLifecycleChanged(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);

      expect(ride.notifier.shown, isEmpty);
    });

    test(
      'says when sharing stopped on its own while the app was away',
      () async {
        final ride = _Ride();
        await ride.begin();
        ride.coordinator.onLifecycleChanged(AppLifecycleState.paused);

        await ride.advance(const Duration(minutes: 46));
        await Future<void>.delayed(Duration.zero);

        expect(ride.notifier.shown, [
          'Still riding with Sunday run?',
          'Location sharing stopped',
        ]);
      },
    );
  });

  group('the ride log', () {
    test('records each change of state, with why', () async {
      final ride = _Ride();
      await ride.begin();

      await ride.advance(thirtyOne);
      await ride.advance(const Duration(minutes: 15));

      expect(ride.notes, [
        'location sharing prompting, dispersed',
        'location sharing paused (unanswered), dispersed',
      ]);
    });
  });

  group('moving', () {
    test('a rider on the road is asked but never stopped', () async {
      final ride = _Ride();
      await ride.begin();
      await ride.advance(thirtyOne);
      expect(ride.coordinator.phase, SharingGuardPhase.prompting);

      for (var minute = 1; minute <= 90; minute += 1) {
        ride.fix(_north(minute * 1500.0), speed: 25);
        await ride.advance(const Duration(minutes: 1));
      }

      expect(ride.coordinator.phase, SharingGuardPhase.prompting);
      expect(ride.coordinator.movedRecently, isTrue);
      expect(ride.log, isEmpty);
    });
  });

  group('the timer', () {
    testWidgets('looks at the ride every interval and stops when disposed', (
      tester,
    ) async {
      var looks = 0;
      final coordinator = LocationSharingCoordinator(
        hooks: LocationSharingHooks(
          rideRunning: () {
            looks += 1;
            return false;
          },
          isGroupRide: () => true,
          reconciledPresence: () => const [],
          liveRiderIds: () => const {},
          peersObservable: () => true,
          activeRoute: () => null,
          activeMarker: () => null,
          ridePausedAt: () => null,
          watchersActive: () => false,
          suspendPublishing: () async {},
          resumePublishing: () {},
          stopLocation: () async {},
          startLocation: () async => true,
        ),
        rideName: null,
        notifier: _FakeNotifier(),
      );

      coordinator.start();
      coordinator.start();
      await tester.pump(const Duration(seconds: 95));
      expect(looks, 3);

      coordinator.dispose();
      await tester.pump(const Duration(minutes: 5));
      expect(looks, 3);
    });
  });

  group('disposal', () {
    test('takes down the notification and ignores everything after', () async {
      final ride = _Ride();
      await ride.begin();
      ride.coordinator.onLifecycleChanged(AppLifecycleState.paused);
      await ride.advance(thirtyOne);
      await Future<void>.delayed(Duration.zero);

      ride.coordinator.dispose();
      await Future<void>.delayed(Duration.zero);
      await ride.coordinator.evaluate();
      await ride.coordinator.stopByRider();

      expect(ride.notifier.cleared, 1);
      expect(ride.log, isEmpty);
    });
  });
}
