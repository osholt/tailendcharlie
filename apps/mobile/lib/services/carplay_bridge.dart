import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/hazard.dart';
import '../domain/imported_route.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';

/// Publishes projected ride and navigation state to the native CarPlay and
/// Android Auto scenes, and relays the CarPlay emergency button back to
/// [onEmergencyTriggered].
///
/// CarPlay renders the route and rider positions in its navigation scene and
/// keeps the existing glanceable ride-status list available from that map.
///
/// One bidirectional method channel rather than a channel pair: unlike the
/// nearby transport (native is the continuous data source there, so it uses
/// an `EventChannel`), Dart is the frequent source here - it calls
/// `updateSnapshot` on every ride-state change - and native only pushes back
/// the occasional `triggerEmergency` call.
class CarPlayBridge {
  CarPlayBridge({
    this.onEmergencyTriggered,
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
  DateTime? _lastPublishedAt;

  /// Driving Task templates are deliberately low-frequency, glanceable
  /// surfaces. Active rides supply regular location updates, so dropping
  /// intermediate snapshots keeps the latest rider state flowing without
  /// refreshing the CarPlay list more often than once every ten seconds.

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'triggerEmergency') {
      await onEmergencyTriggered?.call();
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
  }) async {
    final now = _clock();
    if (_lastPublishedAt != null &&
        now.difference(_lastPublishedAt!) < _minimumPublishInterval) {
      return;
    }
    _lastPublishedAt = now;
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
      'updatedAtMillis': now.millisecondsSinceEpoch,
      'riders': [
        for (final location in riderLocations)
          {
            'label': location.displayName,
            'isLocal':
                session != null && location.riderId == session.localRiderId,
            'role': location.role.label,
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
