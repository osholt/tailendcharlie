import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import '../../services/route_marker_plan.dart';
import '../../services/route_twistiness.dart';
import 'maneuver_list_screen.dart';
import 'resolved_route_map_preview.dart';

enum RouteReviewAction { cancel, edit, confirm }

class RouteReviewScreen extends StatefulWidget {
  const RouteReviewScreen({
    super.key,
    required this.route,
    required this.distanceUnit,
    required this.basemapConfiguration,
    this.distanceMeters,
    this.duration,
    this.twistinessScore,
    this.warnings = const [],
    this.previousRoute,
    this.canEditStops = false,
    this.onMarkerReviewChanged,
  });

  final ImportedRoute route;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;
  final double? distanceMeters;
  final Duration? duration;

  /// The provider-scored twistiness of this route, when it was planned online.
  /// Falls back to scoring the stored geometry, which is what a route loaded
  /// from a share code or a file has.
  final double? twistinessScore;
  final List<String> warnings;
  final ImportedRoute? previousRoute;
  final bool canEditStops;

  /// Reports each change to the route's marker review so the caller can store
  /// it with the route it belongs to. Assistance only suggests; this is where
  /// the person reviewing says which suggestions they will actually use (#179).
  final ValueChanged<MarkerPlanReview>? onMarkerReviewChanged;

  static Future<RouteReviewAction> show(
    BuildContext context, {
    required ImportedRoute route,
    required DistanceUnit distanceUnit,
    required BasemapConfiguration basemapConfiguration,
    double? distanceMeters,
    Duration? duration,
    double? twistinessScore,
    List<String> warnings = const [],
    ImportedRoute? previousRoute,
    bool canEditStops = false,
    ValueChanged<MarkerPlanReview>? onMarkerReviewChanged,
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
            twistinessScore: twistinessScore,
            warnings: warnings,
            previousRoute: previousRoute,
            canEditStops: canEditStops,
            onMarkerReviewChanged: onMarkerReviewChanged,
          ),
        ),
      ) ??
      RouteReviewAction.cancel;

  @override
  State<RouteReviewScreen> createState() => _RouteReviewScreenState();
}

class _RouteReviewScreenState extends State<RouteReviewScreen> {
  static const _analyzer = RouteMarkerPlanAnalyzer();

  late MarkerPlanReview _markerReview = widget.route.markerReview;

  DistanceUnit get distanceUnit => widget.distanceUnit;
  BasemapConfiguration get basemapConfiguration => widget.basemapConfiguration;
  double? get distanceMeters => widget.distanceMeters;
  Duration? get duration => widget.duration;
  double? get twistinessScore => widget.twistinessScore;
  List<String> get warnings => widget.warnings;
  ImportedRoute? get previousRoute => widget.previousRoute;
  bool get canEditStops => widget.canEditStops;

  /// The route as reviewed so far. Everything downstream - the plan, the pins,
  /// the counts - reads this, so the map and the list can never disagree about
  /// which positions are still suggested.
  ImportedRoute get route => widget.route.withMarkerReview(_markerReview);

  void _applyReview(MarkerPlanReview review) {
    setState(() => _markerReview = review);
    widget.onMarkerReviewChanged?.call(review);
  }

  void _reject(MarkerPlanPoint point) =>
      _applyReview(_markerReview.rejecting(point.toReviewPoint()));

  void _restore(String id) => _applyReview(_markerReview.restoring(id));

  Future<void> _addMissedJunction() async {
    final candidates = _analyzer.candidates(route);
    if (candidates.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'No further junctions were found on this route to add.',
          ),
        ),
      );
      return;
    }
    final chosen = await showModalBottomSheet<MarkerPlanCandidate>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          key: const Key('marker-plan-candidates'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(
              'Add a marking position',
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Junctions on this route the detector did not suggest. Adding one '
              'does not start marker mode; it only offers the position.',
              style: TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 6),
            for (final candidate in candidates)
              ListTile(
                key: Key('marker-plan-add-${candidate.id}'),
                dense: true,
                leading: const Icon(Icons.add_location_alt_outlined),
                title: Text(candidate.label),
                onTap: () => Navigator.of(sheetContext).pop(candidate),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    _applyReview(_markerReview.adding(chosen.toReviewPoint()));
  }

  @override
  Widget build(BuildContext context) {
    final route = this.route;
    final previewPaths = route.paths
        .map((path) => path.points)
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
    final routeSegments = route.paths
        .map((path) => path.points.map(_latLng).toList(growable: false))
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
    final reviewWaypoints = _reviewWaypoints(route);
    final markerPlan = _analyzer.analyze(route);
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
    final maneuverCount = const NavigationGuidancePlanner()
        .instructions(route)
        .length;

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
                            .followedBy(
                              markerPlan.points.map(
                                (point) => RoutePreviewPin(
                                  point: point.position,
                                  kind: switch (point.kind) {
                                    MarkerPlanPointKind.likelyMarker =>
                                      'marker',
                                    MarkerPlanPointKind.safetyReview =>
                                      'safety',
                                    MarkerPlanPointKind.musterPoint => 'muster',
                                  },
                                ),
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
                          if (markerPlan.points.isNotEmpty)
                            MarkerLayer(
                              key: const Key('route-review-marker-plan'),
                              markers: markerPlan.points
                                  .take(500)
                                  .map(
                                    (point) => Marker(
                                      point: _latLng(point.position),
                                      width: 38,
                                      height: 38,
                                      child: Tooltip(
                                        message: point.label,
                                        child: Icon(
                                          _markerPlanIcon(point),
                                          color: _markerPlanColor(point.kind),
                                          size: 32,
                                          shadows: const [
                                            Shadow(
                                              color: Color(0xFF10151C),
                                              blurRadius: 4,
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
                      if (maneuverCount > 0)
                        _SummaryItem(
                          icon: Icons.turn_slight_right,
                          label:
                              '$maneuverCount turn '
                              'instruction${maneuverCount == 1 ? '' : 's'}',
                        ),
                      if (route.maneuvers.isNotEmpty)
                        _SummaryItem(
                          icon: Icons.person_pin_circle_outlined,
                          label:
                              '${markerPlan.likelyMarkers.length} likely marker '
                              'position${markerPlan.likelyMarkers.length == 1 ? '' : 's'}',
                        ),
                      if (markerPlan.safetyReviews.isNotEmpty)
                        _SummaryItem(
                          icon: Icons.warning_amber_rounded,
                          label:
                              '${markerPlan.safetyReviews.length} junction '
                              'safety review${markerPlan.safetyReviews.length == 1 ? '' : 's'}',
                        ),
                      if (markerPlan.musterPoints.isNotEmpty)
                        _SummaryItem(
                          icon: Icons.groups_2_outlined,
                          label:
                              '${markerPlan.musterPoints.length} muster '
                              'point${markerPlan.musterPoints.length == 1 ? '' : 's'}',
                        ),
                      // The same score, thresholds and wording the web planner
                      // shows for the same geometry (#46, #182).
                      _SummaryItem(
                        icon: Icons.moving,
                        label: RouteTwistiness.describe(
                          twistinessScore ??
                              RouteTwistiness.score(
                                previewPaths
                                    .expand((points) => points)
                                    .toList(growable: false),
                                distanceMeters: effectiveDistance,
                              ),
                        ),
                      ),
                    ],
                  ),
                  if (route.preferences case final preferences?) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Planned with: ${preferences.summary}',
                      style: const TextStyle(color: Color(0xFF98A3B1)),
                    ),
                  ],
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
                  if (markerPlan.points.isNotEmpty ||
                      markerPlan.rejectedPoints.isNotEmpty ||
                      route.maneuvers.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Marker plan',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Advisory only. The leader must choose a visible, legal '
                      'place away from live traffic lanes. Reject any position '
                      'the group does not need; the rejection stays with this '
                      'route.',
                      style: TextStyle(color: Color(0xFF98A3B1)),
                    ),
                    const SizedBox(height: 6),
                    for (final point in markerPlan.points)
                      ListTile(
                        key: Key('marker-plan-${point.id}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          _markerPlanIcon(point),
                          color: _markerPlanColor(point.kind),
                        ),
                        title: Text(point.label),
                        subtitle: point.detail == null
                            ? null
                            : Text(point.detail!),
                        trailing: IconButton(
                          key: Key('marker-plan-reject-${point.id}'),
                          tooltip: point.source == MarkerPlanPointSource.manual
                              ? 'Remove this added position'
                              : 'Not needed — reject this suggestion',
                          onPressed: () =>
                              point.source == MarkerPlanPointSource.manual
                              ? _restore(point.id)
                              : _reject(point),
                          icon: const Icon(Icons.block_outlined),
                        ),
                      ),
                    if (markerPlan.rejectedPoints.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Rejected for this route',
                        style: TextStyle(color: Color(0xFF98A3B1)),
                      ),
                      for (final point in markerPlan.rejectedPoints)
                        ListTile(
                          key: Key('marker-plan-rejected-${point.id}'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.block_outlined,
                            color: Color(0xFF98A3B1),
                          ),
                          title: Text(
                            point.label,
                            style: const TextStyle(
                              color: Color(0xFF98A3B1),
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                          trailing: IconButton(
                            key: Key('marker-plan-restore-${point.id}'),
                            tooltip: 'Restore this suggestion',
                            onPressed: () => _restore(point.id),
                            icon: const Icon(Icons.undo),
                          ),
                        ),
                    ],
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      key: const Key('marker-plan-add'),
                      onPressed: _addMissedJunction,
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Add a missed junction'),
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
                  if (maneuverCount > 0) ...[
                    OutlinedButton.icon(
                      key: const Key('review-maneuver-list'),
                      onPressed: () => ManeuverListScreen.show(
                        context,
                        route: route,
                        distanceUnit: distanceUnit,
                      ),
                      icon: const Icon(Icons.list_alt),
                      label: Text('All turns ($maneuverCount)'),
                    ),
                    const SizedBox(height: 10),
                  ],
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

IconData _markerPlanIcon(MarkerPlanPoint point) =>
    point.source == MarkerPlanPointSource.manual
    ? Icons.add_location_alt_outlined
    : switch (point.kind) {
        MarkerPlanPointKind.likelyMarker => Icons.person_pin_circle_outlined,
        MarkerPlanPointKind.safetyReview => Icons.warning_amber_rounded,
        MarkerPlanPointKind.musterPoint => Icons.groups_2_outlined,
      };

Color _markerPlanColor(MarkerPlanPointKind kind) => switch (kind) {
  MarkerPlanPointKind.likelyMarker => const Color(0xFF6ED89A),
  MarkerPlanPointKind.safetyReview => const Color(0xFFFF8A4C),
  MarkerPlanPointKind.musterPoint => const Color(0xFF68A9FF),
};

/// How far the rider will actually travel: the length of the path that will be
/// ridden and tracked, not the sum of every path in the file.
///
/// Summing them reported a 23.4 mi MyRoute-app route as 47.4 mi, because that
/// export carries the journey twice - a dense calculated track and the sparse
/// waypoint route it came from (#180). The importer now drops a duplicate
/// representation, so in practice there is one path; this measures the primary
/// one regardless, because a file with two genuinely different paths must not
/// add them together either. A rider reads one number and rides one route.
///
/// "Primary" is the longest path, the same choice `RouteProgressTracker` makes,
/// so the distance shown and the distance progress is measured against cannot
/// disagree.
double routeLengthMeters(ImportedRoute route) {
  var longest = 0.0;
  for (final path in route.paths) {
    final length = _pathLengthMeters(path.points);
    if (length > longest) longest = length;
  }
  return longest;
}

double _pathLengthMeters(List<GeoPoint> points) {
  const distance = Distance();
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    total += distance.as(
      LengthUnit.Meter,
      _latLng(points[index - 1]),
      _latLng(points[index]),
    );
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
