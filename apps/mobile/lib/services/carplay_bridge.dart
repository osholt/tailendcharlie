import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/hazard.dart';
import '../domain/imported_route.dart';
import '../domain/distance_unit.dart';
import '../domain/rider_color.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import '../features/map/motorcycle_icon.dart';
import 'android_auto_navigation_projection.dart';
import 'basemap_configuration.dart';
import 'carplay_navigation_projection.dart';
import 'guidance_time_remaining.dart';
import 'carplay_tec_status.dart';
import 'navigation_camera.dart';
import 'navigation_guidance.dart';
import 'route_progress.dart';
import 'route_journey_progress.dart';

enum CarPlaySurfaceMode { home, preRide, activeRide, endedRide }

/// A submitted CarPlay search result. Coordinates are carried with the label so
/// choosing the second of several places with the same name cannot silently
/// route to the geocoder's first result instead.
class CarPlayDestination {
  const CarPlayDestination({required this.label, required this.point});

  final String label;
  final GeoPoint point;

  Map<String, Object> toSnapshot() => {
    'label': label,
    'latitude': point.latitude,
    'longitude': point.longitude,
  };

  static CarPlayDestination? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    final latitude = raw['latitude'];
    final longitude = raw['longitude'];
    if (label is! String ||
        label.trim().isEmpty ||
        latitude is! num ||
        longitude is! num) {
      return null;
    }
    final lat = latitude.toDouble();
    final lon = longitude.toDouble();
    if (!lat.isFinite ||
        !lon.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lon < -180 ||
        lon > 180) {
      return null;
    }
    return CarPlayDestination(
      label: label.trim(),
      point: GeoPoint(latitude: lat, longitude: lon),
    );
  }
}

/// The saved phone identity used on the home map before a ride session exists.
/// It keeps CarPlay's local marker identical to the phone rather than replacing
/// it with a generic blue dot until a ride is created.
class CarPlayLocalRider {
  const CarPlayLocalRider({
    required this.riderId,
    required this.displayName,
    required this.motorcycleStyle,
    required this.riderSymbol,
    required this.riderColor,
    this.roleLabel = 'Rider',
  });

  final String riderId;
  final String displayName;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderSymbol riderSymbol;
  final RiderColor riderColor;
  final String roleLabel;
}

String _readableCarPlayError(Object error, {required String fallback}) =>
    error is FormatException ? error.message : fallback;

/// Publishes projected ride and navigation state to the native CarPlay and
/// Android Auto scenes, and relays the CarPlay emergency button back to
/// [onEmergencyTriggered].
///
/// CarPlay renders the route and rider positions in its navigation scene and
/// keeps the existing glanceable ride-status list available from that map.
///
/// The snapshot carries the back-marker as its own block ([CarPlayTecStatus])
/// rather than leaving a head unit to infer it from the rider list. The app is
/// named after that role, and a leader who can see five riders listed but not
/// whether anybody is watching the back has been told the least useful half of
/// the group's state.
///
/// One bidirectional method channel rather than a channel pair: unlike the
/// nearby transport (native is the continuous data source there, so it uses
/// an `EventChannel`), Dart is the frequent source here - it calls
/// `updateSnapshot` on every ride-state change - and native only pushes back
/// the occasional `triggerEmergency` call.
class CarPlayBridge {
  CarPlayBridge({
    this.onEmergencyTriggered,
    this.onLeaveRequested,
    this.onHazardReported,
    this.onTecRoleAnswered,
    this.onRideStartRequested,
    this.onDestinationSearch,
    this.onDestinationSelected,
    this.onFreeRoamRequested,
    this.onStateRequested,
    this.onAndroidAutoNavigationHostEvent,
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting String? projectionSourceId,
    @visibleForTesting
    this._minimumPublishInterval = const Duration(seconds: 1),
  }) : _channel =
           channel ?? const MethodChannel('me.osholt.ride_relay/carplay'),
       _clock = clock ?? DateTime.now,
       _projectionSourceId =
           projectionSourceId ??
           '${DateTime.now().microsecondsSinceEpoch}-${_nextProjectionSourceId++}' {
    _methodHandlerOwner = this;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// Flutter can inflate the next ride surface before unmounting the previous
  /// one. Without ownership, the old surface's late dispose clears the new
  /// surface's handler and CarPlay controls stop responding at exactly the
  /// home-to-ride transition.
  static CarPlayBridge? _methodHandlerOwner;
  static int _nextProjectionSourceId = 1;

  final MethodChannel _channel;
  final DateTime Function() _clock;
  final Duration _minimumPublishInterval;
  final String _projectionSourceId;
  final Future<void> Function()? onEmergencyTriggered;

  /// Leaves the current ride after CarPlay has shown its own confirmation.
  /// The phone remains the lifecycle owner and publishes the durable departure.
  final Future<void> Function()? onLeaveRequested;

  /// A first-hand road alert raised from the CarPlay report control. The
  /// native side sends only the type; the phone remains responsible for
  /// validating it, attaching the current fix and publishing the event.
  final Future<void> Function(HazardType type)? onHazardReported;

  /// The rider's answer to a leader's Tail End Charlie request, given on the
  /// head unit (#128).
  final Future<void> Function(String requestId, bool accepted)?
  onTecRoleAnswered;

  /// Starts a ride that was already configured on the phone. Native only
  /// offers the action when the projected state says it is safe, but Dart
  /// revalidates the leader and lifecycle state before recording anything.
  final Future<void> Function()? onRideStartRequested;

  /// Searches only after the rider submits CarPlay's search field. The public
  /// geocoder used by the phone forbids autocomplete, so native deliberately
  /// does not call this while each character is entered.
  final Future<List<CarPlayDestination>> Function(String query)?
  onDestinationSearch;

  /// Plans the selected result on the phone, which remains the single owner of
  /// routing, route persistence and ride creation. [groupRide] is non-null on
  /// the home surface and null when a prepared ride is changing its route.
  final Future<void> Function(CarPlayDestination destination, bool? groupRide)?
  onDestinationSelected;

  /// Creates and starts a route-less solo ride from the home map.
  final Future<void> Function()? onFreeRoamRequested;

  /// Rebuilds the current projection when the CarPlay scene opens.
  ///
  /// The scene can connect after a quiet or restored ride, when no new
  /// position event is due to refresh the native cache. Treating the connection
  /// as an explicit read request prevents CarPlay opening with an earlier empty
  /// roster or world-sized camera.
  final Future<void> Function()? onStateRequested;

  /// Receives Android host lifecycle/intent acknowledgements. The typed event
  /// is deliberately separate from ride commands: losing navigation ownership
  /// must never imply leaving or ending the recorded ride.
  final Future<void> Function(AndroidAutoNavigationHostEvent event)?
  onAndroidAutoNavigationHostEvent;
  DateTime? _lastPublishedAt;

  /// The request the head unit was last told about, so a new one can jump the
  /// throttle and an answered one can take its alert down.
  String? _publishedTecRequestId;
  String? _publishedRideStartKey;
  String? _publishedSurfaceKey;
  int _publishAttempt = 0;

  /// The status list is glanceable, but the same snapshot also drives the live
  /// rider markers, manoeuvre distance and route progress. Ten seconds left the
  /// head unit visibly behind the phone during a ride, so full snapshots are
  /// bounded to one per second while the much smaller camera viewport follows
  /// the phone's own 400 ms camera cadence independently.

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'triggerEmergency':
        await onEmergencyTriggered?.call();
      case 'leaveRide':
        await onLeaveRequested?.call();
      case 'reportHazard':
        final arguments = call.arguments;
        if (arguments is! Map) return;
        final rawType = arguments['type'];
        if (rawType is! String) return;
        final type = HazardType.values
            .where((candidate) => candidate.name == rawType)
            .firstOrNull;
        if (type == null || !type.isRiderReportable) return;
        await onHazardReported?.call(type);
      case 'answerTecRoleRequest':
        final arguments = call.arguments;
        if (arguments is! Map) return;
        final requestId = arguments['requestId'];
        final accepted = arguments['accepted'];
        // A malformed answer is dropped rather than guessed at: recording
        // "accepted" for a request this phone cannot identify would put a rider
        // on the back of the group without them having agreed to it.
        if (requestId is! String || requestId.isEmpty || accepted is! bool) {
          return;
        }
        await onTecRoleAnswered?.call(requestId, accepted);
      case 'startPreparedRide':
        await onRideStartRequested?.call();
      case 'searchDestinations':
        final arguments = call.arguments;
        final query = arguments is Map ? arguments['query'] : null;
        if (query is! String || query.trim().isEmpty) {
          return const {
            'results': <Object?>[],
            'error': 'Enter a destination.',
          };
        }
        final search = onDestinationSearch;
        if (search == null) {
          return const {
            'results': <Object?>[],
            'error': 'Destination search is unavailable on this screen.',
          };
        }
        try {
          final results = await search(query.trim());
          return {
            'results': [for (final result in results) result.toSnapshot()],
            'error': null,
          };
        } on Object catch (error) {
          return {
            'results': const <Object?>[],
            'error': _readableCarPlayError(
              error,
              fallback: 'Could not search for that destination.',
            ),
          };
        }
      case 'planDestination':
        final destination = CarPlayDestination.tryParse(call.arguments);
        final planner = onDestinationSelected;
        if (destination == null) {
          return const {
            'ok': false,
            'error': 'That destination is invalid. Search again.',
          };
        }
        if (planner == null) {
          return const {
            'ok': false,
            'error': 'Route planning is unavailable on this screen.',
          };
        }
        final arguments = call.arguments as Map;
        final rawGroupRide = arguments['groupRide'];
        if (rawGroupRide != null && rawGroupRide is! bool) {
          return const {
            'ok': false,
            'error': 'The ride type is invalid. Try again.',
          };
        }
        try {
          await planner(destination, rawGroupRide as bool?);
          return const {'ok': true, 'error': null};
        } on Object catch (error) {
          return {
            'ok': false,
            'error': _readableCarPlayError(
              error,
              fallback: 'Could not plan that route.',
            ),
          };
        }
      case 'startFreeRoam':
        final start = onFreeRoamRequested;
        if (start == null) {
          return const {
            'ok': false,
            'error': 'Free roam is unavailable on this screen.',
          };
        }
        try {
          await start();
          return const {'ok': true, 'error': null};
        } on Object catch (error) {
          return {
            'ok': false,
            'error': _readableCarPlayError(
              error,
              fallback: 'Could not start free roam.',
            ),
          };
        }
      case 'androidAutoNavigationEvent':
        final event = AndroidAutoNavigationHostEvent.tryParse(call.arguments);
        if (event == null) {
          return const {
            'ok': false,
            'error': 'The Android Auto navigation event is invalid.',
          };
        }
        final handler = onAndroidAutoNavigationHostEvent;
        if (handler == null) {
          return const {
            'ok': false,
            'error': 'Android Auto navigation is unavailable on this screen.',
          };
        }
        try {
          await handler(event);
          return const {'ok': true, 'error': null};
        } on Object catch (error) {
          return {
            'ok': false,
            'error': _readableCarPlayError(
              error,
              fallback: 'Could not apply the Android Auto navigation event.',
            ),
          };
        }
      case 'requestState':
        _lastPublishedAt = null;
        await onStateRequested?.call();
        final viewport = _latestViewport;
        if (viewport != null) {
          // Re-send the style as well as the camera. The native side has just
          // created a new scene even though this Dart bridge is long-lived.
          _publishedMapStyleJson = null;
          await publishViewport(viewport);
        }
    }
  }

  Future<void> publish({
    required RideSession? session,
    required List<RiderLocation> riderLocations,
    required List<RiderRouteAlert> routeAlerts,
    required List<HazardReport> activeHazards,
    ImportedRoute? route,
    String? routeName,
    String? rideState,
    bool followRider = false,
    String? guidanceTitle,
    String? guidanceDetail,
    String? guidanceRoadName,
    double? guidanceDistanceMeters,
    NavigationGuidance? navigationGuidance,
    DistanceUnit? distanceUnit,
    String? localeIdentifier,
    String? groupStatus,
    String? markerStatus,
    CarPlayMarkerStatus? marker,
    CarPlayTecStatus tec = CarPlayTecStatus.absent,
    Set<String> effectiveTecRiderIds = const {},
    CarPlayTecRequest? tecRequest,
    CarPlayRideStart? rideStart,
    CarPlaySurfaceMode surfaceMode = CarPlaySurfaceMode.activeRide,
    bool canPlanRoute = false,
    bool canFreeRoam = false,
    bool showTecStatus = true,
    CarPlayLocalRider? localRider,
    BasemapConfiguration? basemap,
    String? mapStyleJson,
    GeoPoint? localPosition,
    double? localHeadingDegrees,
    double? localSpeedMetersPerSecond,
    bool speedLimitEnabled = false,
    String? speedLimitStatus,
    int? speedLimitMilesPerHour,
    bool speedLimitUnlimited = false,
    bool localSpeedIsAgeing = false,
    RouteProgressGeometry? routeProgress,
    RouteJourneyProgress? journeyProgress,
  }) async {
    final now = _clock();
    // A question addressed to this rider is an event, not a state refresh. It
    // jumps the normal snapshot throttle in both directions: a leader who asks at a
    // fuel stop is standing there waiting, and an alert left on the head unit
    // after the request is answered, expired or superseded is asking a rider to
    // agree to something that is no longer on offer.
    final requestChanged = tecRequest?.requestId != _publishedTecRequestId;
    final rideStartKey = rideStart?.projectionKey;
    final rideStartChanged = rideStartKey != _publishedRideStartKey;
    final surfaceKey =
        '${surfaceMode.name}|$canPlanRoute|$canFreeRoam|$showTecStatus';
    final surfaceChanged = surfaceKey != _publishedSurfaceKey;
    if (!requestChanged &&
        !rideStartChanged &&
        !surfaceChanged &&
        _lastPublishedAt != null &&
        now.difference(_lastPublishedAt!) < _minimumPublishInterval) {
      return;
    }
    final previousPublishedAt = _lastPublishedAt;
    final previousTecRequestId = _publishedTecRequestId;
    final previousRideStartKey = _publishedRideStartKey;
    final previousSurfaceKey = _publishedSurfaceKey;
    final attempt = ++_publishAttempt;
    _lastPublishedAt = now;
    _publishedTecRequestId = tecRequest?.requestId;
    _publishedRideStartKey = rideStartKey;
    _publishedSurfaceKey = surfaceKey;
    final alertsByRider = {
      for (final alert in routeAlerts) alert.riderId: alert,
    };
    final topAlert = _topAlertMessage(routeAlerts, activeHazards);
    final snapshot = {
      'routeId': route?.id,
      'routeName': routeName,
      'routePoints': _projectRoute(route),
      'rideState': rideState,
      'surfaceMode': surfaceMode.name,
      'canPlanRoute': canPlanRoute,
      'canFreeRoam': canFreeRoam,
      // Before the leader starts, the phone frames the complete route so the
      // group can review it. Once underway it changes to the forward-looking
      // rider camera. CarPlay needs that state explicitly; the presence of a
      // local fix alone cannot distinguish those two map views.
      'followRider': followRider,
      'routeProgressMeters': routeProgress?.progressMeters,
      'routeTotalMeters': routeProgress?.totalMeters,
      'remainingRoutePoints': _projectProgressPath(
        routeProgress?.remainingPaths,
      ),
      'riddenRoutePoints': _projectProgressPath(routeProgress?.riddenPaths),
      'journeyProgress': journeyProgress?.toSnapshot(),
      'carplayNavigation': projectCarPlayNavigationV2(
        sourceId: _projectionSourceId,
        sequence: attempt,
        generatedAt: now,
        ridePhase: surfaceMode.name,
        route: route,
        guidance: navigationGuidance,
        distanceUnit: distanceUnit,
        localeIdentifier: localeIdentifier,
        speedMetersPerSecond: localSpeedMetersPerSecond,
        journeyProgress: journeyProgress,
      ),
      'androidAutoNavigation': projectAndroidAutoNavigationV2(
        sourceId: _projectionSourceId,
        sequence: attempt,
        generatedAt: now,
        ridePhase: surfaceMode.name,
        route: route,
        guidance: navigationGuidance,
        distanceUnit: distanceUnit,
        localeIdentifier: localeIdentifier,
        speedMetersPerSecond: localSpeedMetersPerSecond,
        journeyProgress: journeyProgress,
        routeProgress: routeProgress,
        followRider: followRider,
        canPlanRoute: canPlanRoute,
        canFreeRoam: canFreeRoam,
        canStartPreparedRide: rideStart?.enabled == true,
        alert: topAlert,
      ),
      'guidanceTitle': guidanceTitle,
      'guidanceDetail': guidanceDetail,
      'guidanceRoadName': guidanceRoadName,
      'guidanceDistanceMeters': guidanceDistanceMeters,
      // Computed here rather than in Swift, and independent of the speed-limit
      // opt-in: that gate exists so a rider who did not ask for a speed readout
      // does not get one, and an estimate of time to the next turn is not a
      // speed readout (#452).
      'guidanceSecondsRemaining': guidanceSecondsRemaining(
        distanceMeters: guidanceDistanceMeters,
        speedMetersPerSecond: localSpeedMetersPerSecond,
      ),
      'distanceUnit': distanceUnit?.name,
      'groupStatus': groupStatus,
      'markerStatus': markerStatus,
      'marker': marker?.toSnapshot(),
      'tec': showTecStatus ? tec.toSnapshot() : null,
      'tecRequest': tecRequest?.toSnapshot(),
      'rideStart': rideStart?.toSnapshot(),
      'speed': !speedLimitEnabled
          ? null
          : {
              'metresPerSecond': localSpeedMetersPerSecond,
              'isAgeing': localSpeedIsAgeing,
              'limitStatus': speedLimitStatus,
              'limitMilesPerHour': speedLimitMilesPerHour,
              'limitUnlimited': speedLimitUnlimited,
            },
      // The head unit draws with the same MapLibre styles as the phone, and
      // shares its tile cache, so it keeps a basemap through a signal drop
      // instead of going grey (#321). The selected URL makes the car match the
      // phone; both URLs remain as safe fallbacks before that selection arrives.
      'basemap': basemap == null
          ? null
          : {
              'styleUrl': basemap.styleUrl,
              'darkStyleUrl': basemap.darkStyleUrl.isEmpty
                  ? basemap.styleUrl
                  : basemap.darkStyleUrl,
              'selectedStyleUrl': basemap.styleUrl,
              'dark': basemap.dark,
              if (mapStyleJson != null && mapStyleJson.isNotEmpty)
                'styleJson': mapStyleJson,
            },
      if (localPosition != null)
        'localPosition': {
          'latitude': localPosition.latitude,
          'longitude': localPosition.longitude,
          'headingDegrees': localHeadingDegrees,
        },
      if ((localRider != null || session != null) && localPosition != null)
        'localRider': {
          'riderId': localRider?.riderId ?? session!.localRiderId,
          'label': localRider?.displayName ?? session!.displayName,
          'isLocal': true,
          'role': localRider?.roleLabel ?? session!.role.label,
          'riderSymbol':
              localRider?.riderSymbol.storageValue ??
              session!.riderSymbol.storageValue,
          'motorcycleStyle':
              localRider?.motorcycleStyle.name ?? session!.motorcycleStyle.name,
          'riderColor': localRider?.riderColor.name ?? session!.riderColor.name,
          'latitude': localPosition.latitude,
          'longitude': localPosition.longitude,
          'headingDegrees': localHeadingDegrees,
        },
      'updatedAtMillis': now.millisecondsSinceEpoch,
      'riders': [
        for (final location in riderLocations)
          {
            'riderId': location.riderId,
            'label': location.displayName,
            'isLocal':
                session != null && location.riderId == session.localRiderId,
            'role': _roleLabel(location, effectiveTecRiderIds),
            // Project the same identity the rider chose on the phone. CarPlay
            // used to replace the local rider with a blue "You" pill and every
            // peer with a role-coloured initial, so the two screens described
            // the same group with different people.
            'riderSymbol': location.riderSymbol.storageValue,
            'motorcycleStyle': location.motorcycleStyle.name,
            'riderColor': location.riderColor.name,
            // Issue #128: two riders can hold the role at once, and the group
            // needs one answer. The phone map resolves that before it draws a
            // marker; the head unit now resolves it the same way rather than
            // labelling both of them the back of the group.
            'isTec': effectiveTecRiderIds.contains(location.riderId),
            'needsAttention': _needsAttention(location, alertsByRider),
            'latitude': location.sample.position.latitude,
            'longitude': location.sample.position.longitude,
            'headingDegrees': location.sample.headingDegrees,
          },
      ],
      'alert': topAlert,
    };
    try {
      await _channel.invokeMethod('updateSnapshot', snapshot);
    } on Object catch (error) {
      // CarPlay may not be connected, or the plugin unavailable in tests;
      // restore the throttle state so the next ride-state change retries. A
      // newer publish owns the state if one completed while this call waited.
      if (_publishAttempt == attempt) {
        _lastPublishedAt = previousPublishedAt;
        _publishedTecRequestId = previousTecRequestId;
        _publishedRideStartKey = previousRideStartKey;
        _publishedSurfaceKey = previousSurfaceKey;
      }
      if (kDebugMode) debugPrint('Could not publish CarPlay snapshot: $error');
    }
  }

  Future<void> dispose() async {
    if (identical(_methodHandlerOwner, this)) {
      _methodHandlerOwner = null;
      _channel.setMethodCallHandler(null);
    }
  }

  /// Sends the phone map's actual navigation viewport without rebuilding the
  /// heavier route/rider snapshot. The phone already throttles camera commands
  /// to 400 ms, so adding another timer here would only reintroduce visible lag.
  Future<void> publishViewport(NavigationCameraViewport viewport) async {
    _latestViewport = viewport;
    try {
      await publishMapStyle(
        styleJson: viewport.mapStyleJson,
        fallbackStyleUrl: viewport.mapStyleUrl,
      );
      await _channel.invokeMethod('updateViewport', {
        'latitude': viewport.latitude,
        'longitude': viewport.longitude,
        'zoom': viewport.zoom,
        'tilt': viewport.tilt,
        'bearing': viewport.bearing,
        'sourceViewportHeightPixels': viewport.sourceViewportHeightPixels,
        'sourceViewportWidthPixels': viewport.sourceViewportWidthPixels,
        'riderViewportFraction': viewport.riderViewportFraction,
        'riderHorizontalViewportFraction':
            viewport.riderHorizontalViewportFraction,
        'leftHandTraffic': viewport.leftHandTraffic,
        'mapStyleUrl': viewport.mapStyleUrl,
      });
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not publish CarPlay viewport: $error');
    }
  }

  /// Publishes the resolved phone style as soon as map dependencies open.
  ///
  /// Navigation viewports do not exist before a ride starts or after the
  /// final turn. Keeping style delivery independent means CarPlay still
  /// matches the phone in both of those stationary states.
  Future<void> publishMapStyle({
    required String styleJson,
    required String fallbackStyleUrl,
  }) async {
    if (styleJson.isEmpty || styleJson == _publishedMapStyleJson) return;
    try {
      await _channel.invokeMethod('updateMapStyle', {
        'styleJson': styleJson,
        'fallbackStyleUrl': fallbackStyleUrl,
      });
      _publishedMapStyleJson = styleJson;
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not publish CarPlay map style: $error');
    }
  }

  String? _publishedMapStyleJson;
  NavigationCameraViewport? _latestViewport;

  List<Map<String, double>> _projectProgressPath(List<List<GeoPoint>>? paths) {
    if (paths == null || paths.isEmpty) return const [];
    final viable = paths.where((path) => path.length >= 2);
    if (viable.isEmpty) return const [];
    final primary = viable.reduce((first, second) {
      return _pointPathLength(second) > _pointPathLength(first)
          ? second
          : first;
    });
    return _projectPoints(primary);
  }

  /// CarPlay needs enough geometry to draw the complete route, but sending a
  /// multi-thousand-point GPX file through a platform channel on every live
  /// update is unnecessary. Use the longest path (the same primary-path rule
  /// as live guidance) and retain its endpoints while bounding the payload.
  List<Map<String, double>> _projectRoute(ImportedRoute? route) {
    if (route == null || route.paths.isEmpty) return const [];
    final primary = route.paths.reduce((first, second) {
      return _pathLength(second) > _pathLength(first) ? second : first;
    });
    return _projectPoints(primary.points);
  }

  List<Map<String, double>> _projectPoints(List<GeoPoint> points) {
    const maximumPoints = 600;
    if (points.length <= maximumPoints) {
      return [
        for (final point in points)
          {'latitude': point.latitude, 'longitude': point.longitude},
      ];
    }

    final lastIndex = points.length - 1;
    return [
      for (
        var projectedIndex = 0;
        projectedIndex < maximumPoints;
        projectedIndex += 1
      )
        {
          'latitude':
              points[(projectedIndex * lastIndex / (maximumPoints - 1)).round()]
                  .latitude,
          'longitude':
              points[(projectedIndex * lastIndex / (maximumPoints - 1)).round()]
                  .longitude,
        },
    ];
  }

  double _pathLength(RoutePath path) {
    return _pointPathLength(path.points);
  }

  double _pointPathLength(List<GeoPoint> points) {
    var length = 0.0;
    for (var index = 1; index < points.length; index += 1) {
      length += _importedPointDistance(points[index - 1], points[index]);
    }
    return length;
  }

  double _importedPointDistance(GeoPoint first, GeoPoint second) {
    const earthRadiusMeters = 6371008.8;
    final firstLatitude = first.latitude * math.pi / 180;
    final secondLatitude = second.latitude * math.pi / 180;
    final latitudeDelta = secondLatitude - firstLatitude;
    final longitudeDelta = (second.longitude - first.longitude) * math.pi / 180;
    final haversine =
        math.pow(math.sin(latitudeDelta / 2), 2) +
        math.cos(firstLatitude) *
            math.cos(secondLatitude) *
            math.pow(math.sin(longitudeDelta / 2), 2);
    return earthRadiusMeters *
        2 *
        math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
  }

  /// The role a head unit shows against one rider.
  ///
  /// Every role but the back-marker is the rider's own journal role. The TEC is
  /// the exception: two riders can legitimately carry
  /// [RideRole.tailEndCharlie] at once - one self-selected, one asked by the
  /// leader (#128) - and a car screen listing both as the back of the group
  /// tells the leader something that is not true. Only the effective
  /// back-marker keeps the label, which is what the phone's map already draws.
  ///
  /// An empty [effectiveTecRiderIds] means the caller did not resolve one, not
  /// that nobody holds the role, so the journal role stands.
  String _roleLabel(RiderLocation location, Set<String> effectiveTecRiderIds) {
    if (location.role != RideRole.tailEndCharlie ||
        effectiveTecRiderIds.isEmpty) {
      return location.role.label;
    }
    return effectiveTecRiderIds.contains(location.riderId)
        ? RideRole.tailEndCharlie.label
        : RideRole.rider.label;
  }

  bool _needsAttention(
    RiderLocation location,
    Map<String, RiderRouteAlert> alertsByRider,
  ) {
    final alert = alertsByRider[location.riderId];
    return alert != null &&
        alert.assessment.alertLevel.index >= RouteAlertLevel.urgent.index;
  }

  Map<String, Object?>? _topAlertMessage(
    List<RiderRouteAlert> routeAlerts,
    List<HazardReport> activeHazards,
  ) {
    final alert = routeAlerts.isEmpty ? null : routeAlerts.first;
    final hazard = activeHazards.isEmpty ? null : activeHazards.first;
    if (alert == null && hazard == null) return null;
    final alertSeverity = alert?.assessment.alertLevel.index ?? -1;
    final hazardSeverity = hazard == null
        ? -1
        : hazard.severity.index + RouteAlertLevel.values.length;
    if (hazardSeverity > alertSeverity) {
      return {
        'message': '${hazard!.type.label}: ${hazard.severity.label}',
        'severity': hazard.severity.name,
      };
    }
    return {
      'message': alert!.assessment.message,
      'severity': alert.assessment.alertLevel.name,
    };
  }
}

/// A leader-owned ride that has already been configured on the phone and can
/// therefore be started without moving route or group setup onto CarPlay.
class CarPlayRideStart {
  const CarPlayRideStart({
    required this.enabled,
    required this.detail,
    this.warning,
    this.unavailableReason,
  });

  final bool enabled;
  final String detail;
  final String? warning;
  final String? unavailableReason;

  static CarPlayRideStart? project({
    required bool hasSession,
    required bool isLeader,
    required bool rideStarted,
    required bool rideEnded,
    required bool busy,
    required bool locationReady,
    required bool isGroup,
    required bool hasTec,
    String? routeName,
  }) {
    if (!hasSession || !isLeader || rideStarted || rideEnded) return null;
    return CarPlayRideStart(
      enabled: !busy && locationReady,
      detail: routeName == null
          ? 'No route selected. Recording and group location sharing will start.'
          : '$routeName. Recording, sharing and navigation will start.',
      warning: isGroup && !hasTec
          ? 'No Tail End Charlie is assigned. The group can still start, but '
                'nobody is explicitly covering the back.'
          : null,
      unavailableReason: locationReady
          ? (busy ? 'Ride setup is still being saved.' : null)
          : 'Allow location access on the iPhone before starting from CarPlay.',
    );
  }

  String get projectionKey =>
      '$enabled|$detail|${warning ?? ''}|${unavailableReason ?? ''}';

  Map<String, Object?> toSnapshot() => {
    'enabled': enabled,
    'detail': detail,
    'warning': warning,
    'unavailableReason': unavailableReason,
  };
}

/// The phone's second-bike drop-off card, projected into CarPlay's turn card.
///
/// The free-form [instruction] remains in `markerStatus` for the status list
/// and Android Auto. This structured form lets CarPlay preserve the phone's
/// short headline and glanceable progress instead of treating marker mode as
/// ordinary route navigation.
class CarPlayMarkerStatus {
  const CarPlayMarkerStatus({
    required this.stage,
    required this.title,
    required this.detail,
    required this.ridersPassed,
    required this.ridersExpected,
    this.tecDistanceMeters,
  });

  final String stage;
  final String title;
  final String detail;
  final int ridersPassed;
  final int ridersExpected;
  final double? tecDistanceMeters;

  Map<String, Object?> toSnapshot() => {
    'stage': stage,
    'title': title,
    'detail': detail,
    'ridersPassed': ridersPassed,
    'ridersExpected': ridersExpected,
    'tecDistanceMeters': tecDistanceMeters,
  };
}
