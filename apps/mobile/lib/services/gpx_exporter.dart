import 'package:xml/xml.dart';

import '../domain/imported_route.dart';

class GpxExporter {
  const GpxExporter();

  String export(ImportedRoute route) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'gpx',
      attributes: {
        'version': '1.1',
        'creator': 'Tail End Charlie',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
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

  static void _writePointDetails(XmlBuilder builder, GeoPoint point) {
    if (point.elevationMeters case final elevation?) {
      builder.element('ele', nest: elevation.toStringAsFixed(3));
    }
    if (point.recordedAt case final recordedAt?) {
      builder.element('time', nest: recordedAt.toUtc().toIso8601String());
    }
  }
}
