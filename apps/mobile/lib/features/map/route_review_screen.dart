import '../../controllers/eta_calibration_controller.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../domain/ride_coordination_mode.dart';
import '../../domain/ride_plan.dart';
import '../../services/basemap_configuration.dart';
import '../../services/biker_place_catalogue.dart';
import '../../services/discovery_layer_preferences.dart';
import '../../services/motorcycle_discovery.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import '../../services/ride_plan_router.dart';
import '../../services/road_routing.dart';
import '../../services/route_marker_plan.dart';
import '../../services/route_preferences_memory.dart';
import '../../services/route_reshape_planner.dart';
import '../../services/route_twistiness.dart';
import '../../services/route_verification.dart';
import '../../services/route_waypoint_editor.dart';
import 'maneuver_list_screen.dart';
import 'place_memory_panel.dart';
import 'place_search_sheet.dart';
import 'resolved_route_map_preview.dart';
import 'ride_plan_panels.dart';
import 'route_preferences_panel.dart';
import 'sheet_close_button.dart';

enum RouteReviewAction { cancel, edit, another, confirm }

/// Routes a plan from wherever the rider is now.
typedef RidePlanRouting =
    Future<RidePlanRoute> Function(RidePlan plan, GeoPoint? currentLocation);

/// What the plan surface needs from the screen that opens it (#847).
///
/// The plan surface is this review screen with the plan's itinerary, route
/// options and, where the host allows it, solo or group on it. Everything the
/// review already did — drawing the route around, cafés and highlights as
/// stops, the marker plan, all turns — is unchanged, so planning a new route,
/// reviewing an imported one and editing a confirmed one happen in one place.
class RidePlanEditing {
  const RidePlanEditing({
    required this.plan,
    required this.route,
    required this.searchService,
    this.currentLocation,
    this.acquireCurrentLocation,
    this.offerCoordinationChoice = false,
    this.confirmLabel = defaultConfirmLabel,
    this.replanOnOpen = false,
    this.preferencesMemory = const RoutePreferencesMemory(),
  });

  final RidePlan plan;
  final RidePlanRouting route;

  /// The same submit-only geocoder as Home's search
  /// (`docs/geocoder-decision.md`).
  final DestinationSearchService searchService;

  /// Where the rider is, for a start that follows them. Null where the host has
  /// no position at all, in which case "Your location" waits to be chosen.
  final ValueListenable<GeoPoint?>? currentLocation;

  /// Asks for one fix when the start is the rider's location and none is known.
  final Future<GeoPoint?> Function()? acquireCurrentLocation;

  /// Whether the rider chooses solo or group here. Off inside a ride, which
  /// already is one or the other.
  final bool offerCoordinationChoice;

  /// What the confirm button says, which depends on what confirming will do.
  final String Function(RidePlan plan) confirmLabel;

  static String defaultConfirmLabel(RidePlan plan) => 'Confirm';

  /// Whether the route being edited is not this plan, routed, even though it
  /// has the same number of places: a plan trimmed to what is left of a ride
  /// starts somewhere else (#893). Its line is shown until the new one comes.
  final bool replanOnOpen;

  /// Where the confirmed route options are remembered for the next new plan
  /// (#894). Null keeps nothing.
  final RoutePreferencesMemory? preferencesMemory;
}

/// A confirmed plan and the route it was routed to.
class RidePlanOutcome {
  const RidePlanOutcome({required this.plan, required this.route});

  final RidePlan plan;
  final ImportedRoute route;
}

typedef RouteReshapeCallback =
    Future<RouteReshapeResult> Function(
      ImportedRoute route,
      List<RouteShapingPoint> shapingPoints,
    );

class RouteReviewAlternative {
  const RouteReviewAlternative({
    required this.route,
    this.distanceMeters,
    this.duration,
    this.twistinessScore,
    this.warnings = const [],
    this.verification,
  });

  final ImportedRoute route;
  final double? distanceMeters;
  final Duration? duration;
  final double? twistinessScore;
  final List<String> warnings;
  final RouteVerification? verification;
}

typedef RouteAlternativeCallback = Future<RouteReviewAlternative> Function();

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
    this.verification,
    this.previousRoute,
    this.comparisonRoute,
    this.canEditStops = false,
    this.canGenerateAlternative = false,
    this.showMarkerPlan = true,
    this.onMarkerReviewChanged,
    this.onReshapeRoute,
    this.onRouteChanged,
    this.onGenerateAlternative,
    this.pointOfInterestLoader,
    this.discoveryLoader,
    this.discoveryPreferencesLoader,
    this.planning,
    this.onPlanChanged,
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

  /// What checking the planned route against the rider's preferences found.
  /// Kept apart from [warnings] because it describes the route's geometry, and
  /// is replaced when the rider reshapes it or asks for another (#840).
  final RouteVerification? verification;
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
  final RouteAlternativeCallback? onGenerateAlternative;
  final Future<BikerPlaceCatalogue> Function()? pointOfInterestLoader;

  /// The motorcycle discovery layers — twisty highlights and the rest — shown
  /// on the review map for the same reason they are shown in free roam: this
  /// is the moment a rider is looking at a whole route and deciding whether to
  /// put something on it (#578).
  final Future<MotorcycleDiscoveryCatalogue> Function()? discoveryLoader;

  /// The rider's existing layer visibility, so the review map shows what free
  /// roam shows rather than inventing a second set of preferences.
  final Future<DiscoveryLayerPreferences> Function()?
  discoveryPreferencesLoader;

  /// Present for the plan surface; null for a plain review (#847).
  final RidePlanEditing? planning;

  /// Reports each change to the plan, so the host can keep the rider's last
  /// word on solo or group and on the itinerary.
  final ValueChanged<RidePlan>? onPlanChanged;

  /// Opens the plan surface and returns the confirmed plan and its route, or
  /// null when the rider cancels.
  ///
  /// [route] is the route being edited. Without one the surface opens on the
  /// plan's places alone and routes them straight away.
  static Future<RidePlanOutcome?> showPlan(
    BuildContext context, {
    required RidePlanEditing planning,
    required DistanceUnit distanceUnit,
    required BasemapConfiguration basemapConfiguration,
    ImportedRoute? route,
    List<String> warnings = const [],
    bool showMarkerPlan = false,
    Future<BikerPlaceCatalogue> Function()? pointOfInterestLoader,
    Future<MotorcycleDiscoveryCatalogue> Function()? discoveryLoader,
    Future<DiscoveryLayerPreferences> Function()? discoveryPreferencesLoader,
  }) async {
    var plan = planning.plan;
    ImportedRoute? routed = route;
    MarkerPlanReview? markerReview;
    final action = await Navigator.of(context).push<RouteReviewAction>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RouteReviewScreen(
          route:
              route ??
              placeholderPlanRoute(
                plan,
                currentLocation: planning.currentLocation?.value,
              ),
          distanceUnit: distanceUnit,
          basemapConfiguration: basemapConfiguration,
          warnings: warnings,
          previousRoute: route,
          canEditStops: true,
          showMarkerPlan: showMarkerPlan,
          planning: planning,
          onPlanChanged: (value) => plan = value,
          onRouteChanged: (value) => routed = value,
          onMarkerReviewChanged: (value) => markerReview = value,
          pointOfInterestLoader: pointOfInterestLoader,
          discoveryLoader: discoveryLoader,
          discoveryPreferencesLoader: discoveryPreferencesLoader,
        ),
      ),
    );
    final confirmed = routed;
    if (action != RouteReviewAction.confirm || confirmed == null) return null;
    // The options a rider confirms are the next new plan's default (#894).
    await planning.preferencesMemory?.remember(plan.preferences);
    return RidePlanOutcome(
      plan: plan,
      route: confirmed.withMarkerReview(markerReview ?? confirmed.markerReview),
    );
  }

  static Future<RouteReviewAction> show(
    BuildContext context, {
    required ImportedRoute route,
    required DistanceUnit distanceUnit,
    required BasemapConfiguration basemapConfiguration,
    double? distanceMeters,
    Duration? duration,
    double? twistinessScore,
    List<String> warnings = const [],
    RouteVerification? verification,
    ImportedRoute? previousRoute,
    ImportedRoute? comparisonRoute,
    bool canEditStops = false,
    bool canGenerateAlternative = false,
    bool showMarkerPlan = true,
    ValueChanged<MarkerPlanReview>? onMarkerReviewChanged,
    RouteReshapeCallback? onReshapeRoute,
    ValueChanged<ImportedRoute>? onRouteChanged,
    RouteAlternativeCallback? onGenerateAlternative,
    Future<BikerPlaceCatalogue> Function()? pointOfInterestLoader,
    Future<MotorcycleDiscoveryCatalogue> Function()? discoveryLoader,
    Future<DiscoveryLayerPreferences> Function()? discoveryPreferencesLoader,
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
            verification: verification,
            previousRoute: previousRoute,
            comparisonRoute: comparisonRoute,
            canEditStops: canEditStops,
            canGenerateAlternative: canGenerateAlternative,
            showMarkerPlan: showMarkerPlan,
            onMarkerReviewChanged: onMarkerReviewChanged,
            onReshapeRoute: onReshapeRoute,
            onRouteChanged: onRouteChanged,
            onGenerateAlternative: onGenerateAlternative,
            pointOfInterestLoader: pointOfInterestLoader,
            discoveryLoader: discoveryLoader,
            discoveryPreferencesLoader: discoveryPreferencesLoader,
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
  late List<String> _warnings = List.of(widget.warnings);
  late RouteVerification? _verification = widget.verification;
  final List<List<RouteShapingPoint>> _reshapeHistory = [];
  Timer? _reshapeTimer;
  int _reshapeGeneration = 0;
  String? _activeShapingPointId;
  String? _reshapeError;
  late bool _reshapeEnabled;
  bool _reshapeQueued = false;
  bool _reshaping = false;
  bool _generatingAlternative = false;
  int _shapeSequence = 0;
  BikerPlaceCatalogue _pointOfInterests = BikerPlaceCatalogue.empty;
  MotorcycleDiscoveryCatalogue _discoveries =
      const MotorcycleDiscoveryCatalogue([]);
  List<MotorcycleDiscoveryFeature> _nearbyDiscoveries = const [];
  Set<MotorcycleDiscoveryCategory> _enabledDiscoveryCategories = const {};
  bool _showDiscoveries = true;
  List<BikerPlace> _nearbyPointsOfInterest = const [];
  bool _showPointsOfInterest = true;
  bool _loadingPointsOfInterest = false;
  String? _pointOfInterestError;

  /// The plan on screen, in plan mode (#847). Null for a plain review.
  late RidePlan? _plan = widget.planning?.plan;

  /// Whether [_route] is the plan, routed. False while the plan still has to
  /// be routed or the last attempt failed, and confirming waits until it is.
  bool _planRouted = false;
  String? _planError;

  /// A named place whose pin is being dragged on the map, and where it is now
  /// (#891). Counted as the plan's places are: start, stops, destination.
  ({int index, GeoPoint point})? _draggedPlace;

  /// A fix the host fetched on request, for a host whose position does not
  /// update on its own.
  GeoPoint? _acquiredLocation;

  /// The rider's position, for a start that follows them.
  GeoPoint? get _currentLocation =>
      widget.planning?.currentLocation?.value ?? _acquiredLocation;

  /// Asks the host for one fix, and plans from it when it comes.
  Future<void> _acquireLocation() async {
    final acquire = widget.planning?.acquireCurrentLocation;
    if (acquire == null) return;
    final point = await acquire();
    if (!mounted || point == null) return;
    _acquiredLocation = point;
    _onCurrentLocationChanged();
  }

  DistanceUnit get distanceUnit => widget.distanceUnit;
  BasemapConfiguration get basemapConfiguration => widget.basemapConfiguration;
  double? get distanceMeters => _distanceMeters;
  Duration? get duration => _duration;
  double? get twistinessScore => _twistinessScore;
  List<String> get warnings => _warnings;
  ImportedRoute? get previousRoute => widget.previousRoute;
  ImportedRoute? get comparisonRoute => widget.comparisonRoute;
  bool get canEditStops => widget.canEditStops || widget.planning != null;

  /// The route as reviewed so far. Everything downstream - the plan, the pins,
  /// the counts - reads this, so the map and the list can never disagree about
  /// which positions are still suggested.
  ImportedRoute get route => _route.withMarkerReview(_markerReview);

  @override
  void initState() {
    super.initState();
    // Navigation is the default. Drawing places an opaque gesture surface over
    // the native map, so opening editable reviews in that mode made ordinary
    // drag-to-pan and pinch-to-zoom gestures appear broken.
    _reshapeEnabled = false;
    if (canEditStops && _reshapeCallback != null) {
      unawaited(_loadPointsOfInterest());
    }
    final planning = widget.planning;
    final plan = _plan;
    if (planning != null && plan != null) {
      planning.currentLocation?.addListener(_onCurrentLocationChanged);
      // A route that is already this plan, routed, can be confirmed as it is.
      // Anything else — a new plan, or a route whose waypoints are not the
      // plan's places — is routed now, so the line, the list and the drawn
      // adjustments all describe the same legs.
      _planRouted = !planning.replanOnOpen && isRoutedPlan(widget.route, plan);
      if (!_planRouted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_replan(plan));
        });
      }
    }
  }

  /// A fix arriving for a plan that was waiting for one.
  void _onCurrentLocationChanged() {
    final plan = _plan;
    if (!mounted ||
        plan == null ||
        _planRouted ||
        _reshaping ||
        !plan.startsAtCurrentLocation ||
        _currentLocation == null) {
      return;
    }
    unawaited(_replan(plan));
  }

  /// Routes [plan] and shows it, ignoring any answer a later edit overtakes.
  Future<void> _replan(RidePlan plan) async {
    final planning = widget.planning;
    if (planning == null) return;
    _reshapeTimer?.cancel();
    final generation = ++_reshapeGeneration;
    final location = _currentLocation;
    final routable = plan.controls(currentLocation: location) != null;
    setState(() {
      _plan = plan;
      _activeShapingPointId = null;
      _reshapeQueued = false;
      _reshapeError = null;
      _planError = null;
      _planRouted = false;
      _reshaping = routable;
    });
    widget.onPlanChanged?.call(plan);
    if (!routable) {
      // An edit that starts from "your location" needs a fix to re-plan from;
      // ask for one, and plan when it comes.
      if (plan.startsAtCurrentLocation && _currentLocation == null) {
        unawaited(_acquireLocation());
      }
      return;
    }
    try {
      final result = await planning.route(plan, location);
      if (!mounted || generation != _reshapeGeneration) return;
      setState(() {
        _route = result.route.withMarkerReview(_markerReview);
        _lastSuccessfulRoute = _route;
        _distanceMeters = result.distanceMeters;
        _duration = result.duration;
        _twistinessScore = result.twistinessScore;
        _warnings = {...widget.warnings, ...result.warnings}.toList();
        // The geometry on screen is what was checked (#840).
        _verification = result.verification;
        _planRouted = true;
        _nearbyPointsOfInterest = _pointOfInterests.nearRoute(_route.allPoints);
        _nearbyDiscoveries = _discoveriesNearRoute(
          _discoveries,
          _enabledDiscoveryCategories,
        );
      });
      widget.onRouteChanged?.call(_route);
    } on Object catch (error) {
      if (!mounted || generation != _reshapeGeneration) return;
      setState(() {
        _planError =
            'This plan could not be routed. '
            '${error is FormatException ? error.message : '$error'}';
      });
    } finally {
      if (mounted && generation == _reshapeGeneration) {
        setState(() => _reshaping = false);
      }
    }
  }

  void _setCoordinationMode(RidePlan plan, RideCoordinationMode mode) {
    final updated = plan.withCoordinationMode(mode);
    setState(() => _plan = updated);
    widget.onPlanChanged?.call(updated);
  }

  Future<void> _changeStart(RidePlan plan) async {
    final choice = await PlaceSearchSheet.show(
      context,
      searchService: widget.planning!.searchService,
      title: 'Start from',
      offerCurrentLocation: true,
      currentLocationKnown: _currentLocation != null,
      currentPoint: _currentLocation,
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case PlaceSearchCurrentLocation():
        await _replan(plan.withStart(const CurrentLocationStart()));
      case PlaceSearchPlace(:final place):
        await _replan(plan.withStart(PlaceStart(place)));
    }
  }

  Future<void> _changeDestination(RidePlan plan) async {
    final choice = await PlaceSearchSheet.show(
      context,
      searchService: widget.planning!.searchService,
      title: 'Where to?',
      currentPoint: _currentLocation,
    );
    if (choice is! PlaceSearchPlace || !mounted) return;
    await _replan(plan.withDestination(choice.place));
  }

  /// Saves a place on the plan - a stop, the destination, a start the rider
  /// chose, or a pin they dropped by dragging - as Home, Work or a name of their
  /// own (#937). Stays on the phone.
  Future<void> _savePlace(RidePlanPlace place) async {
    final saved = await PlaceMemoryActions.saveOnce(context, place);
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved as ${saved.name}')));
  }

  Future<void> _addStop(RidePlan plan) async {
    final choice = await PlaceSearchSheet.show(
      context,
      searchService: widget.planning!.searchService,
      title: 'Add a stop',
      currentPoint: _currentLocation,
    );
    if (choice is! PlaceSearchPlace || !mounted) return;
    await _replan(
      plan.addStop(choice.place, currentLocation: _currentLocation),
    );
  }

  /// The plan with [candidate]'s stops and adjustments: what a café or
  /// highlight added on the map becomes. The ends stay the plan's own, so a
  /// start that follows the rider keeps following them.
  RidePlan _planAdopting(RidePlan plan, ImportedRoute candidate) {
    final waypoints = candidate.waypoints;
    return plan.copyWith(
      stops: [
        for (final (index, waypoint)
            in waypoints.sublist(1, waypoints.length - 1).indexed)
          RidePlanPlace.fromWaypoint(
            waypoint,
            fallbackLabel: 'Stop ${index + 1}',
          ),
      ],
      shapingPoints: candidate.shapingPoints,
    );
  }

  /// Plan mode routes drawn adjustments through the plan, so they go to the
  /// router as non-stopping controls with the plan's stops and preferences.
  RouteReshapeCallback? get _reshapeCallback {
    final planning = widget.planning;
    if (planning == null) return widget.onReshapeRoute;
    return (candidate, shapingPoints) async {
      final plan = _plan!.withShapingPoints(shapingPoints);
      final result = await planning.route(plan, _currentLocation);
      return RouteReshapeResult(
        route: result.route,
        distanceMeters: result.distanceMeters,
        duration: result.duration,
        twistinessScore: result.twistinessScore,
        verification: result.verification,
      );
    };
  }

  /// Keeps the plan's adjustments with the route that is now on screen.
  void _adoptRouteShapingPoints(ImportedRoute route) {
    final plan = _plan;
    if (plan == null) return;
    final updated = plan.withShapingPoints(route.shapingPoints);
    _plan = updated;
    widget.onPlanChanged?.call(updated);
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
      // Loaded separately from the cafés on purpose. `_loadDiscoveryCatalogue`
      // in the map feature puts three loads in one `Future.wait`, so a failed
      // asset read takes the other two silently down with it; there is no
      // reason to repeat that here.
      await _loadDiscoveries();
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

  Future<void> _generateAlternative() async {
    if (_reshapeQueued || _reshaping || _generatingAlternative) return;
    final callback = widget.onGenerateAlternative;
    if (callback == null) return;
    setState(() {
      _generatingAlternative = true;
      _reshapeError = null;
    });
    try {
      final alternative = await callback();
      if (!mounted) return;
      final updatedRoute = alternative.route;
      final updatedReview = updatedRoute.markerReview;
      setState(() {
        _route = updatedRoute;
        _lastSuccessfulRoute = updatedRoute;
        _markerReview = updatedReview;
        _distanceMeters = alternative.distanceMeters;
        _duration = alternative.duration;
        _twistinessScore = alternative.twistinessScore;
        _warnings = List.of(alternative.warnings);
        _verification = alternative.verification;
        _reshapeHistory.clear();
        _activeShapingPointId = null;
        _nearbyPointsOfInterest = _pointOfInterests.nearRoute(
          updatedRoute.allPoints,
        );
        _nearbyDiscoveries = _discoveriesNearRoute(
          _discoveries,
          _enabledDiscoveryCategories,
        );
      });
      widget.onMarkerReviewChanged?.call(updatedReview);
      widget.onRouteChanged?.call(updatedRoute);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Could not create another route. The current route is unchanged. '
            '$error',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _generatingAlternative = false);
    }
  }

  @override
  void dispose() {
    _reshapeTimer?.cancel();
    _reshapeGeneration += 1;
    widget.planning?.currentLocation?.removeListener(_onCurrentLocationChanged);
    super.dispose();
  }

  void _beginRouteReshape(RoutePreviewReshapeStart start) {
    if (_reshapeCallback == null) return;
    // A plan still waiting for its first route has no line to drag.
    if (_plan != null && !_planRouted) return;
    if (start.draggedPin case final pin?) {
      // A named place moves with the finger and is routed when it is let go;
      // the line under it is left alone (#891).
      final index = planPlacePinIndex(pin);
      if (_plan != null && index != null) {
        setState(() {
          _draggedPlace = (index: index, point: start.point);
          _reshapeError = null;
        });
      }
      return;
    }
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
    if (_draggedPlace case final dragged?) {
      setState(() => _draggedPlace = (index: dragged.index, point: point));
      return;
    }
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
    if (_draggedPlace case final dragged?) {
      _draggedPlace = null;
      final plan = _plan;
      if (plan == null) return;
      // The places keep their order, so every drawn adjustment stays on the
      // leg it was drawn on.
      unawaited(
        _replan(
          plan.withPlaceMoved(
            dragged.index,
            dragged.point,
            currentLocation: _currentLocation,
          ),
        ),
      );
      return;
    }
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
    final callback = _reshapeCallback;
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
            if (_plan != null) {
              _adoptRouteShapingPoints(result.route);
              _planRouted = true;
            }
            _verification = result.verification;
          });
          widget.onRouteChanged?.call(_route);
        } on Object catch (error) {
          if (!mounted || generation != _reshapeGeneration) return;
          setState(() {
            _route = _lastSuccessfulRoute;
            if (_plan != null) _adoptRouteShapingPoints(_lastSuccessfulRoute);
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

  /// The discovery layers, filtered to the rider's enabled categories and to
  /// the corridor of the route being reviewed.
  Future<void> _loadDiscoveries() async {
    try {
      final catalogue =
          await (widget.discoveryLoader?.call() ??
              MotorcycleDiscoveryCatalogue.loadAsset());
      final preferences =
          await (widget.discoveryPreferencesLoader?.call() ??
              DiscoveryLayerPreferences.load());
      if (!mounted) return;
      setState(() {
        _discoveries = catalogue;
        _enabledDiscoveryCategories = {...preferences.categories};
        _nearbyDiscoveries = _discoveriesNearRoute(
          catalogue,
          _enabledDiscoveryCategories,
        );
      });
    } on Object catch (error) {
      if (!mounted) return;
      // Said, not swallowed. The cafés and the route drawing are unaffected.
      setState(() {
        _pointOfInterestError =
            'Discovery layers could not be loaded. Route drawing still works. '
            '$error';
      });
    }
  }

  List<MotorcycleDiscoveryFeature> _discoveriesNearRoute(
    MotorcycleDiscoveryCatalogue catalogue,
    Set<MotorcycleDiscoveryCategory> categories,
  ) {
    final points = route.allPoints;
    if (points.isEmpty || categories.isEmpty) {
      return const <MotorcycleDiscoveryFeature>[];
    }
    var west = points.first.longitude;
    var east = west;
    var south = points.first.latitude;
    var north = south;
    for (final point in points.skip(1)) {
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
    }
    // The same padding free roam uses, so the two surfaces show the same
    // features for the same route rather than differing at the edges.
    const paddingDegrees = 0.6;
    return catalogue.visible(
      categories: categories,
      west: west - paddingDegrees,
      south: south - paddingDegrees,
      east: east + paddingDegrees,
      north: north + paddingDegrees,
    );
  }

  Future<void> _showPointOfInterest(BikerPlace place) async {
    if (_reshaping || _reshapeQueued || _reshapeCallback == null) return;
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
                  // A way out that is not "act on it" (#592).
                  const SheetCloseButton(),
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

  /// Adds a discovery highlight as an ordered stop, the same way a café is
  /// added — the point of showing the layers here is that this is where a stop
  /// gets chosen (#578).
  Future<void> _showDiscoveryFeature(MotorcycleDiscoveryFeature feature) async {
    if (_reshaping || _reshapeQueued || _reshapeCallback == null) return;
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
                    child: Icon(Icons.route, color: Color(0xFF8CD98C)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          feature.name,
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(feature.category.label),
                        const SizedBox(height: 4),
                        // Carried through rather than dropped: a highlight is
                        // a suggestion with a caveat, and the caveat is the
                        // half a rider needs before routing through it.
                        Text(
                          feature.warning,
                          style: const TextStyle(
                            color: Color(0xFF98A3B1),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // A way out that is not "act on it" (#592).
                  const SheetCloseButton(),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: Key('review-add-discovery-${feature.id}'),
                onPressed: () => Navigator.of(sheetContext).pop(true),
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add as a stop'),
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
        point: feature.anchor,
        name: feature.name,
        description: '${feature.category.label} · ${feature.warning}',
        symbol: 'Scenic Area',
      ),
    );
    await _recalculateEditedRoute(
      candidate,
      failurePrefix: 'Could not route via ${feature.name}.',
    );
  }

  Future<void> _removeWaypoint(int index) async {
    if (_reshaping || _reshapeQueued || _reshapeCallback == null) return;
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
    // On the plan surface a stop added on the map is a plan edit like any
    // other: the plan takes the stop and its leg, and is routed as a whole.
    if (_plan case final plan?) {
      await _replan(_planAdopting(plan, candidate));
      return;
    }
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

  MotorcycleDiscoveryFeature? _discoveryForPin(RoutePreviewPin pin) {
    final id = pin.id;
    if (id == null) return null;
    return _discoveries.features
        .where((feature) => 'discovery-${feature.id}' == id)
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
    final plan = _plan;
    // On the plan surface the pins are the plan's places, so a dragged or
    // added stop is where the rider put it while its route is calculated.
    final placePinPoints =
        plan
            ?.controls(currentLocation: _currentLocation)
            ?.namedPlaces
            .map((place) => place.point)
            .toList(growable: false) ??
        reviewWaypoints
            .map((waypoint) => waypoint.point)
            .toList(growable: false);
    // A drop-off group's leader plans marker positions, wherever the route
    // came from; choosing that mode on the plan surface brings the plan in.
    final showMarkerPlan =
        widget.showMarkerPlan ||
        (plan?.coordinationMode.usesSecondBikeDropOff ?? false);
    final markerPlan = showMarkerPlan
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
    final visibleDiscoveries = canEditStops && _showDiscoveries
        ? _nearbyDiscoveries
        : const <MotorcycleDiscoveryFeature>[];
    final discoveryPins = visibleDiscoveries
        .map(
          (feature) => RoutePreviewPin(
            id: 'discovery-${feature.id}',
            label: feature.name,
            point: feature.anchor,
            kind: 'discovery',
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
      ...?_verification?.notices(distanceUnit),
      ?materialWarning,
    ];
    final formatter = MeasurementFormatter(distanceUnit);
    final maneuverCount = const NavigationGuidancePlanner()
        .instructions(route)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: Tooltip(
          message: route.name,
          child: Text(
            route.name,
            key: const Key('route-review-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        leading: IconButton(
          tooltip: 'Cancel route review',
          onPressed: () => Navigator.of(context).pop(RouteReviewAction.cancel),
          icon: const Icon(Icons.close),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SizedBox(
            key: const Key('route-review-actions'),
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.canGenerateAlternative)
                  TextButton.icon(
                    key: const Key('generate-another-route'),
                    onPressed:
                        _reshapeQueued ||
                            _reshaping ||
                            _generatingAlternative ||
                            widget.onGenerateAlternative == null
                        ? null
                        : _generateAlternative,
                    icon: _generatingAlternative
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(
                      _generatingAlternative ? 'Creating…' : 'Another',
                    ),
                  ),
                // The plan surface edits its stops in place; returning to a
                // form to do it lost everything drawn on the map (#847).
                if (canEditStops && plan == null)
                  IconButton(
                    key: const Key('edit-reviewed-route'),
                    tooltip: 'Edit stops',
                    onPressed: _generatingAlternative
                        ? null
                        : () =>
                              Navigator.of(context).pop(RouteReviewAction.edit),
                    icon: const Icon(Icons.edit_location_alt_outlined),
                  ),
                TextButton.icon(
                  key: const Key('confirm-reviewed-route'),
                  onPressed:
                      _reshapeQueued ||
                          _reshaping ||
                          _generatingAlternative ||
                          (plan != null && !_planRouted)
                      ? null
                      : () => Navigator.of(
                          context,
                        ).pop(RouteReviewAction.confirm),
                  icon: const Icon(Icons.check),
                  label: Text(
                    plan == null
                        ? 'Confirm'
                        : widget.planning!.confirmLabel(plan),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
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
                        referencePaths: comparisonPreviewPaths ?? const [],
                        pins: placePinPoints.indexed
                            .map(
                              (entry) => RoutePreviewPin(
                                id: plan == null
                                    ? null
                                    : '$planPlacePinPrefix${entry.$1}',
                                point: _draggedPlace?.index == entry.$1
                                    ? _draggedPlace!.point
                                    : entry.$2,
                                kind: entry.$1 == 0 ? 'start' : 'waypoint',
                                // A plan's start, stops and destination can
                                // be dragged while drawing (#891).
                                draggable: plan != null,
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
                            .followedBy(discoveryPins)
                            .toList(growable: false),
                        basemapConfiguration: basemapConfiguration,
                        reshapeEnabled: _reshapeEnabled,
                        onPinTap: (pin) {
                          final place = _pointOfInterestForPin(pin);
                          if (place != null) {
                            unawaited(_showPointOfInterest(place));
                            return;
                          }
                          final feature = _discoveryForPin(pin);
                          if (feature != null) {
                            unawaited(_showDiscoveryFeature(feature));
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
                              key: const Key('route-review-waypoints'),
                              // Upright however the map is turned; the number
                              // inside the pin must stay readable (#935).
                              rotate: true,
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
                          Builder(
                            builder: (context) {
                              final camera = MapCamera.of(context);
                              final bounds = camera.visibleBounds;
                              final pins = visibleRoutePreviewPins(
                                [...pointOfInterestPins, ...discoveryPins],
                                zoom: camera.zoom,
                                tileSize: 256,
                                viewport: [
                                  GeoPoint(
                                    latitude: bounds.south,
                                    longitude: bounds.west,
                                  ),
                                  GeoPoint(
                                    latitude: bounds.north,
                                    longitude: bounds.east,
                                  ),
                                ],
                              );
                              return MarkerLayer(
                                key: const Key(
                                  'route-review-points-of-interest',
                                ),
                                markers: pins
                                    .map(
                                      (pin) => Marker(
                                        point: _latLng(pin.point),
                                        width: 40,
                                        height: 40,
                                        child: Semantics(
                                          button: true,
                                          label:
                                              'Add ${pin.label} as a waypoint',
                                          child: GestureDetector(
                                            key: Key(
                                              pin.kind == 'poi'
                                                  ? 'route-point-of-interest-${pin.id!.substring(4)}'
                                                  : 'route-${pin.id}',
                                            ),
                                            onTap: () {
                                              final place =
                                                  _pointOfInterestForPin(pin);
                                              if (place != null) {
                                                unawaited(
                                                  _showPointOfInterest(place),
                                                );
                                              }
                                              final feature = _discoveryForPin(
                                                pin,
                                              );
                                              if (feature != null) {
                                                unawaited(
                                                  _showDiscoveryFeature(
                                                    feature,
                                                  ),
                                                );
                                              }
                                            },
                                            child: Tooltip(
                                              message: pin.label ?? '',
                                              child: Icon(
                                                pin.kind == 'poi'
                                                    ? Icons.local_cafe
                                                    : Icons.route,
                                                color: const Color(0xFFF97316),
                                                size: 30,
                                                shadows: const [
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
                              );
                            },
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
                  if (plan != null) ...[
                    RidePlanItinerary(
                      plan: plan,
                      currentLocationKnown: _currentLocation != null,
                      // Edits stay possible while a route is calculated: the
                      // newest edit wins and an overtaken answer is dropped.
                      busy: _reshapeQueued || _generatingAlternative,
                      onChangeStart: () => unawaited(_changeStart(plan)),
                      onChangeDestination: () =>
                          unawaited(_changeDestination(plan)),
                      onAddStop: () => unawaited(_addStop(plan)),
                      onSavePlace: (place) => unawaited(_savePlace(place)),
                      onMoveStop: (from, to) => unawaited(
                        _replan(
                          plan.moveStop(
                            from,
                            to,
                            currentLocation: _currentLocation,
                          ),
                        ),
                      ),
                      onRemoveStop: (index) =>
                          unawaited(_replan(plan.removeStop(index))),
                    ),
                    if (_planError case final error?) ...[
                      const SizedBox(height: 8),
                      _WarningCard(warning: error),
                    ],
                    if (widget.planning!.offerCoordinationChoice) ...[
                      const SizedBox(height: 16),
                      RidePlanPartySelector(
                        mode: plan.coordinationMode,
                        onChanged: (mode) => _setCoordinationMode(plan, mode),
                      ),
                    ],
                    const SizedBox(height: 8),
                    ExpansionTile(
                      key: const Key('ride-plan-preferences'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(
                        'Route options',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      subtitle: Text(plan.preferences.summary),
                      children: [
                        RoutePreferencesPanel(
                          preferences: plan.preferences,
                          enabled: !_reshapeQueued && !_generatingAlternative,
                          onChanged: (preferences) => unawaited(
                            _replan(plan.withPreferences(preferences)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (plan == null || _planRouted)
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
                            label: _durationLabel(
                              Duration(
                                milliseconds:
                                    (value.inMilliseconds *
                                            (EtaCalibrationScope.of(
                                                  context,
                                                )?.factorFor(_route) ??
                                                1))
                                        .round(),
                              ),
                            ),
                          ),
                        // "2 route points" under a curvy line read as two
                        // points of geometry (#626). The plan says what it means.
                        _SummaryItem(
                          icon: Icons.pin_drop_outlined,
                          label: plan == null
                              ? '${reviewWaypoints.length} route point${reviewWaypoints.length == 1 ? '' : 's'}'
                              : plan.stops.isEmpty
                              ? 'No stops'
                              : '${plan.stops.length} stop${plan.stops.length == 1 ? '' : 's'}',
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
                  if (route.preferences case final preferences?
                      when plan == null) ...[
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
                  if (_reshapeCallback != null) ...[
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
                        if (canEditStops && _nearbyDiscoveries.isNotEmpty)
                          FilterChip(
                            key: const Key('toggle-route-discovery-layers'),
                            selected: _showDiscoveries,
                            avatar: const Icon(Icons.route, size: 18),
                            label: Text(
                              'Good roads (${visibleDiscoveries.length})',
                            ),
                            onSelected: (selected) =>
                                setState(() => _showDiscoveries = selected),
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
                      if (plan != null) ...[
                        const SizedBox(height: 10),
                        const Text(
                          'Route adjustments (not stops)',
                          key: Key('ride-plan-adjustments-heading'),
                          style: TextStyle(
                            color: Color(0xFF98A3B1),
                            fontSize: 12,
                          ),
                        ),
                      ],
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
                  if (showMarkerPlan &&
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
                  // The plan surface's itinerary replaces this read-only list.
                  if (plan == null)
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

/// What the plan surface shows before its first route arrives: the plan's
/// places as pins, and no line yet.
@visibleForTesting
ImportedRoute placeholderPlanRoute(RidePlan plan, {GeoPoint? currentLocation}) {
  final start = plan.resolvedStart(currentLocation: currentLocation);
  final destination = plan.destination;
  return ImportedRoute(
    id: 'ride-plan-preview',
    name: destination == null ? 'New route' : RidePlan.nameFor(destination),
    importedAt: DateTime.now().toUtc(),
    sourceFileName: 'ride-plan-preview',
    paths: const [],
    waypoints: [
      ?start?.toWaypoint(defaultSymbol: RidePlanRouter.startSymbol),
      for (final stop in plan.stops)
        stop.toWaypoint(defaultSymbol: RidePlanRouter.stopSymbol),
      ?destination?.toWaypoint(defaultSymbol: RidePlanRouter.destinationSymbol),
    ],
    preferences: plan.preferences,
  );
}

/// Whether [route] already is [plan], routed: a line, and the plan's named
/// places and nothing else as its waypoints. Anything else is routed when the
/// plan surface opens, so the list, the line and the drawn adjustments agree
/// about which legs there are.
@visibleForTesting
/// The id prefix of a plan place's map pin; the rest is its index among the
/// plan's start, stops and destination.
const planPlacePinPrefix = 'plan-place-';

/// Which of the plan's places [pin] is, or null when it is none of them.
int? planPlacePinIndex(RoutePreviewPin pin) {
  final id = pin.id;
  if (!pin.draggable || id == null || !id.startsWith(planPlacePinPrefix)) {
    return null;
  }
  return int.tryParse(id.substring(planPlacePinPrefix.length));
}

bool isRoutedPlan(ImportedRoute route, RidePlan plan) =>
    !plan.derivedFromGeometry &&
    route.paths.any((path) => path.points.length >= 2) &&
    route.waypoints.length == plan.stops.length + 2;

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
