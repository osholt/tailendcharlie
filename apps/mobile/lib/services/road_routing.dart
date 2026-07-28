import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../domain/distance_unit.dart';
import '../domain/imported_route.dart';
import 'measurement_formatter.dart';
import 'route_twistiness.dart';

class RoutingConfiguration {
  const RoutingConfiguration({
    required this.routingBaseUrl,
    required this.geocodingBaseUrl,
    required this.motorcycleRoutingUrl,
  });

  factory RoutingConfiguration.fromEnvironment() => RoutingConfiguration(
    routingBaseUrl: Uri.parse(
      const String.fromEnvironment(
        'RIDE_RELAY_ROUTING_URL',
        defaultValue: 'https://router.project-osrm.org',
      ),
    ),
    geocodingBaseUrl: Uri.parse(
      const String.fromEnvironment(
        'RIDE_RELAY_GEOCODING_URL',
        defaultValue: 'https://nominatim.openstreetmap.org',
      ),
    ),
    // The same Valhalla motorcycle service the web planner uses for the
    // exclusions OSRM's driving profile cannot express, so the two surfaces ask
    // the same engine the same question.
    motorcycleRoutingUrl: Uri.parse(
      const String.fromEnvironment(
        'RIDE_RELAY_MOTORCYCLE_ROUTING_URL',
        defaultValue: 'https://valhalla1.openstreetmap.de/route',
      ),
    ),
  );

  final Uri routingBaseUrl;
  final Uri geocodingBaseUrl;
  final Uri motorcycleRoutingUrl;
}

class RoadRouteResult {
  const RoadRouteResult({
    required this.points,
    required this.distanceMeters,
    required this.duration,
    this.maneuvers = const [],
    this.twistinessScore,
    this.preferences,
  });

  final List<GeoPoint> points;
  final double distanceMeters;
  final Duration duration;
  final List<RoadRouteManeuver> maneuvers;

  /// Degrees of useful heading change per kilometre, as scored by
  /// [RouteTwistiness]. Null when the caller asked for no score.
  final double? twistinessScore;

  /// What the route was actually planned for. Null when the caller asked for
  /// nothing in particular.
  final RoutePreferences? preferences;
}

/// A decision reported by the routing engine rather than inferred from a
/// bend in recorded GPS geometry. These are the points where a second rider
/// may need to mark a junction.
class RoadRouteManeuver extends RouteManeuver {
  const RoadRouteManeuver({
    required super.position,
    required super.type,
    super.modifier,
    super.name,
    super.ref,
    super.exitNumber,
    super.drivingSide,
    super.bearingBeforeDegrees,
    super.bearingAfterDegrees,
    super.lanes,
  });

  /// OSRM does not expose UK give-way signage, but these manoeuvres are the
  /// routing decisions where the group leaves its current road or must
  /// negotiate a junction. A traffic-sign data source can add further points.
  bool get requiresSecondBikeDrop => const {
    'turn',
    'fork',
    'end of road',
    'roundabout',
    'rotary',
    'roundabout turn',
    'merge',
    'on ramp',
    'off ramp',
  }.contains(type);

  factory RoadRouteManeuver.fromJson(Map<String, Object?> json) {
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final type = json['type'];
    if (latitude is! num || longitude is! num || type is! String) {
      throw const FormatException('Route manoeuvre is invalid.');
    }
    return RoadRouteManeuver(
      position: GeoPoint(
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
      ),
      type: type,
      modifier: json['modifier'] as String?,
      name: json['name'] as String?,
      ref: json['ref'] as String?,
      exitNumber: (json['exitNumber'] as num?)?.toInt(),
      drivingSide: json['drivingSide'] as String?,
      bearingBeforeDegrees: (json['bearingBeforeDegrees'] as num?)?.toDouble(),
      bearingAfterDegrees: (json['bearingAfterDegrees'] as num?)?.toDouble(),
      lanes:
          (json['lanes'] as List?)
              ?.whereType<Map>()
              .map(
                (lane) => RouteLane.fromJson(Map<String, Object?>.from(lane)),
              )
              .toList(growable: false) ??
          const [],
    );
  }
}

abstract interface class RoadRoutingService {
  /// Routes through [waypoints].
  ///
  /// [preferences] is what the rider asked the route to be like. Null means
  /// "whatever this service does by default", which is what an internal caller
  /// such as an off-route rejoin wants: a rejoin leg is not a planning decision
  /// and must not silently acquire the exclusions of the route it rejoins.
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
  });
}

class OsrmRoadRoutingService implements RoadRoutingService {
  const OsrmRoadRoutingService({
    required this.client,
    required this.baseUrl,
    this.timeout = const Duration(seconds: 15),
    this.maximumResponseBytes = 5 * 1024 * 1024,
  });

  /// Alternatives asked of OSRM when a bendier style has to choose between
  /// them. The web planner asks for the same three.
  static const alternativeCount = 3;

  final http.Client client;
  final Uri baseUrl;
  final Duration timeout;
  final int maximumResponseBytes;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
  }) async {
    if (waypoints.length < 2) {
      throw const FormatException('At least two route points are required.');
    }
    if (waypoints.length > 100) {
      throw const FormatException(
        'A maximum of 100 route points is supported.',
      );
    }
    _requireHttps(baseUrl, 'Routing');
    final style = preferences?.style ?? RouteStyle.quickest;
    final coordinates = waypoints
        .map((point) => '${point.longitude},${point.latitude}')
        .join(';');
    final path = '${_basePath(baseUrl)}/route/v1/driving/$coordinates';
    final uri = baseUrl.replace(
      path: path,
      queryParameters: {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'true',
        // Only asked for when a style has to choose. The quickest route needs
        // no alternatives, and not asking keeps the default request identical
        // to the one this client has always sent.
        if (style.prefersBends) 'alternatives': '$alternativeCount',
      },
    );
    final response = await client
        .get(uri, headers: _requestHeaders)
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('Road routing failed (${response.statusCode}).');
    }
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const FormatException('Road routing response is too large.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['code'] != 'Ok') {
      final message = decoded is Map ? decoded['message'] : null;
      throw FormatException(
        message is String && message.trim().isNotEmpty
            ? message
            : 'No road route was found.',
      );
    }
    final routes = decoded['routes'];
    if (routes is! List || routes.isEmpty || routes.first is! Map) {
      throw const FormatException('Road routing returned no route.');
    }
    final parsed = routes
        .whereType<Map>()
        .map((route) => _parseRoute(Map<String, dynamic>.from(route)))
        .toList(growable: false);
    final chosen =
        RouteTwistiness.chooseWithinDetour(
          parsed,
          style: style,
          duration: (candidate) =>
              candidate.duration.inMilliseconds.toDouble() / 1000,
          twistiness: (candidate) => candidate.twistinessScore ?? 0,
        ) ??
        parsed.first;
    return RoadRouteResult(
      points: chosen.points,
      distanceMeters: chosen.distanceMeters,
      duration: chosen.duration,
      maneuvers: chosen.maneuvers,
      twistinessScore: chosen.twistinessScore,
      preferences: preferences,
    );
  }

  RoadRouteResult _parseRoute(Map<String, dynamic> route) {
    final geometry = route['geometry'];
    if (geometry is! Map || geometry['coordinates'] is! List) {
      throw const FormatException('Road routing geometry is invalid.');
    }
    final points = (geometry['coordinates'] as List)
        .map((coordinate) {
          if (coordinate is! List || coordinate.length < 2) {
            throw const FormatException('Road routing coordinate is invalid.');
          }
          final longitude = coordinate[0];
          final latitude = coordinate[1];
          if (longitude is! num || latitude is! num) {
            throw const FormatException('Road routing coordinate is invalid.');
          }
          return GeoPoint(
            latitude: latitude.toDouble(),
            longitude: longitude.toDouble(),
          );
        })
        .toList(growable: false);
    if (points.length < 2) {
      throw const FormatException(
        'Road routing returned insufficient geometry.',
      );
    }
    final distance = route['distance'];
    final duration = route['duration'];
    if (distance is! num || duration is! num) {
      throw const FormatException('Road routing summary is invalid.');
    }
    return RoadRouteResult(
      points: points,
      distanceMeters: distance.toDouble(),
      duration: Duration(milliseconds: (duration.toDouble() * 1000).round()),
      maneuvers: _parseManeuvers(route['legs']),
      twistinessScore: RouteTwistiness.score(
        points,
        distanceMeters: distance.toDouble(),
      ),
    );
  }

  static List<RoadRouteManeuver> _parseManeuvers(Object? rawLegs) {
    if (rawLegs is! List) return const [];
    final maneuvers = <RoadRouteManeuver>[];
    for (final rawLeg in rawLegs) {
      if (rawLeg is! Map || rawLeg['steps'] is! List) continue;
      for (final rawStep in rawLeg['steps'] as List) {
        if (rawStep is! Map || rawStep['maneuver'] is! Map) continue;
        final step = Map<String, Object?>.from(rawStep);
        final rawManeuver = Map<String, Object?>.from(
          rawStep['maneuver'] as Map,
        );
        final location = rawManeuver['location'];
        final type = rawManeuver['type'];
        if (location is! List ||
            location.length < 2 ||
            location[0] is! num ||
            location[1] is! num ||
            type is! String) {
          continue;
        }
        maneuvers.add(
          RoadRouteManeuver(
            position: GeoPoint(
              latitude: (location[1] as num).toDouble(),
              longitude: (location[0] as num).toDouble(),
            ),
            type: type,
            modifier: rawManeuver['modifier'] as String?,
            name: step['name'] as String?,
            ref: step['ref'] as String?,
            // OSRM documents `exit` as the roundabout/rotary exit count only.
            exitNumber: (rawManeuver['exit'] as num?)?.toInt(),
            drivingSide: step['driving_side'] as String?,
            bearingBeforeDegrees: _bearing(rawManeuver['bearing_before']),
            bearingAfterDegrees: _bearing(rawManeuver['bearing_after']),
            lanes: _parseLanes(step['intersections']),
          ),
        );
      }
    }
    return List.unmodifiable(maneuvers);
  }

  /// OSRM reports `bearing_before`/`bearing_after` in whole degrees clockwise
  /// from true north. They are the manoeuvre's own geometry and are what the
  /// app uses to state a direction, rather than the driving side.
  static double? _bearing(Object? value) {
    if (value is! num || !value.isFinite) return null;
    return (value.toDouble() % 360 + 360) % 360;
  }

  static List<RouteLane> _parseLanes(Object? rawIntersections) {
    if (rawIntersections is! List) return const [];
    for (final rawIntersection in rawIntersections) {
      if (rawIntersection is! Map || rawIntersection['lanes'] is! List) {
        continue;
      }
      final lanes = <RouteLane>[];
      for (final rawLane in rawIntersection['lanes'] as List) {
        if (rawLane is! Map) continue;
        final indications =
            (rawLane['indications'] as List?)
                ?.whereType<String>()
                .map((value) => value.trim().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toList(growable: false) ??
            const <String>[];
        lanes.add(
          RouteLane(indications: indications, valid: rawLane['valid'] == true),
        );
      }
      if (lanes.isNotEmpty) return List.unmodifiable(lanes);
    }
    return const [];
  }
}

/// Valhalla motorcycle routing, for the exclusions OSRM cannot express.
///
/// It sends the same request the web planner sends: `costing: motorcycle`,
/// `costing_options.motorcycle` from
/// [RoutePreferences.valhallaMotorcycleCostingOptions], and kilometre units. The
/// two surfaces therefore ask one engine one question and get one answer.
///
/// It deliberately reports **no manoeuvres**. Valhalla numbers its manoeuvre
/// types where OSRM names them, and this app turns a manoeuvre into a spoken
/// instruction and a second-bike marker drop, so a mapping invented without a
/// verified fixture could state the wrong direction at a junction. Until such a
/// fixture exists the route falls back to geometry-derived decision points, the
/// same as an imported GPX route, and [PreferenceAwareRoadRoutingService] says
/// so out loud.
class ValhallaMotorcycleRoutingService implements RoadRoutingService {
  const ValhallaMotorcycleRoutingService({
    required this.client,
    required this.routeUrl,
    this.timeout = const Duration(seconds: 20),
    this.maximumResponseBytes = 5 * 1024 * 1024,
  });

  final http.Client client;
  final Uri routeUrl;
  final Duration timeout;
  final int maximumResponseBytes;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
  }) async {
    if (waypoints.length < 2) {
      throw const FormatException('At least two route points are required.');
    }
    if (waypoints.length > 100) {
      throw const FormatException(
        'A maximum of 100 route points is supported.',
      );
    }
    _requireHttps(routeUrl, 'Motorcycle routing');
    final resolved = preferences ?? RoutePreferences.defaults;
    final request = {
      'locations': waypoints
          .map(
            (point) => {
              'lat': point.latitude,
              'lon': point.longitude,
              'type': 'break',
            },
          )
          .toList(growable: false),
      'costing': 'motorcycle',
      'costing_options': {
        'motorcycle': resolved.valhallaMotorcycleCostingOptions(),
      },
      'units': 'kilometers',
      'directions_options': {'units': 'kilometers'},
    };
    final response = await client
        .get(
          routeUrl.replace(
            queryParameters: {
              ...routeUrl.queryParameters,
              'json': jsonEncode(request),
            },
          ),
          headers: _requestHeaders,
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Motorcycle routing failed (${response.statusCode}).',
      );
    }
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const FormatException('Motorcycle routing response is too large.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final trip = decoded is Map ? decoded['trip'] : null;
    if (trip is! Map || trip['legs'] is! List) {
      final error = decoded is Map ? decoded['error'] : null;
      throw FormatException(
        error is String && error.trim().isNotEmpty
            ? error
            : 'No road route was found for those stops.',
      );
    }
    final points = <GeoPoint>[];
    for (final leg in trip['legs'] as List) {
      if (leg is! Map) continue;
      final shape = decodeValhallaShape(leg['shape']);
      points.addAll(points.isEmpty ? shape : shape.skip(1));
    }
    if (points.length < 2) {
      throw const FormatException(
        'Motorcycle routing returned insufficient geometry.',
      );
    }
    final summary = trip['summary'];
    // Valhalla reports `length` in the requested units and `time` in seconds.
    final lengthKm = summary is Map ? summary['length'] : null;
    final seconds = summary is Map ? summary['time'] : null;
    if (lengthKm is! num || seconds is! num) {
      throw const FormatException('Motorcycle routing summary is invalid.');
    }
    final distanceMeters = lengthKm.toDouble() * 1000;
    return RoadRouteResult(
      points: List.unmodifiable(points),
      distanceMeters: distanceMeters,
      duration: Duration(milliseconds: (seconds.toDouble() * 1000).round()),
      twistinessScore: RouteTwistiness.score(
        points,
        distanceMeters: distanceMeters,
      ),
      preferences: resolved,
    );
  }

  /// Valhalla encodes leg shapes as a precision-6 encoded polyline.
  static List<GeoPoint> decodeValhallaShape(Object? encoded) {
    if (encoded is! String || encoded.isEmpty) return const [];
    const factor = 1000000.0;
    final points = <GeoPoint>[];
    var index = 0;
    var latitude = 0;
    var longitude = 0;
    int readValue() {
      var result = 0;
      var shift = 0;
      int byte;
      do {
        if (index >= encoded.length) {
          throw const FormatException(
            'Motorcycle routing returned an invalid route shape.',
          );
        }
        byte = encoded.codeUnitAt(index) - 63;
        index += 1;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      return result.isOdd ? ~(result >> 1) : result >> 1;
    }

    while (index < encoded.length) {
      latitude += readValue();
      longitude += readValue();
      points.add(
        GeoPoint(latitude: latitude / factor, longitude: longitude / factor),
      );
    }
    return points;
  }
}

/// Sends a request to whichever engine can honour the rider's preferences.
///
/// The dispatch rule is [RoutePreferences.requiresMotorcycleCosting], which is
/// the web planner's `requestRoadRoute` rule. Same rule, same engine, same
/// options, same route.
class PreferenceAwareRoadRoutingService implements RoadRoutingService {
  const PreferenceAwareRoadRoutingService({
    required this.osrm,
    required this.motorcycle,
  });

  /// Warning shown when the motorcycle engine had to be used and therefore no
  /// turn instructions came back. Stated rather than hidden: the route is still
  /// correct, but the app will infer junctions from its shape.
  static const motorcycleManeuverWarning =
      'These preferences need the motorcycle router, which does not return turn '
      'instructions. Junctions are worked out from the route shape instead.';

  final RoadRoutingService osrm;
  final RoadRoutingService motorcycle;

  bool usesMotorcycleCosting(RoutePreferences? preferences) =>
      preferences?.requiresMotorcycleCosting ?? false;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
  }) => usesMotorcycleCosting(preferences)
      ? motorcycle.routeThrough(waypoints, preferences: preferences)
      : osrm.routeThrough(waypoints, preferences: preferences);
}

class DestinationMatch {
  const DestinationMatch({required this.label, required this.point});

  final String label;
  final GeoPoint point;
}

abstract interface class DestinationSearchService {
  Future<List<DestinationMatch>> search(String query);
}

class NominatimDestinationSearchService implements DestinationSearchService {
  NominatimDestinationSearchService({
    required this.client,
    required this.baseUrl,
    this.timeout = const Duration(seconds: 10),
  });

  final http.Client client;
  final Uri baseUrl;
  final Duration timeout;
  final Map<String, List<DestinationMatch>> _cache = {};

  @override
  Future<List<DestinationMatch>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Enter a destination.');
    }
    final coordinates = _parseCoordinates(trimmed);
    if (coordinates != null) {
      return [DestinationMatch(label: trimmed, point: coordinates)];
    }
    final cacheKey = trimmed.toLowerCase();
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    _requireHttps(baseUrl, 'Destination search');
    final uri = baseUrl.replace(
      path: '${_basePath(baseUrl)}/search',
      queryParameters: {
        'q': trimmed,
        'format': 'jsonv2',
        'limit': '5',
        'addressdetails': '0',
      },
    );
    final response = await client
        .get(uri, headers: _requestHeaders)
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Destination search failed (${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const FormatException('Destination search response is invalid.');
    }
    final matches = <DestinationMatch>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final latitude = double.tryParse('${item['lat'] ?? ''}');
      final longitude = double.tryParse('${item['lon'] ?? ''}');
      final label = item['display_name'];
      if (latitude == null ||
          longitude == null ||
          label is! String ||
          label.trim().isEmpty) {
        continue;
      }
      matches.add(
        DestinationMatch(
          label: label.trim(),
          point: GeoPoint(latitude: latitude, longitude: longitude),
        ),
      );
    }
    if (matches.isEmpty) {
      throw FormatException('No destination matched "$trimmed".');
    }
    final result = List<DestinationMatch>.unmodifiable(matches);
    _cache[cacheKey] = result;
    return result;
  }
}

class DestinationRoutePlanner {
  DestinationRoutePlanner({
    required this.searchService,
    required this.routingService,
    String Function()? idFactory,
    DateTime Function()? clock,
  }) : _idFactory = idFactory ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final DestinationSearchService searchService;
  final RoadRoutingService routingService;
  final String Function() _idFactory;
  final DateTime Function() _clock;

  Future<DestinationRoutePlan> planForReview({
    GeoPoint? origin,
    String? originQuery,
    List<String> stopQueries = const [],
    required String query,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    RoutePreferences preferences = RoutePreferences.defaults,
  }) async {
    final warnings = <String>[];
    final GeoPoint resolvedOrigin;
    String originLabel;
    if (originQuery != null && originQuery.trim().isNotEmpty) {
      final originMatches = await searchService.search(originQuery);
      if (originMatches.length > 1) {
        warnings.add(
          'The start location had ${originMatches.length} possible matches. '
          'Check the selected pin before confirming.',
        );
      }
      resolvedOrigin = originMatches.first.point;
      originLabel = originMatches.first.label;
    } else if (origin != null) {
      resolvedOrigin = origin;
      originLabel = 'Current location';
    } else {
      throw const FormatException(
        'A start location or current position is required.',
      );
    }

    final resolvedStops = <DestinationMatch>[];
    for (var index = 0; index < stopQueries.length; index += 1) {
      final value = stopQueries[index].trim();
      if (value.isEmpty) continue;
      final matches = await searchService.search(value);
      if (matches.length > 1) {
        warnings.add(
          'Stop ${index + 1} had ${matches.length} possible matches. '
          'Check the selected pin before confirming.',
        );
      }
      resolvedStops.add(matches.first);
    }

    final destinationMatches = await searchService.search(query);
    if (destinationMatches.length > 1) {
      warnings.add(
        'The destination had ${destinationMatches.length} possible matches. '
        'Check the selected pin before confirming.',
      );
    }
    final destination = destinationMatches.first;
    final roadRoute = await routingService.routeThrough([
      resolvedOrigin,
      ...resolvedStops.map((stop) => stop.point),
      destination.point,
    ], preferences: preferences);
    if (routingService case final PreferenceAwareRoadRoutingService dispatcher
        when dispatcher.usesMotorcycleCosting(preferences) &&
            roadRoute.maneuvers.isEmpty) {
      warnings.add(PreferenceAwareRoadRoutingService.motorcycleManeuverWarning);
    }
    final id = _idFactory();
    final route = ImportedRoute(
      id: id,
      name: 'To ${_shortLabel(destination.label)}',
      description:
          'Road route generated by Tail End Charlie. '
          '${MeasurementFormatter(distanceUnit).distance(roadRoute.distanceMeters)}, '
          '${_durationLabel(roadRoute.duration)}. '
          '${preferences.summary}',
      importedAt: _clock().toUtc(),
      sourceFileName: 'ride-relay-destination-$id.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          name: 'Road route to ${_shortLabel(destination.label)}',
          points: roadRoute.points,
        ),
      ],
      waypoints: [
        RouteWaypoint(
          point: resolvedOrigin,
          name: originLabel == 'Current location'
              ? 'Start'
              : _shortLabel(originLabel),
          description: originLabel,
          symbol: 'Flag, Blue',
        ),
        for (var index = 0; index < resolvedStops.length; index += 1)
          RouteWaypoint(
            point: resolvedStops[index].point,
            name: _shortLabel(resolvedStops[index].label),
            description: resolvedStops[index].label,
            symbol: 'Flag, Green',
          ),
        RouteWaypoint(
          point: destination.point,
          name: _shortLabel(destination.label),
          description: destination.label,
          symbol: 'Flag, Red',
        ),
      ],
      maneuvers: roadRoute.maneuvers,
      preferences: preferences,
    );
    return DestinationRoutePlan(
      route: route,
      distanceMeters: roadRoute.distanceMeters,
      duration: roadRoute.duration,
      twistinessScore: roadRoute.twistinessScore,
      warnings: List.unmodifiable(warnings),
    );
  }

  /// [originQuery] is geocoded the same way [query] (the destination)
  /// already is, and takes priority when given - the route need not start
  /// from the rider's current location. [origin] is the fallback used only
  /// when there is no [originQuery]; at least one of the two is required.
  Future<ImportedRoute> plan({
    GeoPoint? origin,
    String? originQuery,
    List<String> stopQueries = const [],
    required String query,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    RoutePreferences preferences = RoutePreferences.defaults,
  }) async {
    return (await planForReview(
      origin: origin,
      originQuery: originQuery,
      stopQueries: stopQueries,
      query: query,
      distanceUnit: distanceUnit,
      preferences: preferences,
    )).route;
  }
}

class DestinationRoutePlan {
  const DestinationRoutePlan({
    required this.route,
    required this.distanceMeters,
    required this.duration,
    this.twistinessScore,
    this.warnings = const [],
  });

  final ImportedRoute route;
  final double distanceMeters;
  final Duration duration;

  /// The route's own twistiness, so the app can show the same number the web
  /// planner shows for the same geometry.
  final double? twistinessScore;
  final List<String> warnings;
}

const _requestHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'TailEndCharlie/1.0 (https://github.com/osholt/tailendcharlie)',
};

String _basePath(Uri base) {
  final path = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return path == '/' ? '' : path;
}

void _requireHttps(Uri uri, String service) {
  if (uri.scheme != 'https' || uri.host.isEmpty) {
    throw FormatException('$service must use a configured HTTPS service.');
  }
}

GeoPoint? _parseCoordinates(String value) {
  final match = RegExp(
    r'^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$',
  ).firstMatch(value);
  if (match == null) return null;
  final latitude = double.tryParse(match.group(1)!);
  final longitude = double.tryParse(match.group(2)!);
  if (latitude == null ||
      longitude == null ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180) {
    throw const FormatException('Destination coordinates are invalid.');
  }
  return GeoPoint(latitude: latitude, longitude: longitude);
}

String _shortLabel(String label) => label.split(',').first.trim();

String _durationLabel(Duration duration) {
  final minutes = (duration.inSeconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
}
