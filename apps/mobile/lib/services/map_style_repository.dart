import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'basemap_configuration.dart';

/// Where the style the map is about to render actually came from.
///
/// [MapStyleRepository.resolve] used to answer with a bare style string, so a
/// provider that could not be reached and a provider that answered were
/// indistinguishable to every caller: both got a `String`, and the failure was
/// swallowed by the `catch` that produced the fallback. On the ride map that
/// fallback draws as a plain dark rectangle, which is pixel-identical to a
/// working map of empty countryside — the rider sees "just a blob or dot where
/// you are and a tail where you been" and has no way to tell us which one it
/// was (#281). The outcome travels with the style so the map can say.
enum MapStyleOutcome {
  /// Fetched from the configured provider on this call.
  live,

  /// Served from the on-device cache. The provider was either not due a refresh
  /// or could not be reached, but the style itself is real and carries sources.
  cached,

  /// This build configures no MapLibre style. Route-only by design, not a
  /// failure, and the map already says so.
  unconfigured,

  /// A style is configured, could not be fetched, and nothing usable was
  /// cached. The map will draw [MapStyleRepository.fallbackStyle]: a background
  /// colour and no sources at all.
  unavailable,
}

/// A resolved style together with where it came from.
class MapStyleResolution {
  const MapStyleResolution(this.style, this.outcome, {this.error});

  /// The MapLibre style document, always usable — a failure resolves to
  /// [MapStyleRepository.fallbackStyle] rather than throwing, because losing
  /// the basemap must never take the locally rendered route with it.
  final String style;

  final MapStyleOutcome outcome;

  /// Why the fetch failed, when it did. Carried so a rider can report the
  /// actual fault rather than "the map was blank".
  final Object? error;

  /// Whether [style] carries real basemap data. False means the map will render
  /// the rider's own overlays over an empty background.
  bool get hasBasemap =>
      outcome == MapStyleOutcome.live || outcome == MapStyleOutcome.cached;
}

class MapStyleRepository {
  // Increment whenever the normalized/repainted style document changes. Tile
  // regions keep their provider namespace; only this small style cache rotates.
  static const _styleCacheVersion = 3;

  MapStyleRepository({
    required this.directory,
    required this.configuration,
    http.Client? client,
    this.maximumStyleBytes = 2 * 1024 * 1024,
    this.refreshAfter = const Duration(hours: 24),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const fallbackStyle =
      '{"version":8,"name":"Tail End Charlie offline fallback","sources":{},'
      '"layers":[{"id":"background","type":"background",'
      '"paint":{"background-color":"#111820"}}]}';

  final Directory directory;
  final BasemapConfiguration configuration;
  final int maximumStyleBytes;
  final Duration refreshAfter;
  final http.Client _client;
  final bool _ownsClient;

  static Future<MapStyleRepository> openDefault(
    BasemapConfiguration configuration,
  ) async {
    final support = await getApplicationSupportDirectory();
    return MapStyleRepository(
      directory: Directory(path.join(support.path, 'map_styles')),
      configuration: configuration,
    );
  }

  Future<MapStyleResolution> resolve() async {
    if (!configuration.usesMapLibre) {
      return const MapStyleResolution(
        fallbackStyle,
        MapStyleOutcome.unconfigured,
      );
    }
    final cached = _cacheFile();
    final cachedStyle = await _readValid(cached);
    if (cachedStyle != null &&
        DateTime.now().difference(await cached.lastModified()) < refreshAfter) {
      return MapStyleResolution(cachedStyle, MapStyleOutcome.cached);
    }
    try {
      final style = await _downloadWithRetries();
      if (configuration.persistentCachingAllowed) {
        await directory.create(recursive: true);
        final temporary = File('${cached.path}.tmp');
        await temporary.writeAsString(style, flush: true);
        if (await cached.exists()) await cached.delete();
        await temporary.rename(cached.path);
      }
      return MapStyleResolution(style, MapStyleOutcome.live);
    } on Object catch (error) {
      // A stale cached style is still a real basemap, so it is reported as one.
      // Only the case with nothing to fall back on is a failure, and it is
      // named rather than dressed up as a map (#281).
      if (cachedStyle != null) {
        return MapStyleResolution(
          cachedStyle,
          MapStyleOutcome.cached,
          error: error,
        );
      }
      return MapStyleResolution(
        fallbackStyle,
        MapStyleOutcome.unavailable,
        error: error,
      );
    }
  }

  /// Without persistent caching (the default until a build opts in), every
  /// cold launch needs a fresh fetch to show real tiles at all - one failed
  /// attempt on a slow ride-start connection otherwise commits the whole
  /// session to the tile-less fallback. A couple of quick retries covers the
  /// common transient case without meaningfully delaying a genuine failure.
  Future<String> _downloadWithRetries() async {
    const attempts = 3;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        return await _downloadAndNormalize();
      } on Object {
        if (attempt == attempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
    throw StateError('unreachable');
  }

  Future<String> _downloadAndNormalize() async {
    final styleUri = Uri.parse(configuration.styleUrl);
    final request = http.Request('GET', styleUri)
      ..headers['User-Agent'] = 'me.osholt.ride_relay';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('Map style request failed.');
    }
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > maximumStyleBytes) {
      throw const FormatException('Map style is too large.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length > maximumStyleBytes) {
        throw const FormatException('Map style is too large.');
      }
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map) throw const FormatException('Map style is invalid.');
    final style = Map<String, dynamic>.from(decoded);
    if (style['version'] != 8 ||
        style['sources'] is! Map ||
        style['layers'] is! List) {
      throw const FormatException('Map style is invalid.');
    }
    _normalizeResourceUrl(style, 'sprite', styleUri);
    _normalizeResourceUrl(style, 'glyphs', styleUri);
    final sources = Map<String, dynamic>.from(style['sources'] as Map);
    for (final entry in sources.entries) {
      if (entry.value is! Map) continue;
      final source = Map<String, dynamic>.from(entry.value as Map);
      _normalizeResourceUrl(source, 'url', styleUri);
      _normalizeResourceUrl(source, 'data', styleUri);
      final tiles = source['tiles'];
      if (tiles is List) {
        source['tiles'] = tiles
            .map(
              (value) => value is String ? _absolute(value, styleUri) : value,
            )
            .toList(growable: false);
      }
      sources[entry.key] = source;
    }
    style['sources'] = sources;
    if (configuration.styleUrl == configuration.darkStyleUrl &&
        configuration.styleUrl.isNotEmpty) {
      _repaintForLegibleDarkMode(style);
    } else if (configuration.restrainedLightStyle &&
        configuration.styleUrl == BasemapConfiguration.defaultLightStyleUrl) {
      _repaintForRestrainedLightMode(style);
    }
    return jsonEncode(style);
  }

  // The dark basemap palette, as one table, because the thing that made the
  // fetched style illegible was never a single colour: it was that roads and
  // ground occupied the same narrow band of near-black. Two bands, and every
  // surface belongs to exactly one of them.
  //
  // Ground band. Uniform, near-black, and closed at the top: no ground surface
  // reaches within 8 CIE L* of the dimmest road, and none is darker than
  // [_ground], so the map has no black holes to compete with the roads. The
  // fetched style violated both ends - buildings rgb(10,10,10), piers
  // rgb(12,12,12) and the aeroway fills at pure black all sat *below* the
  // background, while the airfield runway casing at rgba(60,60,60,0.8) sat
  // *above* every minor road (1.06:1 against one, so a lane crossing an
  // airfield disappeared into it). Colour here is reserved for meaning: the
  // ground is achromatic-cool apart from a hint of green on vegetation and one
  // blue for water, which leaves the whole saturated range to the route and
  // hazard palette in `route_trail_style.dart`.
  static const _ground = '#0F1319';
  static const _groundResidential = '#12171D';
  static const _groundAerowayArea = '#14181D';
  static const _groundAerowayCasing = '#14191E';
  static const _groundAerowayTaxiway = '#16191F';
  static const _groundAerowayRunway = '#181C23';
  static const _groundBuilding = '#171C22';
  static const _groundPark = '#141A15';
  static const _groundWood = '#141815';
  static const _groundPier = '#191D24';
  static const _groundIce = '#1B1E24';
  static const _water = '#132434';
  static const _waterway = '#152637';
  static const _boundary = '#1F2125';

  // Road band. A monotonic ramp with at least 3.4 CIE L* between adjacent
  // classes, so the class of a road is readable from its fill rather than only
  // from its width. The fetched dark style paints trunk, primary, secondary and
  // tertiary from one layer in one colour - identical, 1.00:1 - which is why an
  // A road and a lane looked the same at a glance; the light Liberty style has a
  // layer per class and does not have this problem, which is why day worked and
  // night did not.
  static const _roadPath = '#22272C';
  static const _roadRail = '#2A2F35';
  static const _roadService = '#343A42';
  static const _roadMinor = '#484F58';
  static const _roadTertiary = '#545A64';
  static const _roadSecondary = '#5D646D';
  static const _roadPrimary = '#676D77';
  static const _roadTrunk = '#71767F';
  static const _roadMotorway = '#7A7F86';

  /// Roads read as slabs with a dark edge rather than as outlines. The fetched
  /// style did the opposite: a light casing around a black or near-black inner
  /// fill, which is what made a motorway look like two thin grey lines.
  static const _roadCasing = '#090C0F';

  // Labels. Every one of them was effectively unreadable: road names at
  // rgba(80,78,78,1) measured 1.38:1 against the road they sit on, a motorway
  // ref 1.14:1 against its own motorway, and water names were pure black with a
  // *light* halo. A rider who cannot read a road name gets no confirmation that
  // the road they are on is the road they wanted.
  static const _labelRoad = '#BCC1C9';
  static const _labelMotorway = '#C9CCD1';
  static const _labelPlace = '#B1B7BF';
  static const _labelWater = '#748DB1';
  static const _labelHalo = '#0B0E12';
  static const _labelHaloSoft = 'rgba(11,14,18,0.85)';

  /// `highway_minor` carries unclassified and residential roads - the lanes a
  /// group actually rides - together with driveways and forest tracks. They are
  /// not the same thing to a rider, so the fill is data-driven on `class`
  /// instead of painting all three alike.
  static const _minorClassColor = <Object>[
    'match',
    <Object>['get', 'class'],
    <Object>['service', 'track'],
    _roadService,
    _roadMinor,
  ];

  /// The one layer the fetched style uses for trunk, primary, secondary and
  /// tertiary, split back into four steps of the ramp.
  static const _majorClassColor = <Object>[
    'match',
    <Object>['get', 'class'],
    'trunk',
    _roadTrunk,
    'primary',
    _roadPrimary,
    'secondary',
    _roadSecondary,
    _roadTertiary,
  ];

  /// Every surface of the dark basemap as this app renders it, named, so the
  /// hierarchy can be asserted as a ramp rather than colour by colour, and so
  /// anything measuring an overlay against the basemap has one table to measure
  /// against. `map_style_repository_test.dart` holds the bands apart.
  static const darkBasemapPalette = <String, String>{
    'background': _ground,
    'residential landuse': _groundResidential,
    'aeroway area': _groundAerowayArea,
    'aeroway runway casing': _groundAerowayCasing,
    'aeroway taxiway': _groundAerowayTaxiway,
    'aeroway runway': _groundAerowayRunway,
    'building': _groundBuilding,
    'park': _groundPark,
    'wood': _groundWood,
    'pier': _groundPier,
    'ice': _groundIce,
    'water': _water,
    'waterway': _waterway,
    'boundary': _boundary,
    'path': _roadPath,
    'railway': _roadRail,
    'service/track': _roadService,
    'minor': _roadMinor,
    'tertiary': _roadTertiary,
    'secondary': _roadSecondary,
    'primary': _roadPrimary,
    'trunk': _roadTrunk,
    'motorway': _roadMotorway,
    'road casing': _roadCasing,
  };

  /// The road classes in ramp order, dimmest first, for the tests that hold the
  /// hierarchy monotonic and separated.
  static const darkBasemapRoadRamp = <String>[
    'service/track',
    'minor',
    'tertiary',
    'secondary',
    'primary',
    'trunk',
    'motorway',
  ];

  /// The area surfaces a road is drawn on top of, so one test can hold the whole
  /// ground band below the dimmest road.
  ///
  /// `path`, `railway` and `boundary` are deliberately in neither list: they are
  /// linear context that sits between the two bands, above the ground a rider
  /// cannot use and below the roads a rider can. So is `road casing`, which is
  /// darker than the background on purpose.
  static const darkBasemapGroundBand = <String>[
    'background',
    'residential landuse',
    'aeroway area',
    'aeroway runway casing',
    'aeroway taxiway',
    'aeroway runway',
    'building',
    'park',
    'wood',
    'pier',
    'ice',
    'water',
    'waterway',
  ];

  // A daylight companion to the dark palette: quiet ground, restrained road
  // tint and one clear hierarchy. The route remains the strongest saturated
  // line on screen, while place and road names still provide orientation.
  static const lightBasemapPalette = <String, String>{
    'background': '#F3F2ED',
    'residential landuse': '#ECEBE5',
    'park': '#E5EADF',
    'wood': '#E1E7DC',
    'grass': '#E8ECE2',
    'ice': '#F5F7F5',
    'wetland': '#E2E9E3',
    'water': '#D8E5EA',
    'waterway': '#C2D7E0',
    'sand': '#EEE8D8',
    'building': '#DEDCD6',
    'boundary': '#B6B8B7',
    'path': '#C7CAC6',
    'service/track': '#F7F6F1',
    'minor': '#FEFDF9',
    'tertiary': '#FCF9ED',
    'secondary': '#F8F2DD',
    'primary': '#F4E9CF',
    'trunk': '#F1E2C2',
    'motorway': '#EEDBB6',
    'road casing': '#C4C5C1',
  };

  static const lightBasemapRoadRamp = <String>[
    'service/track',
    'minor',
    'tertiary',
    'secondary',
    'primary',
    'trunk',
    'motorway',
  ];

  static const _lightSecondaryTertiary = <Object>[
    'match',
    <Object>['get', 'class'],
    'secondary',
    '#F8F2DD',
    '#FCF9ED',
  ];

  static const _lightTrunkPrimary = <Object>[
    'match',
    <Object>['get', 'class'],
    'trunk',
    '#F1E2C2',
    '#F4E9CF',
  ];

  static const _lightLinkClassColor = <Object>[
    'match',
    <Object>['get', 'class'],
    'motorway',
    '#EEDBB6',
    'trunk',
    '#F1E2C2',
    'primary',
    '#F4E9CF',
    'secondary',
    '#F8F2DD',
    'tertiary',
    '#FCF9ED',
    '#FEFDF9',
  ];

  static const _restrainedLightPaint = <String, Map<String, Object?>>{
    'background': {'background-color': '#F3F2ED'},
    'natural_earth': {
      'raster-saturation': -0.75,
      'raster-contrast': -0.1,
      'raster-opacity': 0.55,
    },
    'park': {'fill-color': '#E5EADF', 'fill-opacity': 0.8},
    'park_outline': {'line-color': '#D6DED0'},
    'landuse_residential': {'fill-color': '#ECEBE5'},
    'landcover_wood': {
      'fill-color': '#E1E7DC',
      'fill-pattern': null,
      'fill-opacity': 1,
    },
    'landcover_grass': {'fill-color': '#E8ECE2'},
    'landcover_ice': {'fill-color': '#F5F7F5'},
    'landcover_wetland': {'fill-color': '#E2E9E3'},
    'landuse_pitch': {'fill-color': '#E3E9DD'},
    'landuse_track': {'fill-color': '#EAE8E1'},
    'landuse_cemetery': {'fill-color': '#E5E9E1'},
    'landuse_hospital': {'fill-color': '#EEE8E5'},
    'landuse_school': {'fill-color': '#ECE9E1'},
    'water': {'fill-color': '#D8E5EA'},
    'waterway_tunnel': {'line-color': '#C2D7E0'},
    'waterway_river': {'line-color': '#C2D7E0'},
    'waterway_other': {'line-color': '#C2D7E0'},
    'landcover_sand': {'fill-color': '#EEE8D8'},
    'aeroway_fill': {'fill-color': '#E8E7E2'},
    'aeroway_runway': {'line-color': '#D2D3CF'},
    'aeroway_taxiway': {'line-color': '#D8D9D5'},
    'road_area_pattern': {'fill-color': '#F7F6F1', 'fill-pattern': null},
    'building': {'fill-color': '#DEDCD6', 'fill-outline-color': '#D2D0CA'},
    'building-3d': {
      'fill-extrusion-color': '#DEDCD6',
      'fill-extrusion-opacity': 0.55,
    },
    'boundary_3': {'line-color': '#C8C9C7'},
    'boundary_2': {'line-color': '#B6B8B7'},
    'boundary_disputed': {'line-color': '#B6B8B7'},
    'waterway_line_label': {
      'text-color': '#526D7A',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'water_name_point_label': {
      'text-color': '#526D7A',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'water_name_line_label': {
      'text-color': '#526D7A',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'highway-name-path': {
      'text-color': '#626A70',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'highway-name-minor': {
      'text-color': '#535B63',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'highway-name-major': {
      'text-color': '#454E57',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_other': {
      'text-color': '#555D64',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_village': {
      'text-color': '#4B535B',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_town': {
      'text-color': '#454D55',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_state': {
      'text-color': '#555D64',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_city': {
      'text-color': '#3F474F',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_city_capital': {
      'text-color': '#394149',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_country_3': {
      'text-color': '#596168',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_country_2': {
      'text-color': '#4E565E',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
    'label_country_1': {
      'text-color': '#434B53',
      'text-halo-color': 'rgba(243,242,237,0.9)',
    },
  };

  /// The dark style is fetched rather than hand-authored, so this is the only
  /// point with the parsed layers in hand at which to repaint it. A `null`
  /// override removes the paint property instead of setting it. Anything not
  /// listed here, and any layer id no longer present upstream, is left
  /// untouched.
  static const _legibleDarkModePaint = <String, Map<String, Object?>>{
    // Ground.
    'background': {'background-color': _ground},
    'water': {'fill-color': _water},
    'waterway': {'line-color': _waterway},
    'landcover_ice_shelf': {'fill-color': _groundIce},
    'landcover_glacier': {'fill-color': _groundIce},
    'landuse_residential': {'fill-color': _groundResidential},
    'landuse_park': {'fill-color': _groundPark},
    // `fill-pattern` wins over `fill-color` wherever the sprite loads, so
    // repainting woodland without dropping the pattern was a no-op.
    'landcover_wood': {
      'fill-color': _groundWood,
      'fill-pattern': null,
      'fill-opacity': 1,
    },
    'building': {'fill-color': _groundBuilding, 'fill-outline-color': _ground},
    'road_area_pier': {'fill-color': _groundPier},
    'road_pier': {'line-color': _groundPier},
    // The airfield: the most prominent thing on a road-riding map before this,
    // and the one the field report named. Pure-black runway and apron fills
    // inside a light casing, all of it now inside the ground band.
    'aeroway-area': {'fill-color': _groundAerowayArea},
    'aeroway-runway': {'line-color': _groundAerowayRunway},
    'aeroway-runway-casing': {'line-color': _groundAerowayCasing},
    'aeroway-taxiway': {'line-color': _groundAerowayTaxiway},
    // Roads.
    'highway_path': {'line-color': _roadPath},
    'highway_minor': {'line-color': _minorClassColor, 'line-opacity': 1},
    'highway_major_casing': {'line-color': _roadCasing},
    'highway_major_inner': {'line-color': _majorClassColor},
    'highway_major_subtle': {'line-color': _roadSecondary},
    'highway_motorway_casing': {'line-color': _roadCasing},
    'highway_motorway_inner': {'line-color': _roadMotorway},
    'highway_motorway_subtle': {'line-color': _roadMotorway},
    'railway': {'line-color': _roadRail},
    'railway_dashline': {'line-color': _ground},
    'railway_minor': {'line-color': _roadRail},
    'railway_minor_dashline': {'line-color': _ground},
    'railway_transit': {'line-color': _roadRail},
    'railway_transit_dashline': {'line-color': _ground},
    'boundary_state': {'line-color': _boundary},
    'boundary_country_z0-4': {'line-color': _boundary},
    'boundary_country_z5-': {'line-color': _boundary},
    // Labels.
    'highway_name_other': {
      'text-color': _labelRoad,
      'text-halo-color': _labelHalo,
      'text-halo-width': 1.2,
    },
    'highway_name_motorway': {
      'text-color': _labelMotorway,
      'text-halo-color': _labelHalo,
      'text-halo-width': 1.2,
    },
    'water_name': {
      'text-color': _labelWater,
      'text-halo-color': _labelHalo,
      'text-halo-width': 1.2,
    },
    'place_other': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_suburb': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_village': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_town': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_city': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_city_large': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_state': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_country_other': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_country_minor': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
    'place_country_major': {
      'text-color': _labelPlace,
      'text-halo-color': _labelHaloSoft,
    },
  };

  static void _repaintForLegibleDarkMode(Map<String, dynamic> style) {
    final layers = style['layers'] as List;
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      if (layer is! Map) continue;
      final overrides = _legibleDarkModePaint[layer['id']];
      if (overrides == null) continue;
      final updated = Map<String, dynamic>.from(layer);
      final paint = Map<String, dynamic>.from(
        (updated['paint'] as Map?) ?? const {},
      );
      for (final override in overrides.entries) {
        if (override.value == null) {
          paint.remove(override.key);
        } else {
          paint[override.key] = override.value;
        }
      }
      updated['paint'] = paint;
      layers[i] = updated;
    }
  }

  static void _repaintForRestrainedLightMode(Map<String, dynamic> style) {
    final layers = style['layers'] as List;
    final repainted = <Object?>[];
    for (final layer in layers) {
      if (layer is! Map) {
        repainted.add(layer);
        continue;
      }
      final id = layer['id'];
      if (id is! String) {
        repainted.add(layer);
        continue;
      }
      // The Liberty provider's four POI tiers are the visual noise this mode
      // is meant to remove. Road shields, one-way arrows and place labels stay.
      if (id.startsWith('poi_') || id == 'airport') continue;
      final overrides =
          _restrainedLightPaint[id] ?? _restrainedLightRoadPaint(id);
      if (overrides == null) {
        repainted.add(layer);
        continue;
      }
      final updated = Map<String, dynamic>.from(layer);
      final paint = Map<String, dynamic>.from(
        (updated['paint'] as Map?) ?? const {},
      );
      for (final override in overrides.entries) {
        if (override.value == null) {
          paint.remove(override.key);
        } else {
          paint[override.key] = override.value;
        }
      }
      updated['paint'] = paint;
      repainted.add(updated);
    }
    style['layers'] = repainted;
  }

  static Map<String, Object?>? _restrainedLightRoadPaint(String id) {
    if (!(id.startsWith('road_') ||
        id.startsWith('tunnel_') ||
        id.startsWith('bridge_'))) {
      return null;
    }
    if (id.contains('one_way_arrow')) return null;
    if (id.endsWith('_casing')) {
      return const {'line-color': '#C4C5C1'};
    }
    if (id.endsWith('_hatching')) {
      return const {'line-color': '#F3F2ED'};
    }
    if (id.contains('_major_rail') || id.contains('_transit_rail')) {
      return const {'line-color': '#B6B8B7'};
    }
    if (id.contains('path_pedestrian')) {
      return const {'line-color': '#C7CAC6'};
    }
    if (id.contains('service_track')) {
      return const {'line-color': '#F7F6F1'};
    }
    if (id.contains('secondary_tertiary')) {
      return const {'line-color': _lightSecondaryTertiary};
    }
    if (id.contains('trunk_primary')) {
      return const {'line-color': _lightTrunkPrimary};
    }
    if (id.contains('motorway')) {
      return const {'line-color': '#EEDBB6'};
    }
    if (id.endsWith('_link')) {
      return const {'line-color': _lightLinkClassColor};
    }
    if (id.contains('minor') || id.contains('street')) {
      return const {'line-color': '#FEFDF9'};
    }
    return null;
  }

  Future<String?> _readValid(File file) async {
    if (!await file.exists() || await file.length() > maximumStyleBytes) {
      return null;
    }
    try {
      final value = await file.readAsString();
      final decoded = jsonDecode(value);
      if (decoded is Map &&
          decoded['version'] == 8 &&
          decoded['sources'] is Map &&
          decoded['layers'] is List) {
        return value;
      }
    } on Object {
      // A damaged cache must never hide the locally rendered route.
    }
    return null;
  }

  File _cacheFile() {
    final lightVariant =
        configuration.styleUrl == BasemapConfiguration.defaultLightStyleUrl
        ? configuration.restrainedLightStyle
        : true;
    final digest = sha256.convert(
      utf8.encode(
        '$_styleCacheVersion:${configuration.styleUrl}:$lightVariant',
      ),
    );
    return File(path.join(directory.path, '$digest.json'));
  }

  static void _normalizeResourceUrl(
    Map<String, dynamic> target,
    String key,
    Uri base,
  ) {
    final value = target[key];
    if (value is String) target[key] = _absolute(value, base);
  }

  static String _absolute(String value, Uri base) {
    final parsed = Uri.tryParse(value);
    if (parsed == null || parsed.hasScheme || value.startsWith('/')) {
      return value.startsWith('/') ? _resolveTemplate(base, value) : value;
    }
    return _resolveTemplate(base, value);
  }

  static String _resolveTemplate(Uri base, String value) => base
      .resolve(value)
      .toString()
      .replaceAll('%7B', '{')
      .replaceAll('%7D', '}');

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
