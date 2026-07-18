import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../domain/distance_unit.dart';
import '../domain/imported_route.dart';
import 'measurement_formatter.dart';

class RoutingConfiguration {
  const RoutingConfiguration({
    required this.routingBaseUrl,
    required this.geocodingBaseUrl,
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
  );

  final Uri routingBaseUrl;
  final Uri geocodingBaseUrl;
}

class RoadRouteResult {
  const RoadRouteResult({
    required this.points,
    required this.distanceMeters,
    required this.duration,
    this.maneuvers = const [],
  });

  final List<GeoPoint> points;
  final double distanceMeters;
  final Duration duration;
  final List<RoadRouteManeuver> maneuvers;
}

/// A decision reported by the routing engine rather than inferred from a
/// bend in recorded GPS geometry. These are the points where a second rider
/// may need to mark a junction.
class RoadRouteManeuver {
  const RoadRouteManeuver({
    required this.position,
    required this.type,
    this.modifier,
    this.name,
    this.ref,
  });

  final GeoPoint position;
  final String type;
  final String? modifier;
  final String? name;
  final String? ref;

  /// OSRM does not expose UK give-way signage, but these manoeuvres are the
  /// routing decisions where the group leaves its current road or must
  /// negotiate a junction. A traffic-sign data source can add further points.
  bool get requiresSecondBikeDrop => const {
    'turn',
    'fork',
    'end of road',
    'roundabout',
    'rotary',
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
    );
  }
}

abstract interface class RoadRoutingService {
  Future<RoadRouteResult> routeThrough(List<GeoPoint> waypoints);
}

class OsrmRoadRoutingService implements RoadRoutingService {
  const OsrmRoadRoutingService({
    required this.client,
    required this.baseUrl,
    this.timeout = const Duration(seconds: 15),
    this.maximumResponseBytes = 5 * 1024 * 1024,
  });

  final http.Client client;
  final Uri baseUrl;
  final Duration timeout;
  final int maximumResponseBytes;

  @override
  Future<RoadRouteResult> routeThrough(List<GeoPoint> waypoints) async {
    if (waypoints.length < 2) {
      throw const FormatException('At least two route points are required.');
    }
    if (waypoints.length > 100) {
      throw const FormatException(
        'A maximum of 100 route points is supported.',
      );
    }
    _requireHttps(baseUrl, 'Routing');
    final coordinates = waypoints
        .map((point) => '${point.longitude},${point.latitude}')
        .join(';');
    final path = '${_basePath(baseUrl)}/route/v1/driving/$coordinates';
    final uri = baseUrl.replace(
      path: path,
      queryParameters: const {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'true',
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
    final route = Map<String, dynamic>.from(routes.first as Map);
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
          ),
        );
      }
    }
    return List.unmodifiable(maneuvers);
  }
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

  Future<ImportedRoute> plan({
    required GeoPoint origin,
    required String query,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
  }) async {
    final matches = await searchService.search(query);
    final destination = matches.first;
    final roadRoute = await routingService.routeThrough([
      origin,
      destination.point,
    ]);
    final id = _idFactory();
    return ImportedRoute(
      id: id,
      name: 'To ${_shortLabel(destination.label)}',
      description:
          'Road route generated by Tail End Charlie. '
          '${MeasurementFormatter(distanceUnit).distance(roadRoute.distanceMeters)}, '
          '${_durationLabel(roadRoute.duration)}.',
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
        RouteWaypoint(point: origin, name: 'Start', symbol: 'Flag, Blue'),
        RouteWaypoint(
          point: destination.point,
          name: destination.label,
          symbol: 'Flag, Red',
        ),
      ],
    );
  }
}

const _requestHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'RideRelay/1.0 (https://github.com/osholt/ride-relay)',
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
