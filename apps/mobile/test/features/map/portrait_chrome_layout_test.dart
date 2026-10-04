import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/riding_display_size.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #848: in portrait every navigational surface is part of the bottom band, so
/// nothing a rider reads or presses sits over the road ahead, and the camera
/// puts the rider's marker above the band at every guidance size, every text
/// scale and on a small phone as well as a large one.
///
/// The ETA and the group overview used to float 154 pixels below the top of the
/// screen - the middle of the forward view on a mounted phone - and the marker
/// was sometimes drawn under one of them. These tests measure the laid-out
/// rectangles rather than summing assumed heights, because the failure was a
/// rectangle of the screen being occupied twice.

/// A phone, with the safe areas it actually has: the home indicator and the
/// Dynamic Island on an iPhone take 34 and 59 points that a bare test viewport
/// does not.
class _Phone {
  const _Phone(this.name, this.size, {required this.top, required this.bottom});

  final String name;
  final Size size;
  final double top;
  final double bottom;

  @override
  String toString() => '$name ${size.width.round()}x${size.height.round()}';
}

const _phones = [
  _Phone('iPhone 15', Size(393, 852), top: 59, bottom: 34),
  // The smallest screen the app targets: 667 points tall with no notch.
  _Phone('iPhone SE', Size(375, 667), top: 20, bottom: 0),
  _Phone('compact Android', Size(360, 800), top: 24, bottom: 0),
  _Phone('iPhone 15 Pro Max', Size(430, 932), top: 59, bottom: 34),
];

/// 1.0 is the default, 1.3 is the most the chrome follows, and 2.0 is what
/// Android's largest font setting asks for - which must draw exactly as 1.3.
const _textScales = [1.0, 1.3, 2.0];

/// Everything a rider reads or presses on the ride map apart from the top row.
const _navigationalKeys = [
  'route-progress-panel',
  'navigation-guidance-banner',
  'group-mini-map',
  'leader-tec-gap',
  'emergency-alert-button',
  'leave-ride-button',
  'report-sighting-button',
];

/// The three corner glances #125 and #133 allowed above the road: the ride
/// menu, the clock and the speed sign with its compass.
const _topRowKeys = ['ride-menu-button', 'ride-clock', 'speed-compass-cluster'];

/// How far either side of straight ahead the forward cone opens. The road a
/// rider reads runs up the middle of the frame and bends within this of it.
const _forwardConeHalfAngleDegrees = 25.0;

void main() {
  setUpAll(_loadRoboto);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final phone in _phones) {
    testWidgets(
      '$phone keeps the marker and the road ahead clear of every surface',
      (tester) async {
        for (final leader in const [false, true]) {
          for (final display in RidingDisplaySize.values) {
            final byScale = <double, _Layout>{};
            for (final scale in _textScales) {
              final layout = await _pump(
                tester,
                phone: phone,
                display: display,
                textScale: scale,
                leader: leader,
              );
              byScale[scale] = layout;
              _expectMarkerAndConeClear(layout, reason: layout.reason);
              expect(
                tester.takeException(),
                isNull,
                reason: '${layout.reason} overflowed',
              );
            }
            // The chrome stops following the system text size at its ceiling:
            // asking for 2.0 draws what 1.3 draws, and Large - already the
            // biggest the app gets - holds the system scale at 1.0. Left to
            // grow, Large at 2.0 made the turn banner alone taller than the
            // phone, which no camera can frame the marker above.
            expect(
              byScale[2.0]!.band.height,
              closeTo(byScale[1.3]!.band.height, 0.5),
              reason:
                  '${display.name} on $phone must stop following the system '
                  'text size at 1.3',
            );
            if (display == RidingDisplaySize.large) {
              expect(
                byScale[1.3]!.band.height,
                closeTo(byScale[1.0]!.band.height, 0.5),
                reason:
                    'Large on $phone must not stack the system scale on '
                    'its own',
              );
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('the ETA and the group overview are in the band, not over it', (
    tester,
  ) async {
    final layout = await _pump(
      tester,
      phone: _phones.first,
      display: RidingDisplaySize.small,
      textScale: 1,
      leader: true,
    );
    final eta = layout.rects['route-progress-panel']!;
    final overview = layout.rects['group-mini-map']!;
    final banner = layout.rects['navigation-guidance-banner']!;
    final sos = layout.rects['emergency-alert-button']!;
    final report = layout.rects['report-sighting-button']!;
    final band = layout.band;

    // The ETA is the top strip of the band, across the whole of it.
    expect(eta.top, greaterThanOrEqualTo(band.top));
    expect(eta.bottom, lessThanOrEqualTo(banner.top));
    expect(eta.left, closeTo(band.left, 1));
    expect(eta.right, closeTo(band.right, 1));
    // The overview shares the row of targets, hard against the trailing edge,
    // beside them and never over them.
    expect(overview.top, greaterThanOrEqualTo(banner.bottom));
    expect(overview.bottom, lessThanOrEqualTo(band.bottom + 0.5));
    expect(overview.right, closeTo(band.right, 1));
    expect(overview.left, greaterThanOrEqualTo(report.right));
    expect(overview.left, greaterThanOrEqualTo(sos.right));
    // Everything navigational is below the rider's marker; only the three corner
    // glances are above it.
    for (final entry in layout.rects.entries) {
      if (_topRowKeys.contains(entry.key)) continue;
      expect(
        entry.value.top,
        greaterThanOrEqualTo(layout.rider.bottom),
        reason: '${entry.key} is over the road ahead of the marker',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Follow me stays in the band, above the turn banner', (
    tester,
  ) async {
    final layout = await _pump(
      tester,
      phone: _phones.first,
      display: RidingDisplaySize.large,
      textScale: 1,
      leader: true,
    );
    // Pan the map off the rider, above the band where there is only map.
    await tester.dragFrom(
      Offset(layout.phone.size.width / 2, layout.rider.top - 120),
      const Offset(0, 80),
    );
    await tester.pumpAndSettle();
    final follow = tester.getRect(
      find.byKey(const Key('navigation-follow-button')),
    );
    final banner = tester.getRect(
      find.byKey(const Key('navigation-guidance-banner')),
    );
    final band = tester.getRect(find.byKey(portraitBottomChromeKey));
    expect(follow.top, greaterThanOrEqualTo(band.top));
    expect(follow.bottom, lessThanOrEqualTo(banner.top));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('the system text size the chrome follows', () {
    test('Small and Medium follow it up to 1.3, and Large not at all', () {
      expect(rideChromeTextScaleCeiling(RidingDisplaySize.small), 1.3);
      expect(
        rideChromeTextScaleCeiling(RidingDisplaySize.medium),
        closeTo(1.65 / 1.3, 1e-9),
      );
      expect(rideChromeTextScaleCeiling(RidingDisplaySize.large), 1.0);
    });

    test('no size is ever drawn bigger than Large with default text', () {
      for (final size in RidingDisplaySize.values) {
        final ceiling = rideChromeTextScaleCeiling(size);
        expect(ceiling, greaterThanOrEqualTo(1.0));
        expect(ceiling, lessThanOrEqualTo(rideChromeMaximumTextScale));
        expect(
          size.scale * ceiling,
          lessThanOrEqualTo(RidingDisplaySize.large.scale + 1e-9),
          reason: '${size.label} stacks the system scale on its own',
        );
      }
    });

    test('a bigger size never follows the system further than a smaller', () {
      var previous = double.infinity;
      for (final size in RidingDisplaySize.values) {
        final ceiling = rideChromeTextScaleCeiling(size);
        expect(ceiling, lessThanOrEqualTo(previous));
        previous = ceiling;
      }
    });
  });

  group('the forward cone', () {
    // The helper that decides every other assertion in this file, so it is held
    // to a case it must catch and a case it must let through.
    test('a surface across the middle of the road ahead is caught', () {
      final cone = _forwardCone(
        rider: const Rect.fromLTWH(177, 330, 38, 38),
        top: 100,
      );
      // Where the ETA card used to float, 154 pixels from the top.
      expect(cone.intersects(const Rect.fromLTWH(12, 154, 210, 78)), isTrue);
      // A corner glance up in the top row is not in the road ahead.
      expect(cone.intersects(const Rect.fromLTWH(254, 12, 124, 88)), isFalse);
      // Nor is anything below the marker.
      expect(cone.intersects(const Rect.fromLTWH(12, 440, 366, 80)), isFalse);
    });

    test('a marker that is already in the top row has no cone to cover', () {
      final cone = _forwardCone(
        rider: const Rect.fromLTWH(177, 60, 38, 38),
        top: 100,
      );
      expect(cone.isEmpty, isTrue);
      expect(cone.intersects(const Rect.fromLTWH(0, 0, 400, 800)), isFalse);
    });
  });
}

/// One laid-out ride map: every rectangle the assertions look at.
class _Layout {
  _Layout({
    required this.phone,
    required this.reason,
    required this.rider,
    required this.band,
    required this.rects,
  });

  final _Phone phone;
  final String reason;

  /// The rider's own marker.
  final Rect rider;

  /// The bottom band the camera measures.
  final Rect band;

  /// Every keyed surface that exists, by key.
  final Map<String, Rect> rects;

  /// Where the top row ends: the lowest edge of the menu, clock and speed sign.
  double get topRowBottom => rects.entries
      .where((entry) => _topRowKeys.contains(entry.key))
      .map((entry) => entry.value.bottom)
      .fold<double>(0, math.max);
}

void _expectMarkerAndConeClear(_Layout layout, {required String reason}) {
  final everything = {...layout.rects, 'the bottom band': layout.band};
  // The marker is never under anything - not the band, and not the corner row.
  for (final entry in everything.entries) {
    expect(
      layout.rider.deflate(0.5).overlaps(entry.value.deflate(0.5)),
      isFalse,
      reason:
          '$reason: the marker ${layout.rider} is under ${entry.key} '
          '${entry.value}',
    );
  }
  // The rider is on screen, not pushed past an edge to make room.
  expect(layout.rider.top, greaterThanOrEqualTo(layout.phone.top));
  expect(layout.rider.bottom, lessThan(layout.band.top), reason: reason);

  // Nothing navigational sits across the road ahead of it.
  final cone = _forwardCone(rider: layout.rider, top: layout.topRowBottom);
  for (final key in _navigationalKeys) {
    final rect = layout.rects[key];
    if (rect == null) continue;
    expect(
      cone.intersects(rect),
      isFalse,
      reason:
          '$reason: $key $rect is in the forward cone ahead of '
          '${layout.rider}',
    );
    expect(
      rect.top,
      greaterThanOrEqualTo(layout.rider.bottom),
      reason: '$reason: $key is over the road ahead',
    );
  }
  expect(
    cone.intersects(layout.band),
    isFalse,
    reason: '$reason: the band ${layout.band} is in the forward cone',
  );
}

/// The triangle of map a rider reads the road ahead in: from the top of the
/// marker, [_forwardConeHalfAngleDegrees] either side of straight up, to the
/// bottom of the top row, which is the glance row #125 and #133 left above it.
_Cone _forwardCone({required Rect rider, required double top}) {
  final apex = Offset(rider.center.dx, rider.top);
  final height = apex.dy - top;
  if (height <= 0) return const _Cone.empty();
  final reach = height * math.tan(_forwardConeHalfAngleDegrees * math.pi / 180);
  return _Cone([
    apex,
    Offset(apex.dx - reach, top),
    Offset(apex.dx + reach, top),
  ]);
}

class _Cone {
  const _Cone(this.triangle);
  const _Cone.empty() : triangle = const [];

  final List<Offset> triangle;

  bool get isEmpty => triangle.isEmpty;

  /// Whether the open triangle shares area with [rect]. Touching an edge does
  /// not count: two surfaces that meet are not covering each other.
  bool intersects(Rect rect) {
    if (isEmpty) return false;
    final box = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    for (final polygon in [triangle, box]) {
      for (var index = 0; index < polygon.length; index += 1) {
        final a = polygon[index];
        final b = polygon[(index + 1) % polygon.length];
        final axis = Offset(-(b.dy - a.dy), b.dx - a.dx);
        final first = _project(triangle, axis);
        final second = _project(box, axis);
        if (first.$2 <= second.$1 || second.$2 <= first.$1) return false;
      }
    }
    return true;
  }

  static (double, double) _project(List<Offset> points, Offset axis) {
    final values = [
      for (final point in points) point.dx * axis.dx + point.dy * axis.dy,
    ];
    return (values.reduce(math.min), values.reduce(math.max));
  }
}

Future<_Layout> _pump(
  WidgetTester tester, {
  required _Phone phone,
  required RidingDisplaySize display,
  required double textScale,
  required bool leader,
}) async {
  tester.view.physicalSize = phone.size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: phone.top, bottom: phone.bottom);
  tester.view.viewPadding = FakeViewPadding(
    top: phone.top,
    bottom: phone.bottom,
  );
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  final directory = Directory.systemTemp.createTempSync('portrait-chrome');
  addTearDown(() => directory.deleteSync(recursive: true));

  // The worst turn banner: a roundabout with lane guidance and a second turn
  // close behind it, so the "then" row and the lane strip are both drawn.
  final route = ImportedRoute(
    id: 'portrait-chrome',
    name: 'Portrait chrome',
    importedAt: DateTime.utc(2026, 10, 4),
    sourceFileName: 'portrait-chrome.gpx',
    paths: const [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 53, longitude: -1.02),
          GeoPoint(latitude: 53, longitude: -1.01),
          GeoPoint(latitude: 53, longitude: -1),
        ],
      ),
    ],
    waypoints: const [],
    maneuvers: const [
      RouteManeuver(
        position: GeoPoint(latitude: 53, longitude: -1.005),
        type: 'roundabout',
        modifier: 'right',
        name: 'Station Road',
        exitNumber: 3,
        drivingSide: 'left',
        lanes: [
          RouteLane(indications: ['left'], valid: false),
          RouteLane(indications: ['straight', 'right'], valid: true),
        ],
      ),
      RouteManeuver(
        position: GeoPoint(latitude: 53, longitude: -1.0048),
        type: 'turn',
        modifier: 'left',
        name: 'High Street',
        drivingSide: 'left',
      ),
    ],
  );
  final navigation = ValueNotifier<MapNavigationPosition?>(
    MapNavigationPosition(
      point: const GeoPoint(latitude: 53, longitude: -1.015),
      recordedAt: DateTime.utc(2026, 10, 4, 12),
      speedMetersPerSecond: 13,
      headingDegrees: 90,
      accuracyMeters: 5,
    ),
  );
  addTearDown(navigation.dispose);
  final speedLimit = SpeedLimitDisplayController.inMemory();
  addTearDown(speedLimit.dispose);
  final riders = ValueNotifier<List<MapOverlayMarker>>([
    const MapOverlayMarker(
      id: 'rider-alex',
      point: GeoPoint(latitude: 53, longitude: -1.011),
      label: 'Alex',
    ),
    const MapOverlayMarker(
      id: 'rider-charlie',
      point: GeoPoint(latitude: 53, longitude: -1.017),
      label: 'Charlie',
    ),
  ]);
  addTearDown(riders.dispose);
  // A leader sees the gap to the Tail End Charlie, which is one more surface in
  // the band.
  final leaderStatus = ValueNotifier<LeaderRideStatus?>(
    const LeaderRideStatus(
      tecName: 'Charlie',
      distanceToTecMeters: 3200,
      estimatedTimeToTec: Duration(minutes: 4),
      tecLocationAge: Duration(seconds: 10),
      offCourseAlerts: [],
    ),
  );
  addTearDown(leaderStatus.dispose);
  final cache = OfflineTileCache(
    rootDirectory: directory,
    configuration: const BasemapConfiguration(),
    httpClient: MockClient((_) async => http.Response('', 404)),
  );
  addTearDown(cache.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: _loadedFont
            ? Typography.material2021().white.apply(fontFamily: 'Roboto')
            : null,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RideMapScreen(
        key: UniqueKey(),
        routeStore: InMemoryRouteStore(route),
        routeImporter: RouteImporter(source: const _NoFileSource()),
        offlineTileCache: cache,
        navigationPosition: navigation,
        overlayMarkers: riders,
        leaderStatus: leader ? leaderStatus : null,
        groupRiderCount: 3,
        distanceUnit: DistanceUnit.miles,
        ridingDisplaySize: display,
        speedLimitDisplay: speedLimit,
        onOpenRideMenu: () async {},
        onEmergencyAlert: () async {},
        onLeaveRide: () async {},
        onReportHazard: (_) async {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();

  final rects = <String, Rect>{
    for (final key in [..._navigationalKeys, ..._topRowKeys])
      if (find.byKey(Key(key)).evaluate().isNotEmpty)
        key: tester.getRect(find.byKey(Key(key))),
  };
  final marker = find
      .byWidgetPredicate(
        (widget) => widget is RiderMarkerBadge && widget.mapMarker,
      )
      .first;
  return _Layout(
    phone: phone,
    reason:
        '$phone, ${display.name}, text x$textScale, '
        '${leader ? 'leader' : 'rider'}',
    rider: tester.getRect(marker),
    band: tester.getRect(find.byKey(portraitBottomChromeKey)),
    rects: rects,
  );
}

/// The Material fonts that ship with the Flutter SDK, so the text in these
/// measurements has real widths. The default test font draws every glyph as a
/// square of the font size, which doubles the width of every string and makes
/// each wrap that a phone never has.
///
/// Optional: with no SDK font the block font is used, and every assertion here
/// holds under it too - that is the pessimistic case.
bool _loadedFont = false;

Future<void> _loadRoboto() async {
  final executable = Platform.resolvedExecutable;
  final cache = executable.indexOf('/bin/cache/');
  if (cache < 0) return;
  final directory = Directory(
    '${executable.substring(0, cache)}/bin/cache/artifacts/material_fonts',
  );
  final files = [
    for (final name in const [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
      'Roboto-Black.ttf',
    ])
      File('${directory.path}/$name'),
  ];
  if (files.any((file) => !file.existsSync())) return;
  final loader = FontLoader('Roboto');
  for (final file in files) {
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
  _loadedFont = true;
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
