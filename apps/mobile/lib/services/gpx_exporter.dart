import 'package:xml/xml.dart';

import '../domain/imported_route.dart';

/// The Tail End Charlie GPX extension namespace.
const gpxTecNamespace = 'https://tailendcharlie.app/gpx/1';

/// The element that marks a `<wpt>` as a rider's alert rather than a place on a
/// route (#849).
///
/// [GpxParser] drops any waypoint carrying it. Every other `<wpt>` in a GPX file
/// is read back as a route waypoint - a named stop - so a ride's alerts, exported
/// as waypoints for a map or footage tool, would otherwise become stops the next
/// time that file was imported as a route.
const gpxAlertMarkerElement = 'alert';

/// A rider's alert, to be written into a ride's GPX as a waypoint (#849).
///
/// Separate from [RouteWaypoint] on purpose. A [RouteWaypoint] is a stop on a
/// route, and the app reuses a ride's recorded track as a route to ride again;
/// alerts stored among its waypoints would have been ridden to as stops. They are
/// handed to the exporter at the moment of export and kept out of the route.
class GpxAlertWaypoint {
  const GpxAlertWaypoint({
    required this.point,
    required this.name,
    required this.description,
  });

  /// Where the rider was, and - in [GeoPoint.recordedAt] - when. GPX `<time>` is
  /// UTC, as the standard requires.
  final GeoPoint point;
  final String name;
  final String description;
}

class GpxExporter {
  const GpxExporter();

  String export(
    ImportedRoute route, {
    List<GpxAlertWaypoint> alerts = const [],
  }) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'gpx',
      attributes: {
        'version': '1.1',
        'creator': 'Tail End Charlie',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
        if (route.preferences != null ||
            route.markerReview.isNotEmpty ||
            alerts.isNotEmpty)
          'xmlns:tec': gpxTecNamespace,
      },
      nest: () {
        builder.element(
          'metadata',
          nest: () {
            builder.element('name', nest: route.name);
            if (route.description case final description?) {
              builder.element('desc', nest: description);
            }
            builder.element(
              'time',
              nest: route.importedAt.toUtc().toIso8601String(),
            );
            // Preferences belong to the route, so they travel with the file a
            // rider shares rather than staying on the device that planned it.
            // Any other GPX reader ignores an unknown extension element.
            if (route.preferences != null || route.markerReview.isNotEmpty) {
              builder.element(
                'extensions',
                nest: () {
                  if (route.preferences case final preferences?) {
                    builder.element(
                      'tec:route-preferences',
                      attributes: {
                        'style': preferences.style.apiValue,
                        'avoid-motorways': '${preferences.avoidMotorways}',
                        'avoid-major-roads': '${preferences.avoidMajorRoads}',
                        'avoid-tolls': '${preferences.avoidTolls}',
                        'avoid-ferries': '${preferences.avoidFerries}',
                        'byway-surface': preferences.bywaySurface.apiValue,
                      },
                    );
                  }
                  if (route.markerReview.isNotEmpty) {
                    builder.element(
                      'tec:marker-review',
                      nest: () {
                        _writeReviewPoints(
                          builder,
                          'tec:rejected',
                          route.markerReview.rejected,
                        );
                        _writeReviewPoints(
                          builder,
                          'tec:added',
                          route.markerReview.added,
                        );
                      },
                    );
                  }
                },
              );
            }
          },
        );
        for (final waypoint in route.waypoints) {
          builder.element(
            'wpt',
            attributes: _coordinates(waypoint.point),
            nest: () {
              _writePointDetails(builder, waypoint.point);
              if (waypoint.name case final name?) {
                builder.element('name', nest: name);
              }
              if (waypoint.description case final description?) {
                builder.element('desc', nest: description);
              }
              if (waypoint.symbol case final symbol?) {
                builder.element('sym', nest: symbol);
              }
            },
          );
        }
        for (final alert in alerts) {
          builder.element(
            'wpt',
            attributes: _coordinates(alert.point),
            nest: () {
              _writePointDetails(builder, alert.point);
              builder.element('name', nest: alert.name);
              builder.element('desc', nest: alert.description);
              // A symbol most GPS tools draw as a warning. It is free text in
              // the standard, so a tool that has no such symbol shows its default.
              builder.element('sym', nest: 'Danger Area');
              builder.element(
                'extensions',
                nest: () => builder.element('tec:$gpxAlertMarkerElement'),
              );
            },
          );
        }
        for (final path in route.paths) {
          switch (path.kind) {
            case RoutePathKind.track:
              builder.element(
                'trk',
                nest: () {
                  if (path.name case final name?) {
                    builder.element('name', nest: name);
                  }
                  builder.element(
                    'trkseg',
                    nest: () {
                      for (final point in path.points) {
                        builder.element(
                          'trkpt',
                          attributes: _coordinates(point),
                          nest: () => _writePointDetails(builder, point),
                        );
                      }
                    },
                  );
                },
              );
            case RoutePathKind.route:
              builder.element(
                'rte',
                nest: () {
                  if (path.name case final name?) {
                    builder.element('name', nest: name);
                  }
                  for (final point in path.points) {
                    builder.element(
                      'rtept',
                      attributes: _coordinates(point),
                      nest: () => _writePointDetails(builder, point),
                    );
                  }
                },
              );
          }
        }
      },
    );
    return '${builder.buildDocument().toXmlString(pretty: true)}\n';
  }

  String fileName(ImportedRoute route) {
    final slug = route.name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '${slug.isEmpty ? 'ride-relay-route' : slug}.gpx';
  }

  static Map<String, String> _coordinates(GeoPoint point) => {
    'lat': point.latitude.toStringAsFixed(7),
    'lon': point.longitude.toStringAsFixed(7),
  };

  static void _writeReviewPoints(
    XmlBuilder builder,
    String element,
    List<MarkerReviewPoint> points,
  ) {
    for (final point in points) {
      builder.element(
        element,
        attributes: {
          'id': point.id,
          ..._coordinates(point.position),
          'label': ?point.label,
        },
      );
    }
  }

  static void _writePointDetails(XmlBuilder builder, GeoPoint point) {
    if (point.elevationMeters case final elevation?) {
      builder.element('ele', nest: elevation.toStringAsFixed(3));
    }
    if (point.recordedAt case final recordedAt?) {
      builder.element('time', nest: recordedAt.toUtc().toIso8601String());
    }
  }
}
