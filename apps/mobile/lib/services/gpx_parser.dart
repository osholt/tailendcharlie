import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../domain/imported_route.dart';

class GpxParser {
  const GpxParser({
    this.maximumBytes = 10 * 1024 * 1024,
    this.maximumPoints = 200000,
  });

  final int maximumBytes;
  final int maximumPoints;

  ImportedRoute parse(
    Uint8List bytes, {
    required String routeId,
    required String sourceFileName,
    required DateTime importedAt,
  }) {
    if (bytes.isEmpty) {
      throw const GpxFormatException('The GPX file is empty.');
    }
    if (bytes.length > maximumBytes) {
      throw GpxFormatException(
        'The GPX file exceeds the ${maximumBytes ~/ (1024 * 1024)} MB import limit.',
      );
    }

    final String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      throw const GpxFormatException('The GPX file must use UTF-8 encoding.');
    }
    if (source.toUpperCase().contains('<!DOCTYPE')) {
      throw const GpxFormatException(
        'GPX files containing a document type declaration are not accepted.',
      );
    }

    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlParserException catch (error) {
      throw GpxFormatException('Invalid GPX XML: ${error.message}');
    }
    final root = document.rootElement;
    if (root.name.local.toLowerCase() != 'gpx') {
      throw const GpxFormatException('The document root must be <gpx>.');
    }

    var pointCount = 0;
    GeoPoint parsePoint(XmlElement element) {
      pointCount += 1;
      if (pointCount > maximumPoints) {
        throw GpxFormatException(
          'The GPX file exceeds the $maximumPoints point import limit.',
        );
      }
      final latitude = _coordinate(element, 'lat', -90, 90);
      final longitude = _coordinate(element, 'lon', -180, 180);
      final elevation = _optionalDouble(_childText(element, 'ele'));
      final timeText = _childText(element, 'time');
      DateTime? recordedAt;
      if (timeText != null) {
        recordedAt = DateTime.tryParse(timeText)?.toUtc();
      }
      return GeoPoint(
        latitude: latitude,
        longitude: longitude,
        elevationMeters: elevation,
        recordedAt: recordedAt,
      );
    }

    final paths = <RoutePath>[];
    for (final track in _children(root, 'trk')) {
      final trackName = _childText(track, 'name');
      final isCalculatedRoadRoute = _children(track, 'extensions')
          .expand((extensions) => extensions.childElements)
          .any(
            (element) =>
                element.name.local.toLowerCase() == 'road-route' &&
                element.innerText.trim().toLowerCase() == 'true',
          );
      final segments = _children(track, 'trkseg').toList(growable: false);
      for (var index = 0; index < segments.length; index += 1) {
        final points = _children(
          segments[index],
          'trkpt',
        ).map(parsePoint).toList(growable: false);
        if (points.isEmpty) continue;
        final segmentName = segments.length > 1 && trackName != null
            ? '$trackName · segment ${index + 1}'
            : trackName;
        paths.add(
          RoutePath(
            kind: isCalculatedRoadRoute
                ? RoutePathKind.route
                : RoutePathKind.track,
            name: segmentName,
            points: points,
          ),
        );
      }
    }
    for (final route in _children(root, 'rte')) {
      final points = _children(
        route,
        'rtept',
      ).map(parsePoint).toList(growable: false);
      if (points.isEmpty) continue;
      paths.add(
        RoutePath(
          kind: RoutePathKind.route,
          name: _childText(route, 'name'),
          points: points,
        ),
      );
    }

    final waypoints = _children(root, 'wpt')
        .map(
          (waypoint) => RouteWaypoint(
            point: parsePoint(waypoint),
            name: _childText(waypoint, 'name'),
            description:
                _childText(waypoint, 'desc') ?? _childText(waypoint, 'cmt'),
            symbol: _childText(waypoint, 'sym'),
          ),
        )
        .toList(growable: false);

    if (paths.isEmpty && waypoints.isEmpty) {
      throw const GpxFormatException(
        'The GPX file contains no tracks, routes, or waypoints.',
      );
    }
    final metadata = _children(root, 'metadata').firstOrNull;
    final metadataName = metadata == null ? null : _childText(metadata, 'name');
    final firstPathName = paths.map((path) => path.name).nonNulls.firstOrNull;

    return ImportedRoute(
      id: routeId,
      name:
          metadataName ??
          firstPathName ??
          _nameWithoutExtension(sourceFileName),
      description: metadata == null ? null : _childText(metadata, 'desc'),
      importedAt: importedAt.toUtc(),
      sourceFileName: sourceFileName,
      paths: paths,
      waypoints: waypoints,
    );
  }
}

class GpxFormatException implements FormatException {
  const GpxFormatException(this.message);

  @override
  final String message;

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() => 'GpxFormatException: $message';
}

Iterable<XmlElement> _children(XmlElement parent, String localName) => parent
    .childElements
    .where((element) => element.name.local.toLowerCase() == localName);

String? _childText(XmlElement parent, String localName) {
  final element = _children(parent, localName).firstOrNull;
  final value = element?.innerText.trim();
  return value == null || value.isEmpty ? null : value;
}

double _coordinate(
  XmlElement element,
  String attributeName,
  double minimum,
  double maximum,
) {
  final raw = element.getAttribute(attributeName);
  final value = double.tryParse(raw ?? '');
  if (value == null || !value.isFinite || value < minimum || value > maximum) {
    throw GpxFormatException(
      '<${element.name.local}> has an invalid $attributeName coordinate.',
    );
  }
  return value;
}

double? _optionalDouble(String? raw) {
  if (raw == null) return null;
  final value = double.tryParse(raw);
  return value != null && value.isFinite ? value : null;
}

String _nameWithoutExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final name = dot > 0 ? fileName.substring(0, dot) : fileName;
  return name.trim().isEmpty ? 'Imported route' : name.trim();
}
