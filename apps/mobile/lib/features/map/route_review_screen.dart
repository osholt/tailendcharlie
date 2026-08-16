import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/biker_place_catalogue.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import '../../services/route_marker_plan.dart';
import '../../services/route_reshape_planner.dart';
import '../../services/route_twistiness.dart';
import '../../services/route_waypoint_editor.dart';
import 'maneuver_list_screen.dart';
import 'resolved_route_map_preview.dart';

enum RouteReviewAction { cancel, edit, another, confirm }

typedef RouteReshapeCallback =
    Future<RouteReshapeResult> Function(
      ImportedRoute route,
      List<RouteShapingPoint> shapingPoints,
    );

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
    this.comparisonRoute,
    this.canEditStops = false,
    this.canGenerateAlternative = false,
    this.showMarkerPlan = true,
    this.onMarkerReviewChanged,
    this.onReshapeRoute,
    this.onRouteChanged,
    this.pointOfInterestLoader,
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

  /// A route drawn underneath [route] for an explicit before/after review.
  /// This is separate from [previousRoute], which also drives the material
  /// length-change warning and is used by ordinary route editing flows.
  final ImportedRoute? comparisonRoute;
  final bool canEditStops;
  final bool canGenerateAlternative;
  final bool showMarkerPlan;

  /// Reports each change to the route's marker review so the caller can store
  /// it with the route it belongs to. Assistance only suggests; this is where
  /// the person reviewing says which suggestions they will actually use (#179).
  final ValueChanged<MarkerPlanReview>? onMarkerReviewChanged;
  final RouteReshapeCallback? onReshapeRoute;
  final ValueChanged<ImportedRoute>? onRouteChanged;
  final Future<BikerPlaceCatalogue> Function()? pointOfInterestLoader;

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
    ImportedRoute? comparisonRoute,
    bool canEditStops = false,
    bool canGenerateAlternative = false,
    bool showMarkerPlan = true,
    ValueChanged<MarkerPlanReview>? onMarkerReviewChanged,
    RouteReshapeCallback? onReshapeRoute,
    ValueChanged<ImportedRoute>? onRouteChanged,
    Future<BikerPlaceCatalogue> Function()? pointOfInterestLoader,
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
            comparisonRoute: comparisonRoute,
            canEditStops: canEditStops,
            canGenerateAlternative: canGenerateAlternative,
            showMarkerPlan: showMarkerPlan,
            onMarkerReviewChanged: onMarkerReviewChanged,
            onReshapeRoute: onReshapeRoute,
            onRouteChanged: onRouteChanged,
            pointOfInterestLoader: pointOfInterestLoader,
          ),
        ),
      ) ??
      RouteReviewAction.cancel;

  @override
  State<RouteReviewScreen> createState() => _RouteReviewScreenState();
}

class _RouteReviewScreenState extends State<RouteReviewScreen> {
  static const _analyzer = RouteMarkerPlanAnalyzer();
  static const _reshapePreviewDelay = Duration(milliseconds: 450);

  late MarkerPlanReview _markerReview = widget.route.markerReview;
  late ImportedRoute _route = widget.route;
  late ImportedRoute _lastSuccessfulRoute = widget.route;
  late double? _distanceMeters = widget.distanceMeters;
  late Duration? _duration = widget.duration;
  late double? _twistinessScore = widget.twistinessScore;
  final List<List<RouteShapingPoint>> _reshapeHistory = [];
  Timer? _reshapeTimer;
  int _reshapeGeneration = 0;
  String? _activeShapingPointId;
  String? _reshapeError;
  late bool _reshapeEnabled;
  bool _reshapeQueued = false;
  bool _reshaping = false;
  int _shapeSequence = 0;
  BikerPlaceCatalogue _pointOfInterests = BikerPlaceCatalogue.empty;
  List<BikerPlace> _nearbyPointsOfInterest = const [];
  bool _showPointsOfInterest = true;
  bool _loadingPointsOfInterest = false;
  String? _pointOfInterestError;

  DistanceUnit get distanceUnit => widget.distanceUnit;
  BasemapConfiguration get basemapConfiguration => widget.basemapConfiguration;
  double? get distanceMeters => _distanceMeters;
  Duration? get duration => _duration;
  double? get twistinessScore => _twistinessScore;
  List<String> get warnings => widget.warnings;
  ImportedRoute? get previousRoute => widget.previousRoute;
  ImportedRoute? get comparisonRoute => widget.comparisonRoute;
  bool get canEditStops => widget.canEditStops;

  /// The route as reviewed so far. Everything downstream - the plan, the pins,
  /// the counts - reads this, so the map and the list can never disagree about
  /// which positions are still suggested.
  ImportedRoute get route => _route.withMarkerReview(_markerReview);

  @override
  void initState() {
    super.initState();
    // A destination plan opens ready to manipulate, matching the web planner.
    // Imported/recorded routes retain the quieter review-only default.
    _reshapeEnabled = canEditStops && widget.onReshapeRoute != null;
    if (canEditStops && widget.onReshapeRoute != null) {
      unawaited(_loadPointsOfInterest());
    }
  }

  Future<void> _loadPointsOfInterest() async {
    setState(() {
      _loadingPointsOfInterest = true;
      _pointOfInterestError = null;
    });
    try {
      final catalogue =
          await (widget.pointOfInterestLoader?.call() ??
              BikerPlaceCatalogue.loadAsset());
      if (!mounted) return;
      setState(() {
        _pointOfInterests = catalogue;
        _nearbyPointsOfInterest = catalogue.nearRoute(route.allPoints);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _pointOfInterestError =
            'Points of interest could not be loaded. Route drawing still works. $error';
      });
    } finally {
      if (mounted) setState(() => _loadingPointsOfInterest = false);
    }
  }

  void _applyReview(MarkerPlanReview review) {
    setState(() => _markerReview = review);
    widget.onMarkerReviewChanged?.call(review);
  }

  @override
  void dispose() {
    _reshapeTimer?.cancel();
    _reshapeGeneration += 1;
    super.dispose();
  }

  void _beginRouteReshape(RoutePreviewReshapeStart start) {
    if (widget.onReshapeRoute == null) return;
    final current = route.shapingPoints;
    _reshapeHistory.add(List.unmodifiable(current));
    if (_reshapeHistory.length > 20) _reshapeHistory.removeAt(0);
    final existingIndex = start.shapingPointIndex;
    final updated =
        existingIndex != null &&
            existingIndex >= 0 &&
            existingIndex < current.length
        ? current
        : insertRouteShapingPoint(
            route,
            current,
            start.point,
            id: 'shape-${DateTime.now().microsecondsSinceEpoch}-${_shapeSequence++}',
          );
    final activeIndex =
        existingIndex ??
        updated.indexWhere(
          (point) => !current.any((existing) => existing.id == point.id),
        );
    if (activeIndex < 0 || activeIndex >= updated.length) return;
    setState(() {
      _activeShapingPointId = updated[activeIndex].id;
      _route = _route.withShapingPoints(updated);
      _reshapeError = null;
    });
  }

  void _updateRouteReshape(GeoPoint point) {
    final activeId = _activeShapingPointId;
    if (activeId == null) return;
    final updated = [
      for (final shapingPoint in route.shapingPoints)
        shapingPoint.id == activeId
            ? shapingPoint.movedTo(point)
            : shapingPoint,
    ];
    setState(() => _route = _route.withShapingPoints(updated));
    _queueReshape();
  }

  void _endRouteReshape() {
    if (_activeShapingPointId == null) return;
    _activeShapingPointId = null;
    _queueReshape(immediate: true);
  }

  void _removeShapingPoint(String id) {
    _reshapeHistory.add(List.unmodifiable(route.shapingPoints));
    final updated = route.shapingPoints
        .where((point) => point.id != id)
        .toList(growable: false);
    setState(() {
      _route = _route.withShapingPoints(updated);
      _reshapeError = null;
    });
    _queueReshape(immediate: true);
  }

  void _undoReshape() {
    if (_reshapeHistory.isEmpty) return;
    final previous = _reshapeHistory.removeLast();
    setState(() {
      _route = _route.withShapingPoints(previous);
      _reshapeError = null;
    });
    _queueReshape(immediate: true);
  }

  void _queueReshape({bool immediate = false}) {
    final callback = widget.onReshapeRoute;
    if (callback == null) return;
    _reshapeTimer?.cancel();
    final generation = ++_reshapeGeneration;
    setState(() => _reshapeQueued = true);
    _reshapeTimer = Timer(
      immediate ? Duration.zero : _reshapePreviewDelay,
      () async {
        _reshapeTimer = null;
        if (!mounted || generation != _reshapeGeneration) return;
        setState(() {
          _reshapeQueued = false;
          _reshaping = true;
          _reshapeError = null;
        });
        try {
          final result = await callback(route, route.shapingPoints);
          if (!mounted || generation != _reshapeGeneration) return;
          setState(() {
            _route = result.route.withMarkerReview(_markerReview);
            _lastSuccessfulRoute = _route;
            _nearbyPointsOfInterest = _pointOfInterests.nearRoute(
              _route.allPoints,
            );
            _distanceMeters = result.distanceMeters;
            _duration = result.duration;
            _twistinessScore = result.twistinessScore;
          });
          widget.onRouteChanged?.call(_route);
        } on Object catch (error) {
          if (!mounted || generation != _reshapeGeneration) return;
          setState(() {
            _route = _lastSuccessfulRoute;
            _reshapeError =
                'The route could not be reshaped. The last road route is still '
                'shown and unchanged. $error';
          });
        } finally {
          if (mounted && generation == _reshapeGeneration) {
            setState(() => _reshaping = false);
          }
        }
      },
    );
  }

  Future<void> _showPointOfInterest(BikerPlace place) async {
    if (_reshaping || _reshapeQueued || widget.onReshapeRoute == null) return;
    final alreadyAdded = route.waypoints.any(
      (waypoint) => _sameMapPoint(waypoint.point, place.point),
    );
    final add = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3, right: 12),
                    child: Icon(Icons.local_cafe, color: Color(0xFFF97316)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                        if (place.address.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(place.address),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          place.source,
                          style: const TextStyle(
                            color: Color(0xFF98A3B1),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: Key('add-point-of-interest-${place.id}'),
                onPressed: alreadyAdded
                    ? null
                    : () => Navigator.of(sheetContext).pop(true),
                icon: Icon(
                  alreadyAdded ? Icons.check : Icons.add_location_alt_outlined,
                ),
                label: Text(
                  alreadyAdded ? 'Already on this route' : 'Add as waypoint',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (add != true || !mounted) return;
    final candidate = insertRouteWaypoint(
      route,
      RouteWaypoint(
        point: place.point,
        name: place.name,
        description: [
          if (place.address.isNotEmpty) place.address,
          place.source,
        ].join(' · '),
        symbol: 'Restaurant',
      ),
    );
    await _recalculateEditedRoute(
      candidate,
      failurePrefix: 'Could not route via ${place.name}.',
    );
  }

  Future<void> _removeWaypoint(int index) async {
    if (_reshaping || _reshapeQueued || widget.onReshapeRoute == null) return;
    final waypoint = route.waypoints[index];
    final candidate = removeRouteWaypoint(route, index);
    await _recalculateEditedRoute(
      candidate,
      failurePrefix: 'Could not remove ${waypoint.name ?? 'that waypoint'}.',
    );
  }

  Future<void> _recalculateEditedRoute(
    ImportedRoute candidate, {
    required String failurePrefix,
  }) async {
    final callback = widget.onReshapeRoute;
    if (callback == null) return;
    _reshapeTimer?.cancel();
    _reshapeGeneration += 1;
    final previous = route;
    setState(() {
      _activeShapingPointId = null;
      _route = candidate;
      _reshaping = true;
      _reshapeQueued = false;
      _reshapeError = null;
    });
    try {
      final result = await callback(candidate, candidate.shapingPoints);
      if (!mounted) return;
      setState(() {
        _route = result.route.withMarkerReview(_markerReview);
        _lastSuccessfulRoute = _route;
        _nearbyPointsOfInterest = _pointOfInterests.nearRoute(_route.allPoints);
        _distanceMeters = result.distanceMeters;
        _duration = result.duration;
        _twistinessScore = result.twistinessScore;
      });
      widget.onRouteChanged?.call(_route);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _route = previous;
        _reshapeError =
            '$failurePrefix The previous route is unchanged. $error';
      });
    } finally {
      if (mounted) setState(() => _reshaping = false);
    }
  }

  BikerPlace? _pointOfInterestForPin(RoutePreviewPin pin) {
    final id = pin.id;
    if (id == null) return null;
    return _pointOfInterests.places
        .where((place) => 'poi-${place.id}' == id)
        .firstOrNull;
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
    final comparisonPreviewPaths = comparisonRoute?.paths
        .map((path) => path.points)
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
    final comparisonSegments = comparisonRoute?.paths
        .map((path) => path.points.map(_latLng).toList(growable: false))
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
    final reviewWaypoints = _reviewWaypoints(route);
    final markerPlan = widget.showMarkerPlan
        ? _analyzer.analyze(route)
        : const RouteMarkerPlan(points: []);
    final visiblePointsOfInterest = canEditStops && _showPointsOfInterest
        ? _nearbyPointsOfInterest
        : const <BikerPlace>[];
    final pointOfInterestPins = visiblePointsOfInterest
        .map(
          (place) => RoutePreviewPin(
            id: 'poi-${place.id}',
            label: place.name,
            point: place.point,
            kind: 'poi',
            interactive: true,
            includeInFraming: false,
          ),
        )
        .toList(growable: false);
    final allPoints = [
      ...?comparisonSegments?.expand((points) => points),
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
        actions: [
          if (widget.canGenerateAlternative)
            TextButton.icon(
              key: const Key('generate-another-route'),
              onPressed: _reshapeQueued || _reshaping
                  ? null
                  : () => Navigator.of(context).pop(RouteReviewAction.another),
              icon: const Icon(Icons.refresh),
              label: const Text('Another'),
            ),
          if (canEditStops)
            IconButton(
              key: const Key('edit-reviewed-route'),
              tooltip: 'Edit stops',
              onPressed: () =>
                  Navigator.of(context).pop(RouteReviewAction.edit),
              icon: const Icon(Icons.edit_location_alt_outlined),
            ),
          TextButton.icon(
            key: const Key('confirm-reviewed-route'),
            onPressed: _reshapeQueued || _reshaping
                ? null
                : () => Navigator.of(context).pop(RouteReviewAction.confirm),
            icon: const Icon(Icons.check),
            label: const Text('Confirm'),
          ),
          const SizedBox(width: 8),
        ],
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
                        referencePaths: comparisonPreviewPaths ?? const [],
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
                            .followedBy(
                              route.shapingPoints.map(
                                (point) => RoutePreviewPin(
                                  point: point.point,
                                  kind: 'shape',
                                ),
                              ),
                            )
                            .followedBy(pointOfInterestPins)
                            .toList(growable: false),
                        basemapConfiguration: basemapConfiguration,
                        reshapeEnabled: _reshapeEnabled,
                        onPinTap: (pin) {
                          final place = _pointOfInterestForPin(pin);
                          if (place != null) {
                            unawaited(_showPointOfInterest(place));
                          }
                        },
                        onReshapeStart: _beginRouteReshape,
                        onReshapeUpdate: _updateRouteReshape,
                        onReshapeEnd: _endRouteReshape,
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
                          if (comparisonSegments?.any(
                                (points) => points.length >= 2,
                              ) ??
                              false)
                            PolylineLayer(
                              key: const Key('route-review-original-line'),
                              polylines: [
                                for (final points in comparisonSegments!)
                                  if (points.length >= 2)
                                    Polyline(
                                      points: points,
                                      color: const Color(0xFFB8C0CC),
                                      strokeWidth: 5,
                                      pattern: StrokePattern.dashed(
                                        segments: const [10, 8],
                                      ),
                                    ),
                              ],
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
                          if (visiblePointsOfInterest.isNotEmpty)
                            MarkerLayer(
                              key: const Key('route-review-points-of-interest'),
                              markers: visiblePointsOfInterest
                                  .map(
                                    (place) => Marker(
                                      point: _latLng(place.point),
                                      width: 40,
                                      height: 40,
                                      child: Semantics(
                                        button: true,
                                        label:
                                            'Add ${place.name} as a waypoint',
                                        child: GestureDetector(
                                          key: Key(
                                            'route-point-of-interest-${place.id}',
                                          ),
                                          onTap: () => unawaited(
                                            _showPointOfInterest(place),
                                          ),
                                          child: Tooltip(
                                            message: place.name,
                                            child: const Icon(
                                              Icons.local_cafe,
                                              color: Color(0xFFF97316),
                                              size: 30,
                                              shadows: [
                                                Shadow(
                                                  color: Color(0xFF10151C),
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                          ),
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
                  if (_reshapeError case final error?) ...[
                    const SizedBox(height: 8),
                    _WarningCard(warning: error),
                  ],
                  if (_pointOfInterestError case final error?) ...[
                    const SizedBox(height: 8),
                    _WarningCard(warning: error),
                  ],
                  if (_reshaping || _reshapeQueued) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(
                      key: Key('route-reshape-progress'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Recalculating the road route…',
                      style: TextStyle(color: Color(0xFF98A3B1)),
                    ),
                  ],
                  if (widget.onReshapeRoute != null) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          key: const Key('toggle-route-reshape'),
                          selected: _reshapeEnabled,
                          avatar: const Icon(Icons.gesture, size: 18),
                          label: Text(
                            _reshapeEnabled
                                ? 'Finish drawing'
                                : 'Draw route around',
                          ),
                          onSelected: (selected) =>
                              setState(() => _reshapeEnabled = selected),
                        ),
                        if (_reshapeHistory.isNotEmpty)
                          ActionChip(
                            key: const Key('undo-route-reshape'),
                            avatar: const Icon(Icons.undo, size: 18),
                            label: const Text('Undo adjustment'),
                            onPressed: _undoReshape,
                          ),
                        if (canEditStops)
                          FilterChip(
                            key: const Key('toggle-route-points-of-interest'),
                            selected: _showPointsOfInterest,
                            avatar: _loadingPointsOfInterest
                                ? const Icon(Icons.hourglass_top, size: 18)
                                : const Icon(Icons.local_cafe, size: 18),
                            label: Text(
                              _pointOfInterests.places.isEmpty
                                  ? 'Points of interest'
                                  : 'Nearby places (${visiblePointsOfInterest.length})',
                            ),
                            onSelected: (selected) => setState(
                              () => _showPointsOfInterest = selected,
                            ),
                          ),
                      ],
                    ),
                    if (canEditStops &&
                        _showPointsOfInterest &&
                        _pointOfInterests.places.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Drag the blue route to shape it. Tap an orange café or '
                        'biker place to add it as an ordered waypoint; the live '
                        'preview recalculates before you confirm.',
                        style: TextStyle(
                          color: Color(0xFF98A3B1),
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (route.shapingPoints.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in route.shapingPoints.indexed)
                            InputChip(
                              key: Key('route-shaping-point-${entry.$2.id}'),
                              avatar: const Icon(
                                Icons.adjust,
                                size: 16,
                                color: Color(0xFFB37CFF),
                              ),
                              label: Text('Adjustment ${entry.$1 + 1}'),
                              tooltip:
                                  'Route shaping point. This is not a stop.',
                              onDeleted: () => _removeShapingPoint(entry.$2.id),
                            ),
                        ],
                      ),
                    ],
                  ],
                  if (widget.showMarkerPlan &&
                      (markerPlan.points.isNotEmpty ||
                          markerPlan.rejectedPoints.isNotEmpty ||
                          route.maneuvers.isNotEmpty)) ...[
                    const SizedBox(height: 8),
                    ExpansionTile(
                      key: const Key('marker-plan-review-section'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      initiallyExpanded:
                          markerPlan.points.length +
                              markerPlan.rejectedPoints.length <=
                          8,
                      title: Text(
                        'Marker plan (${markerPlan.points.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      subtitle: const Text(
                        'Tap to review, reject or add marking positions.',
                      ),
                      children: [
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Advisory only. The leader must choose a visible, '
                            'legal place away from live traffic lanes. Reject '
                            'any position the group does not need; the rejection '
                            'stays with this route.',
                            style: TextStyle(color: Color(0xFF98A3B1)),
                          ),
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
                              tooltip:
                                  point.source == MarkerPlanPointSource.manual
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
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Rejected for this route',
                              style: TextStyle(color: Color(0xFF98A3B1)),
                            ),
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
                    ),
                  ],
                  const SizedBox(height: 8),
                  ExpansionTile(
                    key: const Key('route-review-points-section'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: reviewWaypoints.length <= 8,
                    title: Text(
                      'Route points (${reviewWaypoints.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      reviewWaypoints.length > 8
                          ? 'Tap to review the full ordered list.'
                          : 'Start, stops and destination in order.',
                    ),
                    children: [
                      if (reviewWaypoints.isEmpty)
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'This imported route has geometry but no named waypoints.',
                            style: TextStyle(color: Color(0xFF98A3B1)),
                          ),
                        )
                      else
                        for (final entry in reviewWaypoints.indexed)
                          ListTile(
                            key: Key('route-review-waypoint-${entry.$1}'),
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              child: Text('${entry.$1 + 1}'),
                            ),
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
                            trailing:
                                canEditStops &&
                                    entry.$1 > 0 &&
                                    entry.$1 < reviewWaypoints.length - 1
                                ? IconButton(
                                    key: Key(
                                      'remove-reviewed-waypoint-${entry.$1}',
                                    ),
                                    tooltip: 'Remove this waypoint',
                                    onPressed: _reshaping || _reshapeQueued
                                        ? null
                                        : () => unawaited(
                                            _removeWaypoint(entry.$1),
                                          ),
                                    icon: const Icon(Icons.delete_outline),
                                  )
                                : null,
                          ),
                    ],
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

bool _sameMapPoint(GeoPoint first, GeoPoint second) {
  final latitude = first.latitude - second.latitude;
  final longitude = first.longitude - second.longitude;
  return latitude * latitude + longitude * longitude < 1e-10;
}

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
