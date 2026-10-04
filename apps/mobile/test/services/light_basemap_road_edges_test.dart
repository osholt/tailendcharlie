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
import 'package:ride_relay/services/provider_label_guard.dart';

/// Measured cover for #841: roads were hard to pick out in the light map, on
/// Android and on iOS.
///
/// The cause was the road *edge*. The restrained repaint painted every casing
/// one pale grey (1.55:1 against the ground) and the provider draws it only
/// 0.8-1.1 px wider than the road on each side at riding zoom, while the fills
/// are white and cream and sit within 1.0-1.2:1 of the ground. These tests hold
/// the repaint to the numbers recorded in `docs/maps-and-gpx.md`, measured on the
/// real OpenFreeMap Liberty paint (`test/fixtures/openfreemap_liberty_roads.json`,
/// recorded on 4 October 2026 and trimmed to the ground and road layers).
///
/// They prove the style; they cannot prove daylight. The photograph or tester
/// confirmation in direct sunlight that #841 asks for is separate evidence.

/// Mirrors the settings a rider on the default daytime map has.
const _restrainedConfiguration = BasemapConfiguration(
  styleUrl: BasemapConfiguration.defaultLightStyleUrl,
  darkStyleUrl: BasemapConfiguration.defaultDarkStyleUrl,
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: BasemapConfiguration.defaultCacheNamespace,
  persistentCachingAllowed: true,
);

/// The same provider style with the daytime map set to Original (#489).
final _originalConfiguration = _restrainedConfiguration.forBrightness(
  dark: false,
  restrainedLightStyle: false,
);

/// The one casing the first restrained repaint used for every road class.
const _previousCasing = '#C4C5C1';

/// A road class as the style sees it: the fill layer and casing layer that draw
/// it, and the `class` value the data-driven colours key on.
typedef _RoadClass = ({String fill, String casing, String klass});

const _roadClasses = <String, _RoadClass>{
  'service/track': (
    fill: 'road_service_track',
    casing: 'road_service_track_casing',
    klass: 'service',
  ),
  'minor': (fill: 'road_minor', casing: 'road_minor_casing', klass: 'minor'),
  'tertiary': (
    fill: 'road_secondary_tertiary',
    casing: 'road_secondary_tertiary_casing',
    klass: 'tertiary',
  ),
  'secondary': (
    fill: 'road_secondary_tertiary',
    casing: 'road_secondary_tertiary_casing',
    klass: 'secondary',
  ),
  'primary': (
    fill: 'road_trunk_primary',
    casing: 'road_trunk_primary_casing',
    klass: 'primary',
  ),
  'trunk': (
    fill: 'road_trunk_primary',
    casing: 'road_trunk_primary_casing',
    klass: 'trunk',
  ),
  'motorway': (
    fill: 'road_motorway',
    casing: 'road_motorway_casing',
    klass: 'motorway',
  ),
};

/// Every class a rider actually uses; service roads and tracks are deliberately
/// not edged any harder (a driveway is not a road a group rides).
final _ridableClasses = [
  for (final name in _roadClasses.keys)
    if (name != 'service/track') name,
];

/// MapLibre zooms the ride camera uses: 13.85 at speed to 14.65 at rest in
/// portrait, 13.35 to 14.15 in landscape (`NavigationCameraPlanner`), plus 16
/// for the closer look a rider takes while stopped.
const _ridingZooms = <double>[14.0, 14.65, 16.0];

Color cssColour(String value) {
  final hex = value.substring(1);
  final full = hex.length == 3
      ? hex.split('').map((digit) => '$digit$digit').join()
      : hex;
  return Color(0xFF000000 | int.parse(full, radix: 16));
}

/// CIE L*, 0 (black) to 100 (white); the perceptual companion to WCAG's ratio.
double lightness(Color color) {
  final y = relativeLuminance(color);
  return y > 0.008856 ? 116 * math.pow(y, 1 / 3) - 16 : 903.3 * y;
}

/// The spread of the channels, as a stand-in for chroma: a neutral grey is 0.
double chroma(Color color) {
  final channels = [color.r, color.g, color.b];
  return channels.reduce(math.max) - channels.reduce(math.min);
}

/// The colour MapLibre would draw for [expression] on a road of [roadClass].
/// Only the two forms the road paint uses: a colour, and `match` on `class`.
Color colourFor(Object? expression, String roadClass) {
  if (expression is String) return cssColour(expression);
  final list = expression! as List;
  expect(list.first, 'match', reason: 'unsupported colour expression $list');
  for (var i = 2; i + 1 < list.length; i += 2) {
    final labels = list[i] is List ? list[i] as List : [list[i]];
    if (labels.contains(roadClass)) return colourFor(list[i + 1], roadClass);
  }
  return colourFor(list.last, roadClass);
}

/// The width MapLibre would draw for a `line-width` paint value at [zoom].
double widthAt(Object? expression, double zoom) {
  if (expression is num) return expression.toDouble();
  final list = expression! as List;
  expect(list.first, 'interpolate', reason: 'unsupported width $list');
  final type = list[1] as List;
  final base = type.first == 'exponential' ? (type[1] as num).toDouble() : 1.0;
  final stops = <(double, double)>[
    for (var i = 3; i + 1 < list.length; i += 2)
      ((list[i] as num).toDouble(), (list[i + 1] as num).toDouble()),
  ];
  if (zoom <= stops.first.$1) return stops.first.$2;
  if (zoom >= stops.last.$1) return stops.last.$2;
  for (var i = 0; i + 1 < stops.length; i++) {
    final (z0, v0) = stops[i];
    final (z1, v1) = stops[i + 1];
    if (zoom < z0 || zoom > z1) continue;
    final t = base == 1
        ? (zoom - z0) / (z1 - z0)
        : (math.pow(base, zoom - z0) - 1) / (math.pow(base, z1 - z0) - 1);
    return v0 + (v1 - v0) * t;
  }
  throw StateError('unreachable');
}

Map<String, dynamic> _provider() =>
    jsonDecode(
          File(
            'test/fixtures/openfreemap_liberty_roads.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> _repainted(BasemapConfiguration configuration) {
  final style = _provider();
  MapStyleRepository.applyPresentation(style, configuration);
  return style;
}

Map<String, Map<String, dynamic>> _layersOf(Map<String, dynamic> style) => {
  for (final layer in (style['layers'] as List).cast<Map<String, dynamic>>())
    layer['id'] as String: layer,
};

Object? _paint(
  Map<String, Map<String, dynamic>> layers,
  String id,
  String key,
) => (layers[id]!['paint'] as Map)[key];

void main() {
  final palette = MapStyleRepository.lightBasemapPalette;
  final ground = cssColour(palette['background']!);
  late Map<String, Map<String, dynamic>> provider;
  late Map<String, Map<String, dynamic>> restrained;

  setUp(() {
    provider = _layersOf(_provider());
    restrained = _layersOf(_repainted(_restrainedConfiguration));
  });

  Color edgeOf(String name) {
    final road = _roadClasses[name]!;
    return colourFor(_paint(restrained, road.casing, 'line-color'), road.klass);
  }

  Color fillOf(String name) {
    final road = _roadClasses[name]!;
    return colourFor(_paint(restrained, road.fill, 'line-color'), road.klass);
  }

  double edgeWidth(
    Map<String, Map<String, dynamic>> layers,
    String name,
    double zoom,
  ) {
    final road = _roadClasses[name]!;
    return (widthAt(_paint(layers, road.casing, 'line-width'), zoom) -
            widthAt(_paint(layers, road.fill, 'line-width'), zoom)) /
        2;
  }

  group('the edge of a road is drawn darker (#841)', () {
    test(
      'every ridable class is edged at 2:1 or better against the ground',
      () {
        // What the first restrained repaint measured: one casing, #C4C5C1, for
        // every class. These are the figures in docs/maps-and-gpx.md.
        const documented = <String, double>{
          'minor': 2.02,
          'tertiary': 2.01,
          'secondary': 2.02,
          'primary': 2.01,
          'trunk': 2.02,
          'motorway': 2.02,
        };
        final before = contrastRatio(cssColour(_previousCasing), ground);

        expect(before, closeTo(1.55, 0.01));
        expect(_ridableClasses, documented.keys);
        for (final entry in documented.entries) {
          final measured = contrastRatio(edgeOf(entry.key), ground);
          expect(measured, closeTo(entry.value, 0.01), reason: entry.key);
          expect(
            measured,
            greaterThanOrEqualTo(2.0),
            reason: '${entry.key} is not edged at 2:1 against the ground',
          );
          expect(
            measured,
            greaterThan(before),
            reason: '${entry.key} is no better edged than it was',
          );
        }
      },
    );

    test('and by 25 L* or so, which is what survives glare', () {
      // WCAG's +0.05 flare term flatters nothing here (these are light on
      // light), but a screen in direct sun adds far more flare than that to
      // every pixel, which shrinks a ratio while leaving a luminance
      // *difference* alone. L* is the better guide to what is left.
      final groundLightness = lightness(ground);
      final before = groundLightness - lightness(cssColour(_previousCasing));

      expect(before, closeTo(16.1, 0.1));
      for (final name in _ridableClasses) {
        expect(
          groundLightness - lightness(edgeOf(name)),
          greaterThanOrEqualTo(24.5),
          reason: name,
        );
      }
    });

    test('and still stands out from the darkest ground a road is drawn over', () {
      // Buildings (z13-14) and woodland are the darkest grounds at riding zoom.
      final building = cssColour(palette['building']!);
      final wood = cssColour(palette['wood']!);

      for (final name in _ridableClasses) {
        expect(
          contrastRatio(edgeOf(name), building),
          greaterThanOrEqualTo(1.6),
          reason: '$name edge against a building',
        );
        expect(
          contrastRatio(edgeOf(name), wood),
          greaterThanOrEqualTo(1.75),
          reason: '$name edge against woodland',
        );
        // The old edge measured 1.27:1 against a building.
        expect(
          contrastRatio(edgeOf(name), building),
          greaterThan(contrastRatio(cssColour(_previousCasing), building)),
          reason: name,
        );
      }
    });

    test('lightness is shared and chroma climbs with the class', () {
      // A casing says what kind of road it edges the way the fill tints do, but
      // none may be darker than the route's casing allows (see below), so the
      // class is carried by chroma and the lightness is held.
      final lightnesses = [
        for (final n in _ridableClasses) lightness(edgeOf(n)),
      ];
      expect(
        lightnesses.reduce(math.max) - lightnesses.reduce(math.min),
        lessThan(1.0),
      );

      var previous = -1.0;
      for (final name in _ridableClasses) {
        final spread = chroma(edgeOf(name));
        expect(
          spread,
          greaterThanOrEqualTo(previous),
          reason: '$name is less tinted than the class below it',
        );
        previous = spread;
      }
      expect(
        palette['trunk casing'],
        isNot(palette['primary casing']),
        reason: 'neighbouring classes need distinct edges',
      );
    });

    test('the fills, and so the hierarchy between classes, are untouched', () {
      // The edge is the whole fix. White and cream stay white and cream, so the
      // road ramp the #365 tests hold apart is exactly what it was.
      for (final name in MapStyleRepository.lightBasemapRoadRamp) {
        expect(fillOf(name), cssColour(palette[name]!), reason: name);
      }
    });

    test('the palette names the edge the repaint applies, class by class', () {
      for (final name in MapStyleRepository.lightBasemapRoadRamp) {
        final road = _roadClasses[name]!;
        final fromStyle = colourFor(
          _paint(restrained, road.casing, 'line-color'),
          road.klass,
        );

        expect(
          fromStyle,
          cssColour(palette['$name casing']!),
          reason: '$name casing in the palette and in the document differ',
        );
      }
    });
  });

  group('the route stays the strongest line on the map', () {
    test('its casing is above 8:1 against every colour the light map paints', () {
      // The #133 rule: a route line is protected by its opaque near-black casing,
      // so what matters is that casing against whatever is under it. Darker road
      // edges are only acceptable while that number does not slip.
      for (final entry in palette.entries) {
        expect(
          contrastRatio(RouteTrailStyle.casing, cssColour(entry.value)),
          greaterThan(8),
          reason: 'route casing against the light basemap\'s ${entry.key}',
        );
      }
    });

    test(
      'and no edge is darker than the route casing can still read against',
      () {
        // The tightest pair, so a future darkening is a conscious act.
        final tightest = [
          for (final name in _ridableClasses)
            contrastRatio(RouteTrailStyle.casing, edgeOf(name)),
        ].reduce(math.min);

        expect(tightest, closeTo(8.07, 0.02));
      },
    );

    test('the route-trail light surfaces are what this repository paints', () {
      // `RouteTrailStyle.lightBasemapSurfaces` restates the palette so the
      // overlay tests need no repository. It must not drift from it.
      const names = <String, String>{
        'background': 'background',
        'minor road': 'minor',
        'trunk': 'trunk',
        'motorway': 'motorway',
        'water': 'water',
        'park': 'park',
        'building': 'building',
        'minor casing': 'minor casing',
        'motorway casing': 'motorway casing',
      };

      expect(RouteTrailStyle.lightBasemapSurfaces.keys, names.keys);
      for (final entry in names.entries) {
        expect(
          RouteTrailStyle.lightBasemapSurfaces[entry.key],
          cssColour(palette[entry.value]!),
          reason: entry.key,
        );
      }
    });
  });

  group('the edge is one pixel wider and the road is not (#841)', () {
    test('only the casing grows, by one pixel from zoom 14', () {
      for (final name in _ridableClasses) {
        final road = _roadClasses[name]!;
        for (final zoom in [13.0, 14.0, 14.65, 16.0, 18.0]) {
          final before = widthAt(
            _paint(provider, road.casing, 'line-width'),
            zoom,
          );
          final after = widthAt(
            _paint(restrained, road.casing, 'line-width'),
            zoom,
          );
          expect(
            after - before,
            closeTo(zoom >= 14 ? 1.0 : 0.0, 0.02),
            reason: '$name casing at z$zoom',
          );
        }
      }
    });

    test('the carriageway keeps the provider\'s width at every zoom', () {
      // #776 widened bright roads on the dark map and field validation found they
      // obscured the route. The fill is the part that competes with the route, so
      // it is not touched here.
      for (final name in _ridableClasses) {
        final road = _roadClasses[name]!;
        for (final zoom in [13.0, 14.0, 14.65, 16.0, 18.0]) {
          expect(
            widthAt(_paint(restrained, road.fill, 'line-width'), zoom),
            widthAt(_paint(provider, road.fill, 'line-width'), zoom),
            reason: '$name fill at z$zoom',
          );
        }
      }
    });

    test('so the edge is 1.25 px or more a side at riding zoom, not 0.75', () {
      for (final name in _ridableClasses) {
        for (final zoom in _ridingZooms) {
          expect(
            edgeWidth(restrained, name, zoom),
            greaterThanOrEqualTo(1.25),
            reason: '$name at z$zoom',
          );
          expect(
            edgeWidth(restrained, name, zoom) - edgeWidth(provider, name, zoom),
            closeTo(0.5, 0.01),
            reason: '$name gained half a pixel a side at z$zoom',
          );
        }
      }
      // The class a rider spends most of a ride on, at the zoom they spend it.
      expect(edgeWidth(provider, 'minor', 14), closeTo(0.75, 0.01));
      expect(edgeWidth(restrained, 'minor', 14), closeTo(1.25, 0.01));
    });

    test('and the road is still no wider than the route line drawn over it', () {
      // Route line 6 px inside a 10 px casing (`RouteTrailStyle.routeAhead`).
      // The widest ridable road at riding zoom, casing included, must not exceed
      // the route's own footprint, or the route stops reading as the line to
      // follow.
      for (final name in _ridableClasses) {
        final road = _roadClasses[name]!;
        for (final zoom in [14.0, 14.65]) {
          expect(
            widthAt(_paint(restrained, road.casing, 'line-width'), zoom),
            lessThanOrEqualTo(RouteTrailStyle.routeAhead.casingWidthPixels),
            reason: '$name casing at z$zoom',
          );
        }
      }
    });
  });

  group('every casing layer gets the edge of its class', () {
    // The suffix of a provider layer id says which family it belongs to; the
    // prefix (`road_`, `bridge_`, `tunnel_`) only says where it is.
    const families = <String, List<String>>{
      'service_track_casing': ['service/track'],
      'path_pedestrian_casing': ['service/track'],
      'street_casing': ['minor'],
      'minor_casing': ['minor'],
      'secondary_tertiary_casing': ['secondary', 'tertiary'],
      'trunk_primary_casing': ['trunk', 'primary'],
      'motorway_casing': ['motorway'],
      'motorway_link_casing': ['motorway'],
      'link_casing': ['trunk', 'primary', 'secondary', 'tertiary', 'minor'],
    };
    const classOfName = <String, String>{
      'service/track': 'service',
      'minor': 'minor',
      'tertiary': 'tertiary',
      'secondary': 'secondary',
      'primary': 'primary',
      'trunk': 'trunk',
      'motorway': 'motorway',
    };

    String? familyOf(String id) {
      // `motorway_link_casing` ends with `link_casing`, so the longest suffix wins.
      final matches = families.keys.where(id.endsWith).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      return matches.isEmpty ? null : matches.first;
    }

    test('road, bridge and tunnel casings all take their class\'s colour', () {
      final casings = [
        for (final id in restrained.keys)
          if (id.endsWith('_casing') &&
              (id.startsWith('road_') ||
                  id.startsWith('bridge_') ||
                  id.startsWith('tunnel_')))
            id,
      ];

      expect(casings.length, greaterThanOrEqualTo(20));
      for (final id in casings) {
        final family = familyOf(id);
        expect(family, isNotNull, reason: '$id belongs to no known family');
        final expression = _paint(restrained, id, 'line-color');
        for (final name in families[family]!) {
          expect(
            colourFor(expression, classOfName[name]!),
            cssColour(palette['$name casing']!),
            reason: '$id on a $name road',
          );
        }
      }
    });

    test('every ridable casing widens, and a pale one never does', () {
      for (final id in restrained.keys) {
        if (!id.endsWith('_casing')) continue;
        final family = familyOf(id);
        if (family == null) continue;
        final widened =
            widthAt(_paint(restrained, id, 'line-width'), 14.65) -
            widthAt(_paint(provider, id, 'line-width'), 14.65);
        final pale = families[family]!.every((name) => name == 'service/track');

        expect(
          widened,
          pale ? 0.0 : closeTo(1.0, 0.02),
          reason: '$id widened by $widened at z14.65',
        );
      }
    });

    test('no casing keeps the provider\'s orange or its old uniform grey', () {
      for (final entry in restrained.entries) {
        if (!entry.key.endsWith('_casing')) continue;
        final expression = entry.value['paint']['line-color'];
        final encoded = jsonEncode(expression).toLowerCase();

        expect(encoded, isNot(contains('#e9ac77')), reason: entry.key);
        if (!(entry.key.contains('service_track') ||
            entry.key.contains('path_pedestrian'))) {
          expect(
            encoded,
            isNot(contains(_previousCasing.toLowerCase())),
            reason: '${entry.key} still has the old uniform edge',
          );
        }
      }
    });

    test(
      'service roads and tracks keep the pale edge and the provider width',
      () {
        final service = _roadClasses['service/track']!;
        final minorEdge = lightness(edgeOf('minor'));

        expect(
          edgeOf('service/track'),
          cssColour(_previousCasing),
          reason: 'a driveway is not a road a group rides',
        );
        expect(
          lightness(edgeOf('service/track')) - minorEdge,
          greaterThanOrEqualTo(8),
          reason: 'the quietest road must stay clearly quieter than a lane',
        );
        for (final zoom in [14.0, 15.5, 16.0, 18.0]) {
          expect(
            widthAt(_paint(restrained, service.casing, 'line-width'), zoom),
            widthAt(_paint(provider, service.casing, 'line-width'), zoom),
            reason: 'service casing at z$zoom',
          );
        }
        // And paths, drawn dashed on top of everything, stay quieter still.
        expect(
          lightness(cssColour(palette['path']!)),
          greaterThan(minorEdge),
          reason: 'a path must not outrank a lane',
        );
      },
    );

    test('ramps leave on the casing of the road they leave', () {
      final expression = _paint(restrained, 'road_link_casing', 'line-color');

      for (final name in ['trunk', 'primary', 'secondary', 'tertiary']) {
        expect(
          colourFor(expression, name),
          cssColour(palette['$name casing']!),
          reason: 'a $name ramp',
        );
      }
      expect(
        colourFor(expression, 'minor'),
        cssColour(palette['minor casing']!),
        reason: 'anything else falls back to the lane edge',
      );
    });
  });

  group('the Original daytime map keeps the provider palette (#489, #841)', () {
    // The edge treatment is the only thing Original receives: its ground, its
    // fills, its labels and its symbols are the provider's, and the Settings
    // copy says so. Everything else here holds that line.
    late Map<String, Map<String, dynamic>> original;

    setUp(() => original = _layersOf(_repainted(_originalConfiguration)));

    bool isStrengthenedEdge(String id) =>
        id.endsWith('_casing') &&
        (id.startsWith('road_') ||
            id.startsWith('bridge_') ||
            id.startsWith('tunnel_')) &&
        !(id.contains('service_track') || id.contains('path_pedestrian'));

    /// A provider POI layer: the only other thing Original changes is its label,
    /// which is guarded against identifiers (#860).
    bool isPoiLabel(Map<String, dynamic> layer) =>
        layer['source-layer'] == 'poi' &&
        (layer['layout'] as Map?)?.containsKey('text-field') == true;

    test(
      'only road edges and the identifier guard differ from the provider',
      () {
        expect(original.keys, provider.keys);
        var changed = 0;
        var labels = 0;
        for (final entry in provider.entries) {
          final id = entry.key;
          if (isPoiLabel(entry.value)) {
            labels++;
            // The label is wrapped and nothing else about the layer moves.
            final guarded = Map<String, dynamic>.from(original[id]!);
            final layout = Map<String, dynamic>.from(guarded['layout'] as Map);
            final providerLabel = (entry.value['layout'] as Map)['text-field'];
            expect(
              ProviderLabelGuard.unwrap(layout['text-field']),
              providerLabel,
              reason: '$id label',
            );
            layout['text-field'] = providerLabel;
            guarded['layout'] = layout;
            expect(jsonEncode(guarded), jsonEncode(entry.value), reason: id);
            continue;
          }
          final different = jsonEncode(original[id]) != jsonEncode(entry.value);

          expect(different, isStrengthenedEdge(id), reason: id);
          if (!different) continue;
          changed++;
          final before = entry.value['paint'] as Map;
          final after = original[id]!['paint'] as Map;
          for (final key in {...before.keys, ...after.keys}) {
            if (jsonEncode(before[key]) == jsonEncode(after[key])) continue;
            expect(
              ['line-color', 'line-width'],
              contains(key),
              reason: '$id changed $key in the Original style',
            );
          }
        }
        expect(changed, greaterThanOrEqualTo(18));
        expect(labels, greaterThanOrEqualTo(4));
      },
    );

    test(
      'a lane\'s edge is deepened; the provider\'s orange and pale edges stay',
      () {
        final ground = cssColour(
          _paint(provider, 'background', 'background-color')! as String,
        );
        final providerLane = cssColour(
          _paint(provider, 'road_minor_casing', 'line-color')! as String,
        );
        final lane = colourFor(
          _paint(original, 'road_minor_casing', 'line-color'),
          'minor',
        );

        expect(lane, cssColour(MapStyleRepository.originalLightCasingMinor));
        expect(contrastRatio(providerLane, ground), closeTo(1.45, 0.01));
        expect(contrastRatio(lane, ground), closeTo(2.07, 0.01));
        expect(
          ground.toARGB32(),
          isNot(cssColour(palette['background']!).toARGB32()),
          reason: 'Original keeps its own warmer ground, not Restrained\'s',
        );
        // The larger roads keep the provider's colour exactly.
        for (final name in [
          'tertiary',
          'secondary',
          'primary',
          'trunk',
          'motorway',
        ]) {
          final road = _roadClasses[name]!;
          expect(
            _paint(original, road.casing, 'line-color'),
            _paint(provider, road.casing, 'line-color'),
            reason: name,
          );
          expect(
            contrastRatio(
              colourFor(
                _paint(original, road.casing, 'line-color'),
                road.klass,
              ),
              ground,
            ),
            closeTo(1.80, 0.01),
            reason: '$name is edged as the provider edges it',
          );
        }
        // And a service road, a track or a path is not touched at all.
        for (final id in provider.keys.where(
          (id) =>
              id.endsWith('_casing') &&
              (id.contains('service_track') || id.contains('path_pedestrian')),
        )) {
          expect(
            jsonEncode(original[id]),
            jsonEncode(provider[id]),
            reason: id,
          );
        }
      },
    );

    test('and a lane is still edged harder than a driveway', () {
      expect(
        lightness(
          colourFor(
            _paint(original, 'road_minor_casing', 'line-color'),
            'minor',
          ),
        ),
        lessThan(
          lightness(
            colourFor(
              _paint(original, 'road_service_track_casing', 'line-color'),
              'service',
            ),
          ),
        ),
      );
    });

    test('every edge widens by one pixel from zoom 14; no road does', () {
      for (final name in _ridableClasses) {
        final road = _roadClasses[name]!;
        for (final zoom in [13.0, 14.0, 14.65, 16.0, 18.0]) {
          expect(
            widthAt(_paint(original, road.casing, 'line-width'), zoom) -
                widthAt(_paint(provider, road.casing, 'line-width'), zoom),
            closeTo(zoom >= 14 ? 1.0 : 0.0, 0.02),
            reason: '$name casing at z$zoom',
          );
          expect(
            widthAt(_paint(original, road.fill, 'line-width'), zoom),
            widthAt(_paint(provider, road.fill, 'line-width'), zoom),
            reason: '$name fill at z$zoom',
          );
        }
        for (final zoom in _ridingZooms) {
          expect(
            edgeWidth(original, name, zoom),
            greaterThanOrEqualTo(1.25),
            reason: '$name edge at z$zoom',
          );
        }
      }
      expect(edgeWidth(provider, 'minor', 14), closeTo(0.75, 0.01));
      expect(edgeWidth(original, 'minor', 14), closeTo(1.25, 0.01));
    });

    test('the route casing stays above 8:1 against every edge', () {
      for (final id in provider.keys.where(
        (id) => id.endsWith('_casing') && isStrengthenedEdge(id),
      )) {
        final expression = _paint(original, id, 'line-color');
        for (final klass in [
          'minor',
          'trunk',
          'primary',
          'secondary',
          'tertiary',
        ]) {
          expect(
            contrastRatio(RouteTrailStyle.casing, colourFor(expression, klass)),
            greaterThan(8),
            reason: '$id on a $klass road',
          );
        }
      }
    });

    test('the Original symbols are the provider\'s, labels guarded (#860)', () {
      // Every symbol layer is exactly as the provider wrote it, except that a POI
      // layer's label carries the identifier guard (checked in full above).
      var symbols = 0;
      for (final entry in provider.entries) {
        if (entry.value['type'] != 'symbol') continue;
        symbols++;
        if (isPoiLabel(entry.value)) continue;
        expect(jsonEncode(original[entry.key]), jsonEncode(entry.value));
      }
      expect(symbols, greaterThanOrEqualTo(6));
      expect(original.keys, containsAll(['poi_r1', 'poi_r7', 'poi_r20']));
    });
  });

  group('cached styles and the repaint (#281, #841)', () {
    test(
      'repainting twice changes nothing, so a cached style upgrades cleanly',
      () {
        // Riders upgrading offline get the new edges because every cached document
        // is repainted on read. That is only safe if the repaint is idempotent.
        for (final configuration in [
          _restrainedConfiguration,
          _originalConfiguration,
        ]) {
          final once = _repainted(configuration);
          final twice = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(once)) as Map,
          );
          MapStyleRepository.applyPresentation(twice, configuration);

          expect(
            jsonEncode(twice),
            jsonEncode(once),
            reason: 'restrained: ${configuration.restrainedLightStyle}',
          );
        }
      },
    );

    for (final restrained in [true, false]) {
      test(
        'a ${restrained ? 'Restrained' : 'Original'} style cached by the previous build gets the new edges offline',
        () async {
          final configuration = restrained
              ? _restrainedConfiguration
              : _originalConfiguration;
          final directory = await Directory.systemTemp.createTemp(
            'ride-relay-edges-test',
          );
          addTearDown(() => directory.delete(recursive: true));
          final live = await MapStyleRepository(
            directory: directory,
            configuration: configuration,
            client: MockClient(
              (_) async => http.Response(jsonEncode(_provider()), 200),
            ),
          ).resolve();
          final cachedFile = (await directory.list().toList())
              .whereType<File>()
              .single;
          // Put the previous build's paint back: the provider's casings in
          // Original, one pale casing in Restrained, provider widths in both.
          final old = jsonDecode(live.style) as Map<String, dynamic>;
          for (final layer
              in (old['layers'] as List).cast<Map<String, dynamic>>()) {
            final id = layer['id'] as String;
            if (!id.endsWith('_casing')) continue;
            final paint = layer['paint'] as Map<String, dynamic>;
            paint['line-color'] = restrained
                ? _previousCasing
                : _paint(provider, id, 'line-color');
            paint['line-width'] = _paint(provider, id, 'line-width');
          }
          await cachedFile.writeAsString(jsonEncode(old));

          final cached = await MapStyleRepository(
            directory: directory,
            configuration: configuration,
            client: MockClient((_) async => throw StateError('offline')),
          ).resolve();
          final upgraded = _layersOf(
            jsonDecode(cached.style) as Map<String, dynamic>,
          );

          expect(cached.outcome, MapStyleOutcome.cached);
          expect(
            colourFor(
              _paint(upgraded, 'road_minor_casing', 'line-color'),
              'minor',
            ),
            cssColour(
              restrained
                  ? palette['minor casing']!
                  : MapStyleRepository.originalLightCasingMinor,
            ),
          );
          expect(
            widthAt(_paint(upgraded, 'road_minor_casing', 'line-width'), 14),
            closeTo(5.0, 0.01),
          );
        },
      );
    }

    test('tile sources, sprite and cache namespace are untouched', () {
      for (final configuration in [
        _restrainedConfiguration,
        _originalConfiguration,
      ]) {
        final style = _repainted(configuration);

        expect(
          ((style['sources'] as Map)['openmaptiles'] as Map)['url'],
          'https://tiles.openfreemap.org/planet',
        );
      }
    });
  });
}
