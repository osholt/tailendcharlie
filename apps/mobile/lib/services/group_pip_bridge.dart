import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/imported_route.dart';

enum GroupPipMarkerKind { rider, hazard }

@immutable
class GroupPipMarker {
  const GroupPipMarker({
    required this.point,
    required this.label,
    required this.colourArgb,
    required this.kind,
    this.isLocal = false,
  });

  final GeoPoint point;
  final String label;
  final int colourArgb;
  final GroupPipMarkerKind kind;
  final bool isLocal;

  Map<String, Object?> toJson() => {
    'latitude': point.latitude,
    'longitude': point.longitude,
    'label': label.length <= 40 ? label : label.substring(0, 40),
    'colourArgb': colourArgb,
    'kind': kind.name,
    'isLocal': isLocal,
  };
}

@immutable
class GroupPipSnapshot {
  const GroupPipSnapshot({
    required this.routePaths,
    required this.markers,
    this.status,
    this.alert = false,
  });

  final List<List<GeoPoint>> routePaths;
  final List<GroupPipMarker> markers;
  final String? status;
  final bool alert;

  Map<String, Object?> toJson() => {
    'routePaths': [
      for (final path in _sampleRoutePaths(routePaths, maximumPoints: 500))
        [
          for (final point in path)
            {'latitude': point.latitude, 'longitude': point.longitude},
        ],
    ],
    'markers': [for (final marker in markers.take(100)) marker.toJson()],
    if (status case final value?)
      'status': value.length <= 80 ? value : value.substring(0, 80),
    'alert': alert,
  };
}

/// Drives Android's user-initiated navigation Picture-in-Picture companion.
///
/// The native Activity renders only bounded route/rider primitives. It does
/// not embed Flutter, request an overlay permission, fetch tiles, or imitate
/// video playback. Calls are harmless on iOS and unsupported Android hosts.
class GroupPipBridge {
  GroupPipBridge({@visibleForTesting MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('me.osholt.ride_relay/group_pip');

  final MethodChannel _channel;
  bool _active = false;

  bool get active => _active;

  Future<bool> isSupported() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on Object {
      return false;
    }
  }

  Future<bool> enter(GroupPipSnapshot snapshot) async {
    try {
      final entered = await _channel.invokeMethod<bool>(
        'enter',
        snapshot.toJson(),
      );
      _active = entered == true;
      return _active;
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not open group PiP: $error');
      _active = false;
      return false;
    }
  }

  Future<void> publish(GroupPipSnapshot snapshot) async {
    if (!_active) return;
    try {
      final stillActive = await _channel.invokeMethod<bool>(
        'updateSnapshot',
        snapshot.toJson(),
      );
      _active = stillActive == true;
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not update group PiP: $error');
    }
  }

  Future<void> close() async {
    if (!_active) return;
    try {
      await _channel.invokeMethod<void>('close');
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not close group PiP: $error');
    } finally {
      _active = false;
    }
  }

  Future<void> dispose() => close();
}

List<List<GeoPoint>> _sampleRoutePaths(
  List<List<GeoPoint>> routePaths, {
  required int maximumPoints,
}) {
  final paths = routePaths.where((path) => path.isNotEmpty).take(50).toList();
  if (paths.isEmpty) return const [];
  final perPath = (maximumPoints / paths.length).floor().clamp(
    2,
    maximumPoints,
  );
  return [
    for (final path in paths)
      if (path.length <= perPath)
        path
      else
        _sampleRoute(path, maximumPoints: perPath),
  ];
}

List<GeoPoint> _sampleRoute(List<GeoPoint> path, {required int maximumPoints}) {
  final stride = (path.length / maximumPoints).ceil();
  final sampled = <GeoPoint>[
    for (var index = 0; index < path.length; index += stride) path[index],
  ];
  if (sampled.last != path.last) sampled.add(path.last);
  return sampled;
}
