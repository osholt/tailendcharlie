import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/measurement_formatter.dart';
import 'resolved_route_map_preview.dart';

enum RouteReviewAction { cancel, edit, confirm }

class RouteReviewScreen extends StatelessWidget {
  const RouteReviewScreen({
    super.key,
    required this.route,
    required this.distanceUnit,
    required this.basemapConfiguration,
    this.distanceMeters,
    this.duration,
    this.warnings = const [],
    this.previousRoute,
    this.canEditStops = false,
  });

  final ImportedRoute route;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;
  final double? distanceMeters;
  final Duration? duration;
  final List<String> warnings;
  final ImportedRoute? previousRoute;
  final bool canEditStops;

  static Future<RouteReviewAction> show(
    BuildContext context, {
    required ImportedRoute route,
    required DistanceUnit distanceUnit,
    required BasemapConfiguration basemapConfiguration,
    double? distanceMeters,
    Duration? duration,
    List<String> warnings = const [],
    ImportedRoute? previousRoute,
    bool canEditStops = false,
  }) async =>
      await Navigator.of(context).push<RouteReviewAction>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => RouteReviewScreen(
            route: route,
            distanceUnit: distanceUnit,
            basemapConfiguration: basemapConfiguration,
            distanceMeters: distanceMeters,
            duration: duration,
            warnings: warnings,
            previousRoute: previousRoute,
            canEditStops: canEditStops,
          ),
        ),
      ) ??
      RouteReviewAction.cancel;

  @override
  Widget build(BuildContext context) {
    final previewPaths = route.paths
        .map((path) => path.points)
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
    final routeSegments = route.paths
        .map((path) => path.points.map(_latLng).toList(growable: false))
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
    final reviewWaypoints = _reviewWaypoints(route);
    final allPoints = [
      ...routeSegments.expand((points) => points),
      ...reviewWaypoints.map((waypoint) => _latLng(waypoint.point)),
    ];
    final effectiveDistance = distanceMeters ?? routeLengthMeters(route);
    final materialWarning = materialRouteChangeWarning(
      previousRoute,
      route,
      distanceUnit,
    );
    final visibleWarnings = [
      ...warnings.where((warning) => warning.trim().isNotEmpty),
      ?materialWarning,
    ];
    final formatter = MeasurementFormatter(distanceUnit);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review route'),
        leading: IconButton(
          tooltip: 'Cancel route review',
          onPressed: () => Navigator.of(context).pop(RouteReviewAction.cancel),
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: ColoredBox(
                color: const Color(0xFF111720),
                child: allPoints.isEmpty
                    ? const Center(child: Text('No route geometry to review.'))
                    : basemapConfiguration.usesMapLibre
                    ? ResolvedRouteMapPreview(
                        key: const Key('route-review-map'),
                        paths: previewPaths,
                        pins: reviewWaypoints.indexed
                            .map(
                              (entry) => RoutePreviewPin(
                                point: entry.$2.point,
                                kind: entry.$1 == 0 ? 'start' : 'waypoint',
                              ),
                            )
                            .toList(growable: false),
                        basemapConfiguration: basemapConfiguration,
                      )
                    : FlutterMap(
                        key: const Key('route-review-map'),
                        options: MapOptions(
                          initialCameraFit: allPoints.length > 1
                              ? CameraFit.bounds(
                                  bounds: LatLngBounds.fromPoints(allPoints),
                                  padding: const EdgeInsets.all(40),
                                )
                              : null,
                          initialCenter: allPoints.first,
                          initialZoom: allPoints.length > 1 ? 12 : 15,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.all,
                          ),
                        ),
                        children: [
                          if (basemapConfiguration.usesLegacyRaster)
                            TileLayer(
                              urlTemplate: basemapConfiguration.urlTemplate,
                              userAgentPackageName: 'me.osholt.ride_relay',
                              maxNativeZoom:
                                  basemapConfiguration.maximumNativeZoom,
                            ),
                          if (routeSegments.any((points) => points.length >= 2))
                            PolylineLayer(
                              polylines: [
                                for (final points in routeSegments)
                                  if (points.length >= 2)
                                    Polyline(
                                      points: points,
                                      color: const Color(0xFF3478F6),
                                      strokeWidth: 6,
                                      borderColor: const Color(0xFF10151C),
                                      borderStrokeWidth: 2,
                                    ),
                              ],
                            ),
                          if (reviewWaypoints.isNotEmpty)
                            MarkerLayer(
                              markers: reviewWaypoints.indexed
                                  .map(
                                    (entry) => Marker(
                                      point: _latLng(entry.$2.point),
                                      width: 42,
                                      height: 42,
                                      child: Semantics(
                                        label: _waypointLabel(
                                          entry.$1,
                                          reviewWaypoints.length,
                                          entry.$2,
                                        ),
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            const Icon(
                                              Icons.location_on,
                                              color: Color(0xFFFFC857),
                                              size: 40,
                                            ),
                                            Positioned(
                                              top: 8,
                                              child: Text(
                                                '${entry.$1 + 1}',
                                                style: const TextStyle(
                                                  color: Color(0xFF10151C),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w900,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                        ],
                      ),
              ),
            ),
            Expanded(
              flex: 6,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                children: [
                  Text(
                    route.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      _SummaryItem(
                        icon: Icons.route,
                        label: formatter.distance(effectiveDistance),
                      ),
                      if (duration case final value?)
                        _SummaryItem(
                          icon: Icons.schedule,
                          label: _durationLabel(value),
                        ),
                      _SummaryItem(
                        icon: Icons.pin_drop_outlined,
                        label:
                            '${reviewWaypoints.length} route point${reviewWaypoints.length == 1 ? '' : 's'}',
                      ),
                      if (route.maneuvers.isNotEmpty)
                        const _SummaryItem(
                          icon: Icons.turn_slight_right,
                          label: 'Visual turn-by-turn ready',
                        ),
                    ],
                  ),
                  if (!basemapConfiguration.usesMapLibre &&
                      !basemapConfiguration.usesLegacyRaster) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'Route-only preview: geometry and pins remain available without map tiles.',
                      style: TextStyle(color: Color(0xFF98A3B1)),
                    ),
                  ],
                  if (visibleWarnings.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    for (final warning in visibleWarnings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _WarningCard(warning: warning),
                      ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Route order',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  if (reviewWaypoints.isEmpty)
                    const Text(
                      'This imported route has geometry but no named waypoints.',
                      style: TextStyle(color: Color(0xFF98A3B1)),
                    )
                  else
                    for (final entry in reviewWaypoints.indexed)
                      ListTile(
                        key: Key('route-review-waypoint-${entry.$1}'),
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(child: Text('${entry.$1 + 1}')),
                        title: Text(
                          _waypointLabel(
                            entry.$1,
                            reviewWaypoints.length,
                            entry.$2,
                          ),
                        ),
                        subtitle: entry.$2.description == null
                            ? null
                            : Text(entry.$2.description!),
                      ),
                  const SizedBox(height: 18),
                  if (canEditStops)
                    OutlinedButton.icon(
                      key: const Key('edit-reviewed-route'),
                      onPressed: () =>
                          Navigator.of(context).pop(RouteReviewAction.edit),
                      icon: const Icon(Icons.edit_location_alt_outlined),
                      label: const Text('Edit stops'),
                    ),
                  if (canEditStops) const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const Key('confirm-reviewed-route'),
                    onPressed: () =>
                        Navigator.of(context).pop(RouteReviewAction.confirm),
                    icon: const Icon(Icons.check),
                    label: const Text('Confirm route'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('cancel-reviewed-route'),
                    onPressed: () =>
                        Navigator.of(context).pop(RouteReviewAction.cancel),
                    child: const Text('Cancel — keep current route'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double routeLengthMeters(ImportedRoute route) {
  const distance = Distance();
  var total = 0.0;
  for (final path in route.paths) {
    for (var index = 1; index < path.points.length; index += 1) {
      total += distance.as(
        LengthUnit.Meter,
        _latLng(path.points[index - 1]),
        _latLng(path.points[index]),
      );
    }
  }
  return total;
}

String? materialRouteChangeWarning(
  ImportedRoute? previous,
  ImportedRoute candidate,
  DistanceUnit distanceUnit,
) {
  if (previous == null) return null;
  final previousDistance = routeLengthMeters(previous);
  final candidateDistance = routeLengthMeters(candidate);
  if (previousDistance < 1000 || candidateDistance < 1000) return null;
  final change =
      (candidateDistance - previousDistance).abs() / previousDistance;
  if (change < 0.2) return null;
  final formatter = MeasurementFormatter(distanceUnit);
  return 'This route is ${(change * 100).round()}% '
      '${candidateDistance > previousDistance ? 'longer' : 'shorter'} than the current route '
      '(${formatter.distance(previousDistance)} → ${formatter.distance(candidateDistance)}).';
}

LatLng _latLng(GeoPoint point) => LatLng(point.latitude, point.longitude);

List<RouteWaypoint> _reviewWaypoints(ImportedRoute route) {
  if (route.waypoints.isNotEmpty) return route.waypoints;
  final geometry = route.paths
      .expand((path) => path.points)
      .toList(growable: false);
  if (geometry.isEmpty) return const [];
  final first = geometry.first;
  final last = geometry.last;
  if (first.latitude == last.latitude && first.longitude == last.longitude) {
    return [
      RouteWaypoint(
        point: first,
        description: 'Derived from imported route geometry.',
      ),
    ];
  }
  return [
    RouteWaypoint(
      point: first,
      description: 'Derived from imported route geometry.',
    ),
    RouteWaypoint(
      point: last,
      description: 'Derived from imported route geometry.',
    ),
  ];
}

String _durationLabel(Duration duration) {
  final minutes = (duration.inSeconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
}

String _waypointRole(int index, int count) {
  if (index == 0) return 'Start';
  if (index == count - 1) return 'Destination';
  return 'Stop $index';
}

String _waypointLabel(int index, int count, RouteWaypoint waypoint) {
  final role = _waypointRole(index, count);
  final name = waypoint.name?.trim();
  return name == null || name.isEmpty ? role : '$role: $name';
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) =>
      Chip(avatar: Icon(icon, size: 18), label: Text(label));
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.warning});

  final String warning;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF2A2115),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF7A5A2B)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.warning_amber, color: Color(0xFFFFC857)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            warning,
            style: const TextStyle(color: Color(0xFFFFD89A)),
          ),
        ),
      ],
    ),
  );
}
