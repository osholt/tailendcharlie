import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/imported_route.dart';
import 'gpx_exporter.dart';

enum NavigationTarget {
  shareGpx,
  googleMaps,
  waze,
  calimoto,
  myRouteApp,
  garmin,
  bmwMotorrad,
}

extension NavigationTargetDetails on NavigationTarget {
  String get label => switch (this) {
    NavigationTarget.shareGpx => 'Share GPX file',
    NavigationTarget.googleMaps => 'Google Maps',
    NavigationTarget.waze => 'Waze',
    NavigationTarget.calimoto => 'Calimoto',
    NavigationTarget.myRouteApp => 'MyRoute-app',
    NavigationTarget.garmin => 'Garmin',
    NavigationTarget.bmwMotorrad => 'BMW Motorrad',
  };

  String get limitation => switch (this) {
    NavigationTarget.shareGpx =>
      'Choose any GPX-compatible app or save to Files',
    NavigationTarget.googleMaps =>
      'Route preview with up to 3 via points; Google recalculates it',
    NavigationTarget.waze =>
      'Opens motorcycle navigation to the final destination only',
    NavigationTarget.calimoto =>
      'Uses the GPX share sheet; choose Calimoto if installed',
    NavigationTarget.myRouteApp =>
      'Uses the GPX share sheet; choose MyRoute-app if installed',
    NavigationTarget.garmin =>
      'Uses the GPX share sheet for Garmin Drive, Tread or Explore',
    NavigationTarget.bmwMotorrad =>
      'Uses the GPX share sheet for the BMW Motorrad Connected app',
  };

  bool get hasDocumentedDirectLink =>
      this == NavigationTarget.googleMaps || this == NavigationTarget.waze;
}

class NavigationExportResult {
  const NavigationExportResult({
    required this.message,
    required this.openedDirectly,
    required this.sharedGpx,
  });

  final String message;
  final bool openedDirectly;
  final bool sharedGpx;
}

abstract interface class ExternalUriLauncher {
  Future<bool> open(Uri uri);
}

class SystemExternalUriLauncher implements ExternalUriLauncher {
  const SystemExternalUriLauncher();

  @override
  Future<bool> open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}

abstract interface class GpxShareGateway {
  Future<void> share({
    required ImportedRoute route,
    required NavigationTarget target,
    Rect? sharePositionOrigin,
  });
}

class SystemGpxShareGateway implements GpxShareGateway {
  const SystemGpxShareGateway({this.exporter = const GpxExporter()});

  final GpxExporter exporter;

  @override
  Future<void> share({
    required ImportedRoute route,
    required NavigationTarget target,
    Rect? sharePositionOrigin,
  }) async {
    final fileName = exporter.fileName(route);
    final bytes = Uint8List.fromList(utf8.encode(exporter.export(route)));
    await SharePlus.instance.share(
      ShareParams(
        title: 'Export ${route.name}',
        subject: 'Tail End Charlie route: ${route.name}',
        text: _shareInstruction(target),
        files: [
          XFile.fromData(
            bytes,
            mimeType: 'application/gpx+xml',
            name: fileName,
          ),
        ],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  static String _shareInstruction(NavigationTarget target) => switch (target) {
    NavigationTarget.shareGpx =>
      'GPX 1.1 route exported from Tail End Charlie.',
    _ =>
      'Choose ${target.label} in the share sheet if it is installed. '
          'Tail End Charlie cannot preselect another app.',
  };
}

class NavigationExportCoordinator {
  const NavigationExportCoordinator({
    this.launcher = const SystemExternalUriLauncher(),
    this.shareGateway = const SystemGpxShareGateway(),
  });

  final ExternalUriLauncher launcher;
  final GpxShareGateway shareGateway;

  Future<NavigationExportResult> export(
    NavigationTarget target,
    ImportedRoute route, {
    Rect? sharePositionOrigin,
  }) async {
    final directUri = switch (target) {
      NavigationTarget.googleMaps => RouteNavigationLinks.googleMaps(route),
      NavigationTarget.waze => RouteNavigationLinks.waze(route),
      _ => null,
    };
    if (directUri != null) {
      try {
        if (await launcher.open(directUri)) {
          return NavigationExportResult(
            message: target == NavigationTarget.googleMaps
                ? 'Opened a Google Maps preview. Check its recalculated route before riding.'
                : 'Opened Waze for the final destination; the GPX route was not transferred.',
            openedDirectly: true,
            sharedGpx: false,
          );
        }
      } on Object {
        // The documented universal link could not be handed to the OS. Preserve
        // the route by falling back to the ordinary GPX share sheet.
      }
    }

    await shareGateway.share(
      route: route,
      target: target,
      sharePositionOrigin: sharePositionOrigin,
    );
    return NavigationExportResult(
      message: directUri == null
          ? '${target.label} uses the GPX share sheet; choose it if installed.'
          : '${target.label} could not be opened, so the GPX share sheet was shown instead.',
      openedDirectly: false,
      sharedGpx: true,
    );
  }
}

class RouteNavigationLinks {
  const RouteNavigationLinks._();

  static Uri? googleMaps(ImportedRoute route) {
    final points = _navigationPoints(route);
    if (points.isEmpty) return null;
    final origin = points.first;
    final destination = points.last;
    final waypoints = _sampleIntermediatePoints(points, 3);
    return Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'origin': _coordinate(origin),
      'destination': _coordinate(destination),
      'travelmode': 'driving',
      'dir_action': 'navigate',
      if (waypoints.isNotEmpty)
        'waypoints': waypoints.map(_coordinate).join('|'),
    });
  }

  static Uri? waze(ImportedRoute route) {
    final points = _navigationPoints(route);
    if (points.isEmpty) return null;
    return Uri.https('waze.com', '/ul', {
      'll': _coordinate(points.last),
      'navigate': 'yes',
      'vehicle_type': 'motorcycle',
      'utm_source': 'ride_relay',
    });
  }

  static List<GeoPoint> _navigationPoints(ImportedRoute route) {
    final pathPoints = route.paths
        .expand((path) => path.points)
        .toList(growable: false);
    if (pathPoints.isNotEmpty) return pathPoints;
    return route.waypoints
        .map((waypoint) => waypoint.point)
        .toList(growable: false);
  }

  static List<GeoPoint> _sampleIntermediatePoints(
    List<GeoPoint> points,
    int maximum,
  ) {
    if (points.length <= 2 || maximum <= 0) return const [];
    final interiorCount = points.length - 2;
    if (interiorCount <= maximum) {
      return points.sublist(1, points.length - 1);
    }
    final selected = <GeoPoint>[];
    final indexes = <int>{};
    for (var number = 1; number <= maximum; number += 1) {
      final index = ((points.length - 1) * number / (maximum + 1)).round();
      if (index > 0 && index < points.length - 1 && indexes.add(index)) {
        selected.add(points[index]);
      }
    }
    return selected;
  }

  static String _coordinate(GeoPoint point) =>
      '${point.latitude.toStringAsFixed(6)},'
      '${point.longitude.toStringAsFixed(6)}';
}
