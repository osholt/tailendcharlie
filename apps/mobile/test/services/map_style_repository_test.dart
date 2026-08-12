import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/features/map/route_trail_style.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/map_style_repository.dart';

/// A `#rrggbb` paint string as an opaque colour, so the palette can be measured
/// where it is actually declared rather than restated as `Color` literals.
Color paint(String hex) =>
    Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

/// CIE L* lightness, 0 (black) to 100 (white).
///
/// WCAG's contrast ratio adds a 0.05 flare term that compresses every
/// dark-on-dark pair towards 1:1: the old `#565656` motorway fill on the old
/// `#1C1C1E` background measured 2.32:1 and its minor roads 1.50:1, numbers that
/// look survivable and were not - a tester called the result "a pretty dark grey
/// on top of a slightly darker grey" (#143). L* is perceptually uniform and does
/// not compress, so the bands of the dark basemap are held apart in L* and the
/// WCAG ratio is reported alongside rather than relied on.
double lightness(Color color) {
  final y = relativeLuminance(color);
  return y > 0.008856 ? 116 * math.pow(y, 1 / 3) - 16 : 903.3 * y;
}

Color surface(String name) =>
    paint(MapStyleRepository.darkBasemapPalette[name]!);

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ride-relay-style-test');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'falls back to a local style when configured service is offline',
    () async {
      final repository = MapStyleRepository(
        directory: directory,
        configuration: _configuration,
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      final style = jsonDecode((await repository.resolve()).style) as Map;

      expect(style['name'], 'Tail End Charlie offline fallback');
      expect(style['sources'], isEmpty);
    },
  );

  test('normalizes and caches relative style resources', () async {
    final repository = MapStyleRepository(
      directory: directory,
      configuration: _configuration,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': 8,
            'sprite': './sprite',
            'glyphs': './fonts/{fontstack}/{range}.pbf',
            'sources': {
              'basemap': {
                'type': 'vector',
                'tiles': ['../tiles/basemap/{z}/{x}/{y}'],
              },
            },
            'layers': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final style = jsonDecode((await repository.resolve()).style) as Map;
    final source = (style['sources'] as Map)['basemap'] as Map;

    expect(style['sprite'], 'https://maps.example.test/styles/sprite');
    expect(
      (source['tiles'] as List).single,
      'https://maps.example.test/tiles/basemap/{z}/{x}/{y}',
    );
    expect(await directory.list().where((item) => item is File).length, 1);
  });

  test(
    'repaints the fetched dark style toward a more legible palette',
    () async {
      final repository = MapStyleRepository(
        directory: directory,
        configuration: _darkConfiguration,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(_darkStyleFixture),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      final style = jsonDecode((await repository.resolve()).style) as Map;
      final layers = (style['layers'] as List).cast<Map>();
      Map paintOf(String id) =>
          layers.singleWhere((layer) => layer['id'] == id)['paint'] as Map;

      expect(
        paintOf('background')['background-color'],
        MapStyleRepository.darkBasemapPalette['background'],
      );
      expect(paintOf('highway_minor')['line-color'], isNot('#181818'));
      // Properties the table does not name survive, and a layer the table does
      // not name is untouched entirely.
      expect(paintOf('highway_minor')['line-blur'], 0.4);
      expect(paintOf('unrelated_layer'), isEmpty);
    },
  );

  test('splits the one major-road layer back into a class ramp', () async {
    // The fetched dark style paints trunk, primary, secondary and tertiary from
    // a single layer in a single colour, so an A road and a country lane looked
    // alike. `line-color` is data-driven on `class` instead.
    final repository = MapStyleRepository(
      directory: directory,
      configuration: _darkConfiguration,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(_darkStyleFixture),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final style = jsonDecode((await repository.resolve()).style) as Map;
    final layers = (style['layers'] as List).cast<Map>();
    final major = layers.singleWhere(
      (layer) => layer['id'] == 'highway_major_inner',
    );
    final expression = (major['paint'] as Map)['line-color'] as List;

    expect(expression.first, 'match');
    expect(expression[1], ['get', 'class']);
    for (final entry in {
      'trunk': 'trunk',
      'primary': 'primary',
      'secondary': 'secondary',
    }.entries) {
      final index = expression.indexOf(entry.key);
      expect(index, greaterThan(1), reason: entry.key);
      expect(
        expression[index + 1],
        MapStyleRepository.darkBasemapPalette[entry.value],
        reason: entry.key,
      );
    }
    // The fallback is tertiary, the dimmest of the four.
    expect(expression.last, MapStyleRepository.darkBasemapPalette['tertiary']);
  });

  test('drops the woodland fill pattern that overrode its colour', () async {
    // `fill-pattern` wins over `fill-color` wherever the sprite loads, so
    // repainting woodland without removing the pattern did nothing at all.
    final repository = MapStyleRepository(
      directory: directory,
      configuration: _darkConfiguration,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(_darkStyleFixture),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final style = jsonDecode((await repository.resolve()).style) as Map;
    final wood = (style['layers'] as List).cast<Map>().singleWhere(
      (layer) => layer['id'] == 'landcover_wood',
    );

    expect((wood['paint'] as Map).containsKey('fill-pattern'), isFalse);
    expect(
      (wood['paint'] as Map)['fill-color'],
      MapStyleRepository.darkBasemapPalette['wood'],
    );
  });

  test('does not repaint the day style', () async {
    final repository = MapStyleRepository(
      directory: directory,
      configuration: _configuration,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': 8,
            'sources': <String, Object?>{},
            'layers': [
              {
                'id': 'background',
                'type': 'background',
                'paint': {'background-color': 'rgb(12,12,12)'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final style = jsonDecode((await repository.resolve()).style) as Map;
    final background = (style['layers'] as List).cast<Map>().single;

    expect((background['paint'] as Map)['background-color'], 'rgb(12,12,12)');
  });

  group('restrained default light basemap (#365)', () {
    test('repaints Liberty without changing its tile sources', () async {
      final repository = MapStyleRepository(
        directory: directory,
        configuration: _lightConfiguration,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(_lightStyleFixture),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      final style = jsonDecode((await repository.resolve()).style) as Map;
      final layers = (style['layers'] as List).cast<Map>();
      Map paintOf(String id) =>
          layers.singleWhere((layer) => layer['id'] == id)['paint'] as Map;

      expect(
        paintOf('background')['background-color'],
        MapStyleRepository.lightBasemapPalette['background'],
      );
      expect(
        paintOf('road_service_track')['line-color'],
        MapStyleRepository.lightBasemapPalette['service/track'],
      );
      final secondaryTertiary =
          paintOf('road_secondary_tertiary')['line-color'] as List;
      expect(secondaryTertiary.first, 'match');
      expect(
        secondaryTertiary,
        contains(MapStyleRepository.lightBasemapPalette['secondary']),
      );
      expect(
        secondaryTertiary.last,
        MapStyleRepository.lightBasemapPalette['tertiary'],
      );
      expect(
        ((style['sources'] as Map)['openmaptiles'] as Map)['url'],
        'https://tiles.openfreemap.org/planet',
        reason: 'light and dark keep sharing the provider tile cache',
      );
    });

    test('removes POI tiers but retains navigation labels', () async {
      final resolution = await MapStyleRepository(
        directory: directory,
        configuration: _lightConfiguration,
        client: MockClient(
          (_) async => http.Response(jsonEncode(_lightStyleFixture), 200),
        ),
      ).resolve();

      final style = jsonDecode(resolution.style) as Map;
      final ids = (style['layers'] as List)
          .cast<Map>()
          .map((layer) => layer['id'])
          .toSet();

      expect(ids, isNot(contains('poi_r20')));
      expect(ids, isNot(contains('poi_transit')));
      expect(ids, isNot(contains('airport')));
      expect(ids, contains('highway-name-major'));
      expect(ids, contains('label_town'));
    });

    test('declares a distinct road colour for every hierarchy step', () {
      final colours = MapStyleRepository.lightBasemapRoadRamp
          .map((name) => MapStyleRepository.lightBasemapPalette[name])
          .toList();

      expect(colours, everyElement(isNotNull));
      expect(colours.toSet(), hasLength(colours.length));
      for (final surface in RouteTrailStyle.lightBasemapSurfaces.values) {
        expect(
          contrastRatio(RouteTrailStyle.casing, surface),
          greaterThan(8),
          reason: 'the route casing must stay dominant on every light surface',
        );
      }
    });
  });

  group('the resolution says where the style came from (#281)', () {
    // Every one of these used to be a bare `String`, so the ride map could not
    // tell a provider that answered from one that did not, and drew the empty
    // fallback as though it were the map.
    test('a fetched style is reported as live', () async {
      final repository = MapStyleRepository(
        directory: directory,
        configuration: _configuration,
        client: MockClient((_) async => http.Response(_minimalStyle, 200)),
      );

      final resolution = await repository.resolve();

      expect(resolution.outcome, MapStyleOutcome.live);
      expect(resolution.hasBasemap, isTrue);
      expect(resolution.error, isNull);
    });

    test('a style served from the cache is reported as cached', () async {
      var requests = 0;
      MapStyleRepository open() => MapStyleRepository(
        directory: directory,
        configuration: _configuration,
        client: MockClient((_) async {
          requests++;
          return http.Response(_minimalStyle, 200);
        }),
      );

      await open().resolve();
      final resolution = await open().resolve();

      expect(requests, 1);
      expect(resolution.outcome, MapStyleOutcome.cached);
      expect(resolution.hasBasemap, isTrue);
    });

    test('an unfetchable style with nothing cached is unavailable', () async {
      final repository = MapStyleRepository(
        directory: directory,
        configuration: _configuration,
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      final resolution = await repository.resolve();

      expect(resolution.outcome, MapStyleOutcome.unavailable);
      expect(resolution.hasBasemap, isFalse);
      expect(resolution.style, MapStyleRepository.fallbackStyle);
      expect(
        resolution.error,
        isA<SocketException>(),
        reason: 'the rider should be able to report the actual fault',
      );
    });

    test('a stale cache beats the fallback and still counts as a map', () async {
      // Roads from yesterday are still roads. Reporting this as a failure would
      // put a warning on a perfectly usable map.
      await MapStyleRepository(
        directory: directory,
        configuration: _configuration,
        client: MockClient((_) async => http.Response(_minimalStyle, 200)),
      ).resolve();

      final resolution = await MapStyleRepository(
        directory: directory,
        configuration: _configuration,
        refreshAfter: Duration.zero,
        client: MockClient((_) async => throw const SocketException('offline')),
      ).resolve();

      expect(resolution.outcome, MapStyleOutcome.cached);
      expect(resolution.hasBasemap, isTrue);
      expect(resolution.style, isNot(MapStyleRepository.fallbackStyle));
    });

    test(
      'a build with no style configured is unconfigured, not failed',
      () async {
        final repository = MapStyleRepository(
          directory: directory,
          configuration: const BasemapConfiguration(),
          client: MockClient((_) async => http.Response(_minimalStyle, 200)),
        );

        final resolution = await repository.resolve();

        expect(resolution.outcome, MapStyleOutcome.unconfigured);
        expect(resolution.hasBasemap, isFalse);
        expect(resolution.style, MapStyleRepository.fallbackStyle);
      },
    );
  });

  group('dark basemap palette (#143)', () {
    final ground = surface('background');
    final dimmestRoad = surface(MapStyleRepository.darkBasemapRoadRamp.first);

    test('the road ramp rises monotonically with a visible step', () {
      // The whole point of the ramp: a rider can tell a motorway from an A road
      // from a B road from a lane. Before this the middle four were one colour.
      var previous = -1.0;
      for (final name in MapStyleRepository.darkBasemapRoadRamp) {
        final value = lightness(surface(name));
        expect(
          value - previous,
          greaterThanOrEqualTo(previous < 0 ? 0 : 3.4),
          reason: '$name is not a clear step above the class below it',
        );
        previous = value;
      }
      expect(
        MapStyleRepository.darkBasemapRoadRamp.last,
        'motorway',
        reason: 'the lightest road is the motorway',
      );
    });

    test('every road class clears the ground it is drawn on', () {
      // What main measured, class by class, against its own background.
      const before = <String, double>{
        'service/track': 1.50,
        'minor': 1.50,
        'tertiary': 1.86,
        'secondary': 1.86,
        'primary': 1.86,
        'trunk': 1.86,
        'motorway': 2.32,
      };
      const after = <String, double>{
        'service/track': 1.62,
        'minor': 2.25,
        'tertiary': 2.68,
        'secondary': 3.11,
        'primary': 3.57,
        'trunk': 4.08,
        'motorway': 4.62,
      };

      expect(after.keys, MapStyleRepository.darkBasemapRoadRamp);
      for (final entry in after.entries) {
        final measured = contrastRatio(surface(entry.key), ground);
        expect(measured, closeTo(entry.value, 0.01), reason: entry.key);
        expect(
          measured,
          greaterThan(before[entry.key]!),
          reason: '${entry.key} must not be less separated than it was on main',
        );
      }
      // The classes a rider actually uses gained the most: a lane was the worst
      // measured road on the map and a motorway was already the best.
      expect(
        contrastRatio(surface('minor'), ground) / before['minor']!,
        greaterThan(1.4),
      );
    });

    test('the ground band is closed below the dimmest road', () {
      // No non-road surface may come near the road band. On main the airfield
      // runway casing composited to #363636 and measured 1.06:1 against a minor
      // road, so a lane crossing an airfield vanished into it.
      for (final name in MapStyleRepository.darkBasemapGroundBand) {
        expect(
          lightness(dimmestRoad) - lightness(surface(name)),
          greaterThanOrEqualTo(8),
          reason: '$name is within 8 L* of the dimmest road class',
        );
      }
    });

    test('nothing on the ground is darker than the background', () {
      // The fetched style had buildings at rgb(10,10,10), piers at rgb(12,12,12)
      // and both aeroway fills at pure black, all below its own background, so
      // the map read as blotches of black rather than as a ground with roads on
      // it. Only the deliberate road edge is allowed below the background.
      for (final name in MapStyleRepository.darkBasemapGroundBand) {
        expect(
          lightness(surface(name)),
          greaterThanOrEqualTo(lightness(ground) - 0.01),
          reason: '$name is a hole in the ground',
        );
      }
      expect(
        lightness(surface('road casing')),
        lessThan(lightness(ground)),
        reason: 'the road casing is the dark edge that makes a road a slab',
      );
    });

    test('the airfield recedes rather than dominating', () {
      // The field report for #143 named this: "the most legible bit is actually
      // airfields as they are coloured in black".
      const airfield = [
        'aeroway area',
        'aeroway runway',
        'aeroway runway casing',
        'aeroway taxiway',
      ];
      for (final name in airfield) {
        expect(
          (lightness(surface(name)) - lightness(ground)).abs(),
          lessThan(5),
          reason: '$name still stands out from the ground',
        );
        expect(
          contrastRatio(surface(name), surface('minor')),
          greaterThan(1.8),
          reason: '$name must sit clearly below a minor road, not above it',
        );
        expect(
          lightness(surface(name)),
          lessThan(lightness(surface('minor'))),
          reason: '$name outranks a road a group can ride on',
        );
      }
    });

    test('colour is reserved for meaning; the ground is near-achromatic', () {
      // Five saturated route colours and a hazard palette have to own the
      // saturated range, so the basemap keeps a hint of green on vegetation and
      // one blue for water and is otherwise a cool grey.
      for (final name in MapStyleRepository.darkBasemapRoadRamp) {
        final road = surface(name);
        final channels = [road.r, road.g, road.b];
        expect(
          channels.reduce(math.max) - channels.reduce(math.min),
          lessThan(0.08),
          reason: '$name is a coloured road',
        );
      }
    });

    test('the route and trail palette is not undone by the new ground', () {
      // #107 chose these colours and #133 audited them against the old basemap.
      // Any basemap change moves every one of those numbers, so they are
      // re-measured here against the surfaces this repository now paints.
      const overGround = <String, double>{
        'route ahead': 10.44,
        'travelled': 7.14,
        'leader trail': 10.71,
        'off route': 6.93,
        'rejoin breadcrumb': 12.11,
      };

      expect(RouteTrailStyle.allLines.keys, overGround.keys);
      for (final entry in RouteTrailStyle.allLines.entries) {
        final line = entry.value.color;
        final measured = contrastRatio(line, ground);
        expect(
          measured,
          closeTo(overGround[entry.key]!, 0.01),
          reason: entry.key,
        );
        // A darker ground can only help a bright line, so every one of them is
        // better off than it was against #1C1C1E.
        expect(
          measured,
          greaterThan(
            contrastRatio(
              line,
              RouteTrailStyle.darkBasemapSurfaces['background']!,
            ),
          ),
          reason: '${entry.key} over the ground',
        );
        expect(measured, greaterThan(4.5), reason: entry.key);
      }
    });

    test('the route casing separates from the new road fills better', () {
      // #133's rule: a route line never touches a road fill, because it carries
      // an opaque casing two pixels wider on each side. Lighter roads therefore
      // *help* - the number that changes is casing against road, and it rises.
      const beforeFill = <String, String>{
        'service/track': '#3A3A3A',
        'minor': '#3A3A3A',
        'tertiary': '#484848',
        'secondary': '#484848',
        'primary': '#484848',
        'trunk': '#484848',
        'motorway': '#565656',
      };

      for (final name in MapStyleRepository.darkBasemapRoadRamp) {
        final before = contrastRatio(
          RouteTrailStyle.casing,
          paint(beforeFill[name]!),
        );
        final after = contrastRatio(RouteTrailStyle.casing, surface(name));
        if (name == 'service/track') {
          // The one class that got dimmer, deliberately: a driveway or a forest
          // track is not a road a group rides, and main painted it the same
          // colour as a lane.
          expect(after, closeTo(before, 0.02), reason: name);
          continue;
        }
        expect(
          after,
          greaterThan(before),
          reason: 'route casing against $name',
        );
      }
      expect(
        contrastRatio(RouteTrailStyle.casing, surface('motorway')),
        closeTo(4.54, 0.01),
      );
    });

    test('a bright line over a road fill is no worse off than in daylight', () {
      // Lifting the road fills does cost the bare line-over-road number, which
      // is why #139 rejected the opposite change. The floor that makes it
      // acceptable is the light basemap, whose road fills are white and cream:
      // it ships, it is field-legible, and it is harsher on every one of these
      // colours than the new dark basemap is.
      double worst(Iterable<Color> surfaces) => RouteTrailStyle.allLines.values
          .expand((line) => surfaces.map((s) => contrastRatio(line.color, s)))
          .reduce(math.min);

      final dark = worst([
        for (final name in MapStyleRepository.darkBasemapPalette.keys)
          if (name != 'road casing') surface(name),
      ]);
      final light = worst(RouteTrailStyle.lightBasemapSurfaces.values);

      expect(light, closeTo(1.00, 0.01));
      expect(dark, closeTo(1.50, 0.01));
      expect(
        dark,
        greaterThan(light),
        reason: 'the dark basemap must not be harsher on a line than day is',
      );
    });

    test('labels are legible on the surfaces they are placed on', () {
      // Road names measured 1.38:1 against the road they sit on, a motorway ref
      // 1.14:1 against its own carriageway, and water names were pure black.
      // Each label carries a near-black halo, so the halo is what it is measured
      // against as well - the same rule as a route casing.
      const labels = <String, (String, double)>{
        'road name': ('minor', 4.58),
        'motorway ref': ('motorway', 2.50),
        'place name': ('background', 9.22),
        'water name': ('water', 4.65),
      };
      const labelInk = <String, String>{
        'road name': '#BCC1C9',
        'motorway ref': '#C9CCD1',
        'place name': '#B1B7BF',
        'water name': '#748DB1',
      };
      for (final entry in labels.entries) {
        final (against, expected) = entry.value;
        expect(
          contrastRatio(paint(labelInk[entry.key]!), surface(against)),
          closeTo(expected, 0.01),
          reason: '${entry.key} on $against',
        );
        expect(
          contrastRatio(paint(labelInk[entry.key]!), paint('#0B0E12')),
          greaterThan(4.5),
          reason: '${entry.key} against its halo',
        );
      }
    });
  });
}

/// A cut of the OpenFreeMap dark style with the layers this repaint has to get
/// right, at the values the provider actually publishes.
const _darkStyleFixture = <String, Object?>{
  'version': 8,
  'sources': <String, Object?>{},
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': 'rgb(12,12,12)'},
    },
    {
      'id': 'highway_minor',
      'type': 'line',
      'paint': {'line-color': '#181818', 'line-opacity': 0.9, 'line-blur': 0.4},
    },
    {
      'id': 'highway_major_inner',
      'type': 'line',
      'paint': {'line-color': 'hsl(0,0%,7%)'},
    },
    {
      'id': 'highway_motorway_inner',
      'type': 'line',
      'paint': {
        'line-color': [
          'interpolate',
          ['linear'],
          ['zoom'],
          5.8,
          'hsla(0,0%,85%,0.53)',
          6,
          '#000',
        ],
      },
    },
    {
      'id': 'landcover_wood',
      'type': 'fill',
      'paint': {
        'fill-color': 'rgb(32,32,32)',
        'fill-pattern': 'wood-pattern',
        'fill-opacity': 0.4,
      },
    },
    {
      'id': 'aeroway-area',
      'type': 'fill',
      'paint': {'fill-color': '#000'},
    },
    {
      'id': 'aeroway-runway-casing',
      'type': 'line',
      'paint': {'line-color': 'rgba(60,60,60,0.8)'},
    },
    {'id': 'unrelated_layer', 'type': 'fill', 'paint': <String, Object?>{}},
  ],
};

const _lightStyleFixture = <String, Object?>{
  'version': 8,
  'sources': {
    'openmaptiles': {
      'type': 'vector',
      'url': 'https://tiles.openfreemap.org/planet',
    },
  },
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': '#F8F4F0'},
    },
    {
      'id': 'landcover_wood',
      'type': 'fill',
      'paint': {'fill-color': '#D8E8C8', 'fill-pattern': 'wood-pattern'},
    },
    {
      'id': 'road_service_track',
      'type': 'line',
      'paint': {'line-color': '#FFFFFF'},
    },
    {
      'id': 'road_secondary_tertiary',
      'type': 'line',
      'paint': {'line-color': '#FFEEAA'},
    },
    {'id': 'poi_r20', 'type': 'symbol', 'paint': <String, Object?>{}},
    {'id': 'poi_transit', 'type': 'symbol', 'paint': <String, Object?>{}},
    {'id': 'airport', 'type': 'symbol', 'paint': <String, Object?>{}},
    {
      'id': 'highway-name-major',
      'type': 'symbol',
      'paint': {'text-color': '#333333'},
    },
    {
      'id': 'label_town',
      'type': 'symbol',
      'paint': {'text-color': '#222222'},
    },
  ],
};

/// The smallest document that satisfies the repository's validation, for the
/// tests that care where a style came from rather than what is in it.
final _minimalStyle = jsonEncode({
  'version': 8,
  'sources': {
    'planet': {
      'type': 'vector',
      'tiles': ['https://maps.example.test/tiles/{z}/{x}/{y}.pbf'],
    },
  },
  'layers': <Object>[],
});

const _configuration = BasemapConfiguration(
  styleUrl: 'https://maps.example.test/styles/ride-relay.json',
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: 'open-map-v1',
  persistentCachingAllowed: true,
);

const _darkConfiguration = BasemapConfiguration(
  styleUrl: 'https://maps.example.test/styles/dark.json',
  darkStyleUrl: 'https://maps.example.test/styles/dark.json',
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: 'open-map-v1-dark',
  persistentCachingAllowed: true,
);

const _lightConfiguration = BasemapConfiguration(
  styleUrl: BasemapConfiguration.defaultLightStyleUrl,
  darkStyleUrl: BasemapConfiguration.defaultDarkStyleUrl,
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: BasemapConfiguration.defaultCacheNamespace,
  persistentCachingAllowed: true,
);
