import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/hazard.dart';
import '../domain/imported_route.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import 'carplay_tec_status.dart';

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
    this.onTecRoleAnswered,
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting
    this._minimumPublishInterval = const Duration(seconds: 10),
  }) : _channel =
           channel ?? const MethodChannel('me.osholt.ride_relay/carplay'),
       _clock = clock ?? DateTime.now {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final MethodChannel _channel;
  final DateTime Function() _clock;
  final Duration _minimumPublishInterval;
  final Future<void> Function()? onEmergencyTriggered;

  /// The rider's answer to a leader's Tail End Charlie request, given on the
  /// head unit (#128).
  final Future<void> Function(String requestId, bool accepted)?
  onTecRoleAnswered;
  DateTime? _lastPublishedAt;

  /// The request the head unit was last told about, so a new one can jump the
  /// throttle and an answered one can take its alert down.
  String? _publishedTecRequestId;

  /// Driving Task templates are deliberately low-frequency, glanceable
  /// surfaces. Active rides supply regular location updates, so dropping
  /// intermediate snapshots keeps the latest rider state flowing without
  /// refreshing the CarPlay list more often than once every ten seconds.

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'triggerEmergency':
        await onEmergencyTriggered?.call();
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
    String? guidanceTitle,
    String? guidanceDetail,
    String? guidanceRoadName,
    double? guidanceDistanceMeters,
    String? groupStatus,
    String? markerStatus,
    CarPlayTecStatus tec = CarPlayTecStatus.absent,
    Set<String> effectiveTecRiderIds = const {},
    CarPlayTecRequest? tecRequest,
  }) async {
    final now = _clock();
    // A question addressed to this rider is an event, not a state refresh. It
    // jumps the ten-second throttle in both directions: a leader who asks at a
    // fuel stop is standing there waiting, and an alert left on the head unit
    // after the request is answered, expired or superseded is asking a rider to
    // agree to something that is no longer on offer.
    final requestChanged = tecRequest?.requestId != _publishedTecRequestId;
    if (!requestChanged &&
        _lastPublishedAt != null &&
        now.difference(_lastPublishedAt!) < _minimumPublishInterval) {
      return;
    }
    _lastPublishedAt = now;
    _publishedTecRequestId = tecRequest?.requestId;
    final alertsByRider = {
      for (final alert in routeAlerts) alert.riderId: alert,
    };
    final snapshot = {
      'routeId': route?.id,
      'routeName': routeName,
      'routePoints': _projectRoute(route),
      'rideState': rideState,
      'guidanceTitle': guidanceTitle,
      'guidanceDetail': guidanceDetail,
      'guidanceRoadName': guidanceRoadName,
      'guidanceDistanceMeters': guidanceDistanceMeters,
      'groupStatus': groupStatus,
      'markerStatus': markerStatus,
      'tec': tec.toSnapshot(),
      'tecRequest': tecRequest?.toSnapshot(),
      'updatedAtMillis': now.millisecondsSinceEpoch,
      'riders': [
        for (final location in riderLocations)
          {
            'label': location.displayName,
            'isLocal':
                session != null && location.riderId == session.localRiderId,
            'role': _roleLabel(location, effectiveTecRiderIds),
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
      'alert': _topAlertMessage(routeAlerts, activeHazards),
    };
    try {
      await _channel.invokeMethod('updateSnapshot', snapshot);
    } on Object catch (error) {
      // CarPlay may not be connected, or the plugin unavailable in tests;
      // the next ride-state change retries.
      if (kDebugMode) debugPrint('Could not publish CarPlay snapshot: $error');
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
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
    const maximumPoints = 600;
    final points = primary.points;
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
    var length = 0.0;
    for (var index = 1; index < path.points.length; index += 1) {
      length += _importedPointDistance(
        path.points[index - 1],
        path.points[index],
      );
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
