import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/hazard.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';

/// Publishes a compact ride status (riders, the single highest-priority
/// alert) to the native CarPlay scene, and relays the CarPlay emergency
/// button back to [onEmergencyTriggered].
///
/// Renders as a `CPListTemplate` (rider name/role/alert-status rows) under the
/// app's CarPlay Driving Task entitlement. It is not a native map:
/// `CPMapTemplate` requires Apple's separate CarPlay Navigation entitlement,
/// which this app does not request or carry.
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
      'riders': [
        for (final location in riderLocations)
          {
            'label': location.displayName,
            'isLocal':
                session != null && location.riderId == session.localRiderId,
            'role': location.role.label,
            'needsAttention': _needsAttention(location, alertsByRider),
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
