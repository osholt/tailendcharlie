import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/services/enforcement_alert_detector.dart';
import 'package:ride_relay/services/external_hazard_provider.dart';
import 'package:ride_relay/services/fixed_speed_camera_catalogue.dart';
import 'package:ride_relay/services/fixed_speed_camera_provider.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/features/map/hazard_map_symbol.dart';

String _catalogueJson(List<Map<String, Object?>> cameras) => jsonEncode({
  'type': 'FeatureCollection',
  'properties': {
    'attribution': '© OpenStreetMap contributors, ODbL',
    'boundedRegion': 'Great Britain',
    'extractDate': '2026-08-07',
    'count': cameras.length,
  },
  'features': [
    for (final camera in cameras)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [camera['lon'], camera['lat']],
        },
        'properties': {
          'osmId': camera['osmId'],
          if (camera['role'] != null) 'role': camera['role'],
          if (camera['maxspeed'] != null) 'maxspeed': camera['maxspeed'],
        },
      },
  ],
});

/// A straight run east along a single latitude, so distances off it are easy
/// to reason about.
const _route = <GeoPoint>[
  GeoPoint(latitude: 51.5000, longitude: -2.5000),
  GeoPoint(latitude: 51.5000, longitude: -2.4000),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the shipped layer', () {
    // Guards the asset itself, not the code that reads it. A regeneration that
    // dropped the provenance, swapped the coordinate order or came from a
    // partly failed fetch would still parse; none of that would show up in a
    // test built on a hand-written fixture.
    test('loads, and says where it came from and when', () async {
      final catalogue = await FixedSpeedCameraCatalogue.load();

      expect(catalogue.cameras.length, greaterThan(2500));
      expect(catalogue.attribution, contains('OpenStreetMap'));
      expect(catalogue.attribution, contains('ODbL'));
      expect(catalogue.extractDate, isNotEmpty);
      expect(catalogue.boundedRegion, isNotEmpty);
    });

    test('every camera lands in the British Isles', () async {
      final catalogue = await FixedSpeedCameraCatalogue.load();

      for (final camera in catalogue.cameras) {
        // GeoJSON is longitude first. Reading the pair the wrong way round puts
        // every camera in the Indian Ocean, where the corridor filter finds
        // none and the layer silently warns about nothing.
        expect(camera.position.latitude, inInclusiveRange(49.0, 61.5));
        expect(camera.position.longitude, inInclusiveRange(-9.0, 2.5));
      }
    });

    test('finds the cameras along a real route quickly', () async {
      final catalogue = await FixedSpeedCameraCatalogue.load();
      // Bristol to Bath along the A4, the kind of leg this app is used for.
      const leg = <GeoPoint>[
        GeoPoint(latitude: 51.4545, longitude: -2.5879),
        GeoPoint(latitude: 51.4400, longitude: -2.4500),
        GeoPoint(latitude: 51.3900, longitude: -2.3600),
      ];

      final stopwatch = Stopwatch()..start();
      catalogue.near(leg);
      stopwatch.stop();

      // A whole-country layer scanned on the way into a ride. Generous, but it
      // fails loudly if the bounding-box prefilter is ever lost.
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });
  });

  group('FixedSpeedCameraCatalogue', () {
    test('carries the licence and the extract date', () {
      final catalogue = FixedSpeedCameraCatalogue.parse(
        _catalogueJson([
          {'osmId': 'node/1', 'lat': 51.5, 'lon': -2.45},
        ]),
      );

      expect(catalogue.attribution, contains('ODbL'));
      expect(catalogue.extractDate, '2026-08-07');
      expect(catalogue.boundedRegion, 'Great Britain');
    });

    test('keeps a camera on the route and drops one on a parallel road', () {
      final catalogue = FixedSpeedCameraCatalogue.parse(
        _catalogueJson([
          {'osmId': 'node/1', 'lat': 51.5000, 'lon': -2.4500},
          // ~1.1 km north: a different road the group is not riding.
          {'osmId': 'node/2', 'lat': 51.5100, 'lon': -2.4500},
        ]),
      );

      final found = catalogue.near(_route, corridorMeters: 250);

      expect(found.map((camera) => camera.osmId), ['node/1']);
    });

    test('rejects a camera inside the bounding box but off every leg', () {
      // The bounding box is only a cheap prefilter. On a route that turns, the
      // box covers a large area the ride never enters, and a camera sitting in
      // that corner must still be rejected on its real distance to the road.
      const cornerRoute = <GeoPoint>[
        GeoPoint(latitude: 51.5000, longitude: -2.5000),
        GeoPoint(latitude: 51.5000, longitude: -2.4000),
        GeoPoint(latitude: 51.5500, longitude: -2.4000),
      ];
      final catalogue = FixedSpeedCameraCatalogue.parse(
        _catalogueJson([
          // Kilometres from both legs, comfortably inside the box they span.
          {'osmId': 'node/corner', 'lat': 51.5400, 'lon': -2.4900},
          {'osmId': 'node/on-leg', 'lat': 51.5000, 'lon': -2.4500},
        ]),
      );

      expect(
        catalogue.near(cornerRoute, corridorMeters: 250).map((c) => c.osmId),
        ['node/on-leg'],
      );
    });

    test('rejects a camera far outside the route bounding box', () {
      final catalogue = FixedSpeedCameraCatalogue.parse(
        _catalogueJson([
          {'osmId': 'node/9', 'lat': 57.1000, 'lon': -2.4500},
        ]),
      );

      expect(catalogue.near(_route), isEmpty);
    });

    test('describes an untagged camera without inventing detail', () {
      final catalogue = FixedSpeedCameraCatalogue.parse(
        _catalogueJson([
          {'osmId': 'node/1', 'lat': 51.5, 'lon': -2.45},
          {
            'osmId': 'node/2',
            'lat': 51.5,
            'lon': -2.44,
            'role': 'average',
            'maxspeed': '50 mph',
          },
        ]),
      );

      expect(catalogue.cameras.first.description, 'Fixed speed camera');
      expect(catalogue.cameras.last.description, 'Average speed camera · 50 mph limit');
    });

    test('survives a malformed feature rather than losing the layer', () {
      final catalogue = FixedSpeedCameraCatalogue.parse(
        jsonEncode({
          'type': 'FeatureCollection',
          'features': [
            {'type': 'Feature', 'geometry': null, 'properties': {}},
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [-2.45, 51.5],
              },
              'properties': {'osmId': 'node/7'},
            },
          ],
        }),
      );

      expect(catalogue.cameras.map((camera) => camera.osmId), ['node/7']);
    });
  });

  group('FixedSpeedCameraProvider', () {
    FixedSpeedCameraProvider provider() => FixedSpeedCameraProvider.ready(
      FixedSpeedCameraCatalogue.parse(
        _catalogueJson([
          {'osmId': 'node/1', 'lat': 51.5000, 'lon': -2.4500},
        ]),
      ),
    );

    ExternalHazardQuery query(DateTime at) => ExternalHazardQuery(
      rideId: 'ride-1',
      route: _route,
      requestedAt: at,
    );

    test('credits the extract, never a rider', () async {
      final result = await provider().fetch(query(DateTime.utc(2026, 8, 7)));

      final hazard = result.hazards.single;
      expect(hazard.source, HazardSource.externalProvider);
      expect(hazard.providerId, FixedSpeedCameraProvider.providerId);
      expect(hazard.type, HazardType.speedCamera);
    });

    test('does not inherit the two-hour expiry of a rider sighting', () async {
      final now = DateTime.utc(2026, 8, 7, 9);
      final result = await provider().fetch(query(now));

      // The specific defect: a permanent roadside object silently lapsing
      // partway through a long ride because it borrowed the lifetime meant for
      // a patrol car that has moved on.
      expect(
        result.hazards.single.expiresAt.difference(now),
        greaterThan(const Duration(days: 1)),
      );
      expect(result.hazards.single.isActiveAt(now.add(const Duration(hours: 8))), isTrue);
    });

    test('gives the same camera the same id for every rider', () async {
      final first = await provider().fetch(query(DateTime.utc(2026, 8, 7)));
      final second = await provider().fetch(query(DateTime.utc(2026, 8, 8)));

      expect(first.hazards.single.id, second.hazards.single.id);
      expect(first.hazards.single.id, contains('node-1'));
    });

    test('reaches the warning the rider already had for a sighting', () async {
      final now = DateTime.utc(2026, 8, 7);
      final result = await provider().fetch(query(now));

      final alert = const EnforcementAlertDetector().detect(
        position: const GeoPoint(latitude: 51.5000, longitude: -2.4600),
        hazards: result.hazards,
        now: now,
        route: _route,
      );

      expect(alert, isNotNull);
      expect(alert!.hazard.providerId, FixedSpeedCameraProvider.providerId);
      expect(alert.distanceMeters, lessThan(1609.344));
    });

    test('an empty layer reports itself unavailable, not "no cameras"', () {
      final provider = FixedSpeedCameraProvider.ready(
        FixedSpeedCameraCatalogue.empty,
      );

      expect(provider.status.state, ExternalHazardProviderState.unavailable);
      expect(provider.status.canFetch, isFalse);
      expect(provider.status.message.toLowerCase(), isNot(contains('no cameras here')));
    });

    test('never reads as something a rider just saw', () async {
      final now = DateTime.utc(2026, 8, 7);
      final camera = (await provider().fetch(query(now))).hazards.single;

      expect(camera.isStandingRecord, isTrue);
      final text = HazardMapSymbols.describe(camera, now: now);
      // The defect this guards: a permanent camera described as seen "just
      // now" tells a rider a patrol is out when nothing was observed at all.
      expect(text, isNot(contains('just now')));
      expect(text, isNot(contains('ago')));
      expect(text, contains('fixed'));
    });

    test('does not fade weeks after the extract was read', () async {
      final now = DateTime.utc(2026, 8, 7);
      final camera = (await provider().fetch(query(now))).hazards.single;

      // Well past the point where a rider report would be dashed and dulled.
      final late = now.add(const Duration(days: 27));
      expect(
        HazardMapSymbols.freshnessFor(camera, late),
        HazardMapFreshness.fresh,
      );
    });

    test('a rider sighting still ages normally', () {
      final reported = DateTime.utc(2026, 8, 7, 9);
      final sighting = HazardReport(
        id: 'r1',
        rideId: 'ride-1',
        type: HazardType.speedCamera,
        severity: HazardSeverity.serious,
        position: const GeoPoint(latitude: 51.5, longitude: -2.45),
        reportedAt: reported,
        updatedAt: reported,
        expiresAt: reported.add(const Duration(hours: 2)),
        reporterId: 'rider-1',
        reporterName: 'Dan',
        source: HazardSource.rider,
      );

      expect(sighting.isStandingRecord, isFalse);
      expect(
        HazardMapSymbols.freshnessFor(
          sighting,
          reported.add(const Duration(minutes: 110)),
        ),
        HazardMapFreshness.fading,
      );
      expect(
        HazardMapSymbols.describe(sighting, now: reported.add(const Duration(minutes: 5))),
        contains('5 min ago'),
      );
    });

    test('does not read the catalogue until it is asked for hazards', () async {
      // Setting a ride up must not wait on a file. Reading the asset while the
      // awareness controller was being built stalled the frame loop until
      // pumpAndSettle gave up, so construction has to stay free.
      var reads = 0;
      final provider = FixedSpeedCameraProvider(
        readCatalogue: () async {
          reads += 1;
          return FixedSpeedCameraCatalogue.parse(
            _catalogueJson([
              {'osmId': 'node/1', 'lat': 51.5000, 'lon': -2.4500},
            ]),
          );
        },
      );

      expect(reads, 0);
      expect(provider.status.canFetch, isTrue);

      await provider.fetch(query(DateTime.utc(2026, 8, 7)));
      await provider.fetch(query(DateTime.utc(2026, 8, 8)));

      // And only once, however many times the ride refreshes its hazards.
      expect(reads, 1);
    });

    test('states the coverage limit where a rider can read it', () {
      expect(provider().status.message, contains('does not list every camera'));
      expect(provider().status.message, contains('2026-08-07'));
    });
  });
}
