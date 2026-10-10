import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/ride/ride_replay_screen.dart';
import 'package:ride_relay/services/ride_replay.dart';

/// **Replay controls (#305): play, pause, speed and scrub.**
///
/// The map is a stand-in that prints where the marker is, so what is asserted
/// is the screen's own behaviour: that pressing play moves the marker at the
/// chosen speed, pause stops it, and the scrubber and speed control do what
/// they say.
void main() {
  final base = DateTime.utc(2026, 10, 4, 9);

  /// A one-hour ride north along a meridian: latitude is progress.
  ImportedRoute hour({bool withGap = false}) => ImportedRoute(
    id: 'ride',
    name: 'Ride',
    importedAt: base,
    sourceFileName: 'ride.gpx',
    paths: [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 50, longitude: -2, recordedAt: base),
          GeoPoint(
            latitude: 51,
            longitude: -2,
            recordedAt: base.add(Duration(minutes: withGap ? 30 : 60)),
          ),
        ],
      ),
      if (withGap)
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(
              latitude: 51,
              longitude: -2,
              recordedAt: base.add(const Duration(hours: 3)),
            ),
            GeoPoint(
              latitude: 52,
              longitude: -2,
              recordedAt: base.add(const Duration(hours: 3, minutes: 30)),
            ),
          ],
        ),
    ],
    waypoints: const [],
  );

  CompletedRide rideOf(ImportedRoute route) => CompletedRide(
    rideId: 'ride-1',
    rideCode: '405400',
    rideName: null,
    localDisplayName: 'Oliver',
    localRole: RideRole.rider,
    startedAt: base,
    endedAt: base.add(const Duration(hours: 1)),
    archivedAt: base.add(const Duration(hours: 1)),
    riderCount: 1,
    eventCount: 12,
    totalDistanceMeters: 100000,
    markerSessions: const [],
    plannedRoute: null,
    traveledRoute: route,
  );

  Future<void> pumpReplay(
    WidgetTester tester, {
    bool withGap = false,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final route = hour(withGap: withGap);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideReplayScreen(
          ride: rideOf(route),
          timeline: RideReplayTimeline.fromRoute(route)!,
          mapBuilder: (context, position) => ValueListenableBuilder<GeoPoint?>(
            valueListenable: position,
            builder: (context, point, _) => Center(
              child: Text(
                point == null ? 'no marker' : point.latitude.toStringAsFixed(3),
                key: const Key('fake-map-marker'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  testWidgets('starts paused at the start, with the whole ride as the length', (
    tester,
  ) async {
    await pumpReplay(tester);

    expect(text(tester, 'replay-elapsed'), '00:00');
    expect(text(tester, 'replay-total'), '1:00:00');
    expect(text(tester, 'fake-map-marker'), '50.000');
    expect(find.byTooltip('Play'), findsOneWidget);
    // And it says what it is: one rider, no group, and skips nothing here.
    expect(find.textContaining('Other riders are not kept'), findsOneWidget);
    expect(find.textContaining('paused'), findsNothing);
  });

  testWidgets('play moves the marker at the chosen speed and pause stops it', (
    tester,
  ) async {
    await pumpReplay(tester);

    await tester.tap(find.byKey(const Key('replay-play-pause')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    // 60x by default: ten seconds of watching is ten minutes of riding.
    expect(text(tester, 'replay-elapsed'), '10:00');
    expect(text(tester, 'fake-map-marker'), '50.167');
    expect(find.byTooltip('Pause'), findsOneWidget);

    await tester.tap(find.byKey(const Key('replay-play-pause')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(text(tester, 'replay-elapsed'), '10:00', reason: 'paused');
  });

  testWidgets('a faster speed covers more of the ride in the same time', (
    tester,
  ) async {
    await pumpReplay(tester);

    await tester.tap(find.text('120×'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('replay-play-pause')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));

    expect(text(tester, 'replay-elapsed'), '20:00');
  });

  testWidgets('the scrubber moves the marker to a point in the ride', (
    tester,
  ) async {
    await pumpReplay(tester);

    // The middle of the slider is the middle of the ride.
    await tester.tap(find.byKey(const Key('replay-scrubber')));
    await tester.pump();

    expect(text(tester, 'replay-elapsed'), '30:00');
    expect(text(tester, 'fake-map-marker'), '50.500');
    expect(find.byTooltip('Play'), findsOneWidget, reason: 'still paused');
  });

  testWidgets('it stops at the end and offers to start over', (tester) async {
    await pumpReplay(tester);

    await tester.tap(find.text('120×'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('replay-play-pause')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 40));
    await tester.pump(const Duration(seconds: 40));

    expect(text(tester, 'replay-elapsed'), '1:00:00');
    expect(text(tester, 'fake-map-marker'), '51.000');
    expect(find.byTooltip('Replay from the start'), findsOneWidget);

    await tester.tap(find.byKey(const Key('replay-play-pause')));
    await tester.pump();
    expect(text(tester, 'replay-elapsed'), '00:00');
    expect(find.byTooltip('Pause'), findsOneWidget);
    // Leave nothing running for the framework to complain about.
    await tester.tap(find.byKey(const Key('replay-play-pause')));
    await tester.pump();
  });

  testWidgets('a recording gap is skipped, and the replay says so', (
    tester,
  ) async {
    await pumpReplay(tester, withGap: true);

    // 30 + 30 minutes recorded; the 2.5 hours between them are not played.
    expect(text(tester, 'replay-total'), '1:00:00');
    expect(find.textContaining('Recording paused once'), findsOneWidget);
    expect(find.textContaining('skips it'), findsOneWidget);
  });

  testWidgets(
    'on its side the controls are one row and the map keeps the room',
    (tester) async {
      await pumpReplay(tester, size: const Size(844, 390));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('replay-scrubber')), findsOneWidget);
      expect(find.byKey(const Key('replay-play-pause')), findsOneWidget);
      expect(find.byKey(const Key('replay-speed')), findsOneWidget);
      // The explanatory note gives way to the map in landscape.
      expect(find.byKey(const Key('replay-note')), findsNothing);
      // One row: play and speed sit level.
      final play = tester.getCenter(find.byKey(const Key('replay-play-pause')));
      final speed = tester.getCenter(find.byKey(const Key('replay-speed')));
      expect((play.dy - speed.dy).abs(), lessThan(8));
      // And the map has the rest: over two thirds of the screen's height.
      final map = tester.getSize(find.byKey(const Key('fake-map-marker')));
      expect(map.width, greaterThan(0));
      final mapArea = tester.getRect(
        find.ancestor(
          of: find.byKey(const Key('fake-map-marker')),
          matching: find.byType(Expanded),
        ),
      );
      expect(mapArea.height / 390, greaterThan(0.66));
    },
  );
}
