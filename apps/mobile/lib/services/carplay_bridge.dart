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
/// Renders as a `CPListTemplate` (rider name/role/alert-status rows), not a
/// native map: `CPMapTemplate` requires Apple's manually-granted CarPlay
/// Navigation entitlement, which Simulator ad-hoc builds don't carry -
/// without it, CPMapTemplate crashes Apple's own internal chrome code on
/// load (confirmed via the CarPlayTemplateUIHost crash report). A list needs
/// no such entitlement.
///
/// One bidirectional method channel rather than a channel pair: unlike the
/// nearby transport (native is the continuous data source there, so it uses
/// an `EventChannel`), Dart is the frequent source here - it calls
/// `updateSnapshot` on every ride-state change - and native only pushes back
/// the occasional `triggerEmergency` call.
class CarPlayBridge {
  CarPlayBridge({this.onEmergencyTriggered})
    : _channel = const MethodChannel('me.osholt.ride_relay/carplay') {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final MethodChannel _channel;
  final Future<void> Function()? onEmergencyTriggered;
  DateTime? _lastPublishedAt;

  /// CarPlay is a glanceable secondary display, not a live map that needs
  /// every simulation tick (~200ms during Ride Lab) - publishing that often
  /// visibly loaded down the CarPlay Simulator's own relay daemon. A call
  /// always arrives again well within this interval during an active ride,
  /// so simply dropping over-frequent calls (rather than coalescing a
  /// trailing one) still keeps CarPlay within a second of current state.
  static const _minPublishInterval = Duration(seconds: 1);

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
    final now = DateTime.now();
    if (_lastPublishedAt != null &&
        now.difference(_lastPublishedAt!) < _minPublishInterval) {
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
