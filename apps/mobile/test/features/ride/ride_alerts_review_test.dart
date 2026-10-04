import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_alert_record.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/ride/previous_rides_screen.dart';
import 'package:ride_relay/features/ride/ride_alerts_card.dart';
import 'package:ride_relay/services/map_style_repository.dart';

/// #849: after the ride, every alert is listed with its time to the second and
/// plotted where it was raised, and each time is one tap from the clipboard so it
/// can be found in dash-cam footage.
void main() {
  // Isle of Man: nowhere near any rider's home.
  final firstAlert = RideAlertRecord(
    id: 'alert-1',
    // Built from local components so the time on screen does not depend on the
    // zone the test runs in.
    raisedAt: DateTime(2026, 10, 4, 14, 32, 7).toUtc(),
    position: const awareness.GeoPoint(latitude: 54.15, longitude: -4.48),
    raisedBy: 'Nigel',
  );
  final secondAlert = RideAlertRecord(
    id: 'alert-2',
    raisedAt: DateTime(2026, 10, 4, 15, 1, 2).toUtc(),
    position: const awareness.GeoPoint(latitude: 54.2, longitude: -4.5),
    raisedBy: 'Oliver',
    raisedByLocalRider: true,
  );
  final olderBuildAlert = RideAlertRecord(
    id: 'alert-3',
    raisedAt: DateTime(2026, 10, 4, 15, 40, 59).toUtc(),
    position: const awareness.GeoPoint(latitude: 54.21, longitude: -4.51),
    raisedBy: 'Becks',
    kind: RideAlertKind.speedCamera,
  );

  /// Records what the app writes to the clipboard.
  List<String> captureClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return copied;
  }

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  group('the alerts card', () {
    testWidgets('lists each alert with its time to the second, who and where', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          RideAlertsCard(alerts: [firstAlert, secondAlert, olderBuildAlert]),
        ),
      );

      expect(find.text('3 alerts'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-alert-time-alert-1')))
            .data,
        '14:32:07',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-alert-time-alert-2')))
            .data,
        '15:01:02',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-alert-detail-alert-1')))
            .data,
        'Nigel · 54.15000, -4.48000',
      );
      // The rider's own, and one an older build raised as a speed camera.
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-alert-detail-alert-2')))
            .data,
        'Oliver (you) · 54.20000, -4.50000',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-alert-detail-alert-3')))
            .data,
        'Becks · speed camera · 54.21000, -4.51000',
      );
    });

    testWidgets('says what zone the times are in', (tester) async {
      await tester.pumpWidget(host(RideAlertsCard(alerts: [firstAlert])));

      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-alerts-time-note')))
            .data,
        allOf(contains('to the second'), contains('UTC')),
      );
    });

    testWidgets('says "1 alert", not "1 alerts"', (tester) async {
      await tester.pumpWidget(host(RideAlertsCard(alerts: [firstAlert])));

      expect(find.text('1 alert'), findsOneWidget);
    });

    testWidgets('tapping a time copies it in the form footage shows', (
      tester,
    ) async {
      final copied = captureClipboard(tester);
      await tester.pumpWidget(
        host(RideAlertsCard(alerts: [firstAlert, secondAlert])),
      );

      await tester.tap(find.byKey(const Key('ride-alert-row-alert-1')));
      await tester.pump();

      expect(copied, ['2026-10-04 14:32:07']);
      expect(find.text('Copied 2026-10-04 14:32:07'), findsOneWidget);
    });

    testWidgets('the copy button copies the same thing', (tester) async {
      final copied = captureClipboard(tester);
      await tester.pumpWidget(
        host(RideAlertsCard(alerts: [firstAlert, secondAlert])),
      );

      await tester.tap(find.byKey(const Key('ride-alert-copy-alert-2')));
      await tester.pump();

      expect(copied, ['2026-10-04 15:01:02']);
    });

    testWidgets('"Copy all" copies a line per alert, oldest first', (
      tester,
    ) async {
      final copied = captureClipboard(tester);
      await tester.pumpWidget(
        host(RideAlertsCard(alerts: [firstAlert, secondAlert])),
      );

      await tester.tap(find.byKey(const Key('ride-alerts-copy-all')));
      await tester.pump();

      expect(copied, hasLength(1));
      final lines = copied.single.split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, startsWith('2026-10-04 14:32:07 ('));
      expect(lines.first, contains('Nigel'));
      expect(lines.last, startsWith('2026-10-04 15:01:02 ('));
      expect(find.text('Copied all 2 alerts'), findsOneWidget);
    });

    testWidgets('every time can be hit with a thumb', (tester) async {
      await tester.pumpWidget(host(RideAlertsCard(alerts: [firstAlert])));

      expect(
        tester.getSize(find.byKey(const Key('ride-alert-row-alert-1'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(find.byKey(const Key('ride-alert-copy-alert-1')))
            .shortestSide,
        greaterThanOrEqualTo(40),
      );
    });

    testWidgets('has a spoken label for each alert', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(RideAlertsCard(alerts: [firstAlert])));

      expect(
        find.bySemanticsLabel(
          'Alert at 14:32:07, raised by Nigel, 54.15000, -4.48000',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('shows nothing at all when the ride raised none', (
      tester,
    ) async {
      await tester.pumpWidget(host(const RideAlertsCard(alerts: [])));

      expect(find.byKey(const Key('ride-alerts-card')), findsNothing);
      expect(find.textContaining('alert'), findsNothing);
    });
  });

  group('a previous ride', () {
    Future<void> openRide(WidgetTester tester, CompletedRide ride) async {
      final store = InMemoryCompletedRideStore();
      await store.save(ride);
      final completed = await CompletedRidesController.load(store);
      await tester.pumpWidget(
        MaterialApp(
          home: PreviousRideDetailScreen(
            ride: ride,
            completedRides: completed,
            distanceUnits: DistanceUnitController.forLocale(
              const Locale('en', 'GB'),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('lists its alerts under the map, with a legend key', (
      tester,
    ) async {
      // Tall enough that the list builds every child, so the order can be read.
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openRide(tester, _ride(alerts: [firstAlert, secondAlert]));

      expect(find.byKey(const Key('ride-alerts-card')), findsOneWidget);
      expect(find.text('2 alerts'), findsOneWidget);
      expect(find.text('14:32:07'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('archived-ride-legend')),
          matching: find.text('Alert'),
        ),
        findsOneWidget,
      );
      // The card sits between the map and the ride's own actions.
      final map = tester.getRect(
        find.byKey(const Key('archived-ride-expand-map')),
      );
      final card = tester.getRect(find.byKey(const Key('ride-alerts-card')));
      final rideAgain = tester.getRect(
        find.byKey(const Key('archived-ride-again')),
      );
      expect(card.top, greaterThan(map.bottom));
      expect(card.bottom, lessThanOrEqualTo(rideAgain.top));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a ride with no alerts shows no card and no legend key', (
      tester,
    ) async {
      await openRide(tester, _ride());

      expect(find.byKey(const Key('ride-alerts-card')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('archived-ride-legend')),
          matching: find.text('Alert'),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the review map', () {
    test(
      'plots one point per alert, labelled with its time, longitude first',
      () {
        final geoJson = archivedRideAlertGeoJson([firstAlert, secondAlert]);

        final features = geoJson['features'] as List;
        expect(features, hasLength(2));
        final first = features.first as Map;
        expect(first['id'], 'alert-1');
        expect((first['geometry'] as Map)['coordinates'], [-4.48, 54.15]);
        expect((first['properties'] as Map)['label'], '14:32:07');
        expect((first['properties'] as Map)['raisedBy'], 'Nigel');
        expect((first['properties'] as Map)['time'], '2026-10-04 14:32:07');
        expect(
          ((features.last as Map)['properties'] as Map)['label'],
          '15:01:02',
        );
      },
    );

    testWidgets('puts the alerts on the native map above the track', (
      tester,
    ) async {
      final calls = await _mountArchivedMap(
        tester,
        alerts: [firstAlert, secondAlert],
      );

      final source = calls.singleWhere(
        (call) =>
            call.method == 'source#addGeoJson' &&
            (call.arguments as Map)['sourceId'] == 'archived-alert-source',
      );
      final features =
          (jsonDecode((source.arguments as Map)['geojson'] as String)
                  as Map)['features']
              as List;
      expect(features, hasLength(2));
      expect((features.first['geometry'] as Map)['coordinates'], [
        -4.48,
        54.15,
      ]);

      final layerOrder = [
        for (final call in calls)
          if (call.method == 'lineLayer#add' ||
              call.method == 'circleLayer#add' ||
              call.method == 'symbolLayer#add')
            '${(call.arguments as Map)['sourceId']}',
      ];
      expect(
        layerOrder.lastIndexOf('archived-alert-source'),
        greaterThan(layerOrder.lastIndexOf('archived-track-source')),
        reason: 'a marker must not be hidden under the line it was raised on',
      );
      expect(
        calls.where(
          (call) =>
              call.method == 'circleLayer#add' &&
              (call.arguments as Map)['sourceId'] == 'archived-alert-source',
        ),
        hasLength(1),
      );
      expect(
        calls.where(
          (call) =>
              call.method == 'symbolLayer#add' &&
              (call.arguments as Map)['sourceId'] == 'archived-alert-source',
        ),
        hasLength(1),
      );
    });

    testWidgets('a ride with no alerts adds no alert layers', (tester) async {
      final calls = await _mountArchivedMap(tester, alerts: const []);

      expect(
        calls.where(
          (call) =>
              (call.arguments is Map) &&
              (call.arguments as Map)['sourceId'] == 'archived-alert-source',
        ),
        isEmpty,
      );
    });
  });
}

/// Mounts the archived map over a mocked MapLibre channel, lets its style load,
/// and returns every call the map made - the same harness
/// `archived_ride_native_markers_test.dart` uses for the endpoint markers.
Future<List<MethodCall>> _mountArchivedMap(
  WidgetTester tester, {
  required List<RideAlertRecord> alerts,
}) async {
  final original = ml.MapLibrePlatform.createInstance;
  final calls = <MethodCall>[];
  // One channel per platform view the framework has made in this test run, so a
  // second mount in the same file finds a handler too.
  final channels = [
    for (var id = 0; id < 8; id += 1)
      MethodChannel('plugins.flutter.io/maplibre_gl_$id'),
  ];
  const views = MethodChannel('flutter/platform_views');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(views, (call) async {
        if (call.method == 'create') return 0;
        if (call.method == 'resize') {
          final args = call.arguments as Map;
          return {'width': args['width'], 'height': args['height']};
        }
        return null;
      });
  for (final channel in channels) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  }
  ml.MapLibrePlatform.createInstance = () {
    final platform = ml.MapLibreMethodChannel();
    unawaited(platform.initPlatform(0));
    return platform;
  };
  addTearDown(() {
    ml.MapLibrePlatform.createInstance = original;
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(views, null);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ArchivedRideMap(
          plannedRoute: null,
          traveledRoute: _track(),
          alerts: alerts,
          mapStyleString: MapStyleRepository.fallbackStyle,
        ),
      ),
    ),
  );
  await tester.pump();
  final map = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
  final platform = ml.MapLibreMethodChannel();
  await platform.initPlatform(0);
  final controller = ml.MapLibreMapController(
    maplibrePlatform: platform,
    annotationOrder: const [],
    annotationConsumeTapEvents: const [],
  );
  map.onMapCreated!(controller);
  map.onStyleLoadedCallback!();
  // Native rasterisation runs on the engine; let it finish, then drain the
  // map's initial-fit timer.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 350)),
  );
  await tester.pump(const Duration(seconds: 1));
  return calls;
}

ImportedRoute _track() => ImportedRoute(
  id: 'ridden',
  name: 'Recorded',
  importedAt: DateTime.utc(2026, 10, 4),
  sourceFileName: 'ride.gpx',
  waypoints: const [],
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 54.14, longitude: -4.48),
        GeoPoint(latitude: 54.22, longitude: -4.52),
      ],
    ),
  ],
);

CompletedRide _ride({List<RideAlertRecord> alerts = const []}) => CompletedRide(
  rideId: 'ride-1',
  rideCode: '123456',
  rideName: 'Day out',
  localDisplayName: 'Oliver',
  localRole: RideRole.lead,
  startedAt: DateTime.utc(2026, 10, 4, 12),
  endedAt: DateTime.utc(2026, 10, 4, 15),
  archivedAt: DateTime.utc(2026, 10, 4, 15),
  riderCount: 3,
  eventCount: 12,
  totalDistanceMeters: 42000,
  markerSessions: const [],
  plannedRoute: null,
  traveledRoute: _track(),
  alerts: alerts,
);
