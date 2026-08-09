import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../map/map_camera_guard.dart';

import '../../controllers/completed_rides_controller.dart';
import '../../controllers/distance_unit_controller.dart';
import '../../domain/completed_ride.dart';
import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/completed_ride_sharer.dart';
import '../../services/map_geojson.dart';
import '../../services/map_style_repository.dart';
import '../../services/measurement_formatter.dart';
import '../../services/ride_summary_exporter.dart';
import '../../services/stored_route_library.dart';
import '../map/resolved_route_map_preview.dart'
    show embeddedMapGestureRecognizers;
import '../map/stored_route_picker.dart';
import 'ride_recap_screen.dart';

class PreviousRidesScreen extends StatelessWidget {
  const PreviousRidesScreen({
    super.key,
    required this.completedRides,
    required this.distanceUnits,
  });

  final CompletedRidesController completedRides;
  final DistanceUnitController distanceUnits;

  static Future<StoredRouteSelection?> show(
    BuildContext context,
    CompletedRidesController completedRides,
    DistanceUnitController distanceUnits,
  ) => Navigator.of(context).push<StoredRouteSelection>(
    MaterialPageRoute<StoredRouteSelection>(
      builder: (_) => PreviousRidesScreen(
        completedRides: completedRides,
        distanceUnits: distanceUnits,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Previous rides')),
    body: AnimatedBuilder(
      animation: completedRides,
      builder: (context, _) {
        final rides = completedRides.rides;
        if (rides.isEmpty) {
          return const _EmptyArchive();
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
          itemCount: rides.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'These records stay on this phone until you delete them. '
                  'Exported files are saved wherever you choose in the native '
                  'share sheet.',
                  style: TextStyle(color: Color(0xFFABB5C1), height: 1.4),
                ),
              );
            }
            final ride = rides[index - 1];
            return _RideTile(
              ride: ride,
              distance: MeasurementFormatter(
                distanceUnits.value,
              ).distance(ride.totalDistanceMeters),
              onTap: () async {
                final selection = await Navigator.of(context).push(
                  MaterialPageRoute<StoredRouteSelection>(
                    builder: (_) => PreviousRideDetailScreen(
                      ride: ride,
                      completedRides: completedRides,
                      distanceUnits: distanceUnits,
                    ),
                  ),
                );
                if (selection != null && context.mounted) {
                  Navigator.of(context).pop(selection);
                }
              },
            );
          },
        );
      },
    ),
  );
}

class _EmptyArchive extends StatelessWidget {
  const _EmptyArchive();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.route_outlined, size: 52, color: Color(0xFF7F8A98)),
          SizedBox(height: 16),
          Text(
            'No previous rides yet',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 8),
          Text(
            'A real ride will appear here after it ends or you leave it.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFABB5C1)),
          ),
        ],
      ),
    ),
  );
}

class _RideTile extends StatelessWidget {
  const _RideTile({
    required this.ride,
    required this.distance,
    required this.onTap,
  });

  final CompletedRide ride;
  final String distance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      leading: const CircleAvatar(child: Icon(Icons.two_wheeler)),
      title: Text(ride.title),
      subtitle: Text(
        '${_date(ride.startedAt)} · $distance · ${ride.riderCount} riders\n'
        '${ride.traveledRoute == null
            ? 'No GPX trail recorded'
            : ride.hasRecordingGaps
            ? 'Recorded trail has location gaps'
            : 'GPX ready'}',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class PreviousRideDetailScreen extends StatefulWidget {
  const PreviousRideDetailScreen({
    super.key,
    required this.ride,
    required this.completedRides,
    required this.distanceUnits,
    this.sharer = const SystemCompletedRideSharer(),
  });

  final CompletedRide ride;
  final CompletedRidesController completedRides;
  final DistanceUnitController distanceUnits;
  final CompletedRideSharer sharer;

  @override
  State<PreviousRideDetailScreen> createState() =>
      _PreviousRideDetailScreenState();
}

class _PreviousRideDetailScreenState extends State<PreviousRideDetailScreen> {
  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    final formatter = MeasurementFormatter(widget.distanceUnits.value);
    return Scaffold(
      appBar: AppBar(
        title: Text(ride.title),
        actions: [
          IconButton(
            tooltip: 'Delete ride',
            onPressed: _confirmDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
        children: [
          SizedBox(
            height: 320,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: ArchivedRideMap(
                plannedRoute: ride.plannedRoute,
                traveledRoute: ride.traveledRoute,
              ),
            ),
          ),
          if (_legendKeys(ride) case final keys when keys.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              key: const Key('archived-ride-legend'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: keys,
            ),
          ],
          const SizedBox(height: 18),
          if (ride.hasRecordingGaps) ...[
            Card(
              key: const Key('archived-ride-recording-gap'),
              color: const Color(0xFF342B17),
              child: const ListTile(
                leading: Icon(Icons.location_disabled_outlined),
                title: Text('This recording has gaps'),
                subtitle: Text(
                  'Location stopped for part of the ride. Missing sections are '
                  'left blank rather than shown as straight lines, and are not '
                  'included in the distance.',
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                runSpacing: 14,
                spacing: 24,
                children: [
                  _Metric(label: 'Date', value: _date(ride.startedAt)),
                  _Metric(label: 'Duration', value: _duration(ride.duration)),
                  _Metric(
                    label: 'Distance',
                    value: formatter.distance(ride.totalDistanceMeters),
                  ),
                  _Metric(label: 'Riders', value: '${ride.riderCount}'),
                  _Metric(label: 'Role', value: ride.localRole.name),
                  _Metric(label: 'Ride code', value: ride.rideCode),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('archived-ride-again'),
            onPressed: ride.plannedRoute == null && ride.traveledRoute == null
                ? null
                : _rideAgain,
            icon: const Icon(Icons.route_outlined),
            label: const Text('Ride again'),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _sharing ? null : () => _shareSummary(),
            icon: const Icon(Icons.ios_share),
            label: const Text('Share summary'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('archived-ride-export-gpx'),
            onPressed: _sharing || ride.traveledRoute == null
                ? null
                : _exportGpx,
            icon: const Icon(Icons.file_upload_outlined),
            label: Text(
              ride.traveledRoute == null
                  ? 'No recorded GPX trail'
                  : 'Export GPX',
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _openRecap,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Share recap image'),
          ),
          const SizedBox(height: 14),
          const Text(
            'Ride history is stored locally on this phone. Tail End Charlie '
            'does not upload a permanent copy. The native share destination '
            'determines where an exported GPX is saved.',
            style: TextStyle(color: Color(0xFF8994A2), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _shareSummary() => _runShare(
    () => widget.sharer.shareSummary(
      widget.ride,
      distanceUnit: widget.distanceUnits.value,
      sharePositionOrigin: _shareOrigin(),
    ),
  );

  Future<void> _rideAgain() async {
    final ride = widget.ride;
    final candidates = <StoredRouteCandidate>[
      if (ride.plannedRoute case final route?)
        StoredRouteCandidate(
          id: 'ride:${ride.rideId}:plan',
          origin: StoredRouteOrigin.previousRidePlan,
          title: ride.title,
          storedAt: ride.startedAt,
          geometry: route,
          rideCode: ride.rideCode,
        ),
      if (ride.traveledRoute case final route?)
        StoredRouteCandidate(
          id: 'ride:${ride.rideId}:track',
          origin: StoredRouteOrigin.previousRideTrack,
          title: ride.title,
          storedAt: ride.startedAt,
          geometry: route,
          rideCode: ride.rideCode,
        ),
    ];
    if (candidates.isEmpty) return;
    // A plan is the default because it describes the intended ride. The track
    // remains an explicit choice where both exist.
    var candidate = candidates.first;
    if (candidates.length > 1) {
      final chosen = await showModalBottomSheet<StoredRouteCandidate>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Which route should be reused?'),
                subtitle: Text(
                  'The planned route is recommended. The recorded track '
                  'includes where the bike actually went.',
                ),
              ),
              for (final option in candidates)
                ListTile(
                  key: Key('ride-again-${option.origin.name}'),
                  leading: Icon(
                    option.origin == StoredRouteOrigin.previousRidePlan
                        ? Icons.route_outlined
                        : Icons.timeline_outlined,
                  ),
                  title: Text(
                    option.origin == StoredRouteOrigin.previousRidePlan
                        ? 'Planned route · recommended'
                        : 'Recorded track',
                  ),
                  onTap: () => Navigator.pop(sheetContext, option),
                ),
            ],
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      candidate = chosen;
    }
    final selection = await showModalBottomSheet<StoredRouteSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StoredRouteOptionsSheet(
        candidate: candidate,
        distanceUnit: widget.distanceUnits.value,
      ),
    );
    if (selection != null && mounted) {
      Navigator.of(context).pop(selection);
    }
  }

  Future<void> _exportGpx() => _runShare(
    () => widget.sharer.exportGpx(
      widget.ride,
      sharePositionOrigin: _shareOrigin(),
    ),
  );

  Future<void> _runShare(Future<void> Function() action) async {
    setState(() => _sharing = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not share: $error')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Rect? _shareOrigin() {
    final renderObject = context.findRenderObject();
    return renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
  }

  Future<void> _openRecap() async {
    final ride = widget.ride;
    final summary = RideSummary(
      rideId: ride.rideId,
      rideCode: ride.rideCode,
      displayName: ride.localDisplayName,
      startedAt: ride.startedAt,
      endedAt: ride.endedAt,
      generatedAt: ride.archivedAt,
      eventCount: ride.eventCount,
      markerSessions: [
        for (final (index, marker) in ride.markerSessions.indexed)
          MarkerSessionSummary(
            markerDeviceId: 'archived-marker-$index',
            startedAt: marker.startedAt,
            endedAt: marker.endedAt,
            uniquePassCount: marker.uniquePassCount,
            duration: (marker.endedAt ?? ride.endedAt)
                .difference(marker.startedAt)
                .abs(),
          ),
      ],
      riderCount: ride.riderCount,
      totalDistanceMeters: ride.totalDistanceMeters,
    );
    await RideRecapScreen.show(
      context,
      // The real configuration, not the empty default: without a style there is
      // no basemap to snapshot and the recap falls back to the outline (#157).
      basemapConfiguration: BasemapConfiguration.fromEnvironment(),
      summary: summary,
      routePoints:
          ride.traveledRoute?.paths.expand((path) => path.points).toList() ??
          ride.plannedRoute?.paths.expand((path) => path.points).toList() ??
          const [],
      distanceUnit: widget.distanceUnits.value,
    );
  }

  static List<Widget> _legendKeys(CompletedRide ride) {
    final legend = archivedRideLegend(ride);
    return [
      if (legend.planned)
        const _Legend(color: Color(0xFFFF7A1A), label: 'Planned route'),
      if (legend.planned && legend.traveled) const SizedBox(width: 18),
      if (legend.traveled)
        const _Legend(color: Color(0xFF42C9E8), label: 'Your recorded trail'),
    ];
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this ride?'),
        content: const Text(
          'Its local summary and recorded geometry will be removed from this '
          'phone. Files you previously exported are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.completedRides.delete(widget.ride.rideId);
    if (mounted) Navigator.of(context).pop();
  }
}

class ArchivedRideMap extends StatefulWidget {
  const ArchivedRideMap({
    super.key,
    required this.plannedRoute,
    required this.traveledRoute,
    this.basemapConfiguration,
    this.mapStyleString,
  });

  final ImportedRoute? plannedRoute;
  final ImportedRoute? traveledRoute;
  final BasemapConfiguration? basemapConfiguration;
  final String? mapStyleString;

  @override
  State<ArchivedRideMap> createState() => _ArchivedRideMapState();
}

class _ArchivedRideMapState extends State<ArchivedRideMap> {
  static const _plannedSource = 'archived-planned-source';
  static const _trackSource = 'archived-track-source';
  ml.MapLibreMapController? _controller;
  late final Future<String> _mapStyle = _resolveMapStyle();

  List<GeoPoint> get _points => [
    ...?widget.plannedRoute?.allPoints,
    ...?widget.traveledRoute?.allPoints,
  ];

  @override
  Widget build(BuildContext context) {
    final points = _points;
    if (points.isEmpty) {
      return const ColoredBox(
        color: Color(0xFF151E28),
        child: Center(child: Text('No route geometry was recorded')),
      );
    }
    final configuration =
        widget.basemapConfiguration ??
        BasemapConfiguration.fromEnvironment().forBrightness(dark: true);
    final first = points.first;
    return FutureBuilder<String>(
      future: _mapStyle,
      builder: (context, snapshot) {
        final style = snapshot.data;
        if (style == null) {
          return const ColoredBox(
            color: Color(0xFF111820),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Stack(
          children: [
            Positioned.fill(
              child: ml.MapLibreMap(
                key: const Key('archived-ride-map'),
                styleString: style,
                initialCameraPosition: ml.CameraPosition(
                  target: ml.LatLng(first.latitude, first.longitude),
                  zoom: points.length == 1 ? 14 : 10,
                ),
                onMapCreated: (controller) => _controller = controller,
                onStyleLoadedCallback: () => unawaited(_prepareStyle()),
                gestureRecognizers: embeddedMapGestureRecognizers,
                logoEnabled: false,
                compassEnabled: true,
                minMaxZoomPreference: ml.MinMaxZoomPreference(
                  3,
                  configuration.maximumNativeZoom.toDouble(),
                ),
              ),
            ),
            const Positioned(
              right: 6,
              bottom: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Color(0xB3000000)),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    'OpenFreeMap · © OSM',
                    style: TextStyle(color: Colors.white, fontSize: 8),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Material(
                color: const Color(0xD9182029),
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('archived-ride-fit-route'),
                  tooltip: 'Fit the whole ride',
                  onPressed: _fit,
                  color: Colors.white,
                  icon: const Icon(Icons.fit_screen),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<String> _resolveMapStyle() async {
    final supplied = widget.mapStyleString;
    if (supplied != null) return supplied;
    final configuration =
        widget.basemapConfiguration ??
        BasemapConfiguration.fromEnvironment().forBrightness(dark: true);
    final repository = await MapStyleRepository.openDefault(configuration);
    try {
      // As in `resolved_route_map_preview.dart`: a history thumbnail has
      // nowhere to report a basemap failure, so the outcome is dropped on
      // purpose rather than overlooked (#281).
      return (await repository.resolve()).style;
    } finally {
      repository.dispose();
    }
  }

  Future<void> _prepareStyle() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.addGeoJsonSource(
        _plannedSource,
        MapGeoJson.route(widget.plannedRoute),
      );
      await controller.addLineLayer(
        _plannedSource,
        'archived-planned-line',
        const ml.LineLayerProperties(
          lineColor: '#FF7A1A',
          lineWidth: 4,
          lineOpacity: 0.8,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(
        _trackSource,
        MapGeoJson.route(widget.traveledRoute),
      );
      await controller.addLineLayer(
        _trackSource,
        'archived-track-line',
        const ml.LineLayerProperties(
          lineColor: '#42C9E8',
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await _fit();
    } on Object {
      // Summary and exports remain usable if a style cannot be loaded.
    }
  }

  Future<void> _fit() async {
    final controller = _controller;
    final points = _points;
    if (controller == null || points.isEmpty) return;
    if (points.length == 1) {
      final only = ml.LatLng(points.single.latitude, points.single.longitude);
      // An archived ride is replayed from stored coordinates, so a bad one
      // outlives the ride that produced it and crashes the screen every time it
      // is opened (#359).
      if (!mapLibreCameraIsUsable(only, zoom: 14)) return;
      await controller.animateCamera(ml.CameraUpdate.newLatLngZoom(only, 14));
      return;
    }
    final bounds = archivedRideBounds(points);
    if (!bounds.isUsableCamera) return;
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        bounds,
        left: 28,
        top: 28,
        right: 28,
        bottom: 28,
      ),
      duration: const Duration(milliseconds: 450),
    );
  }
}

/// Which legend keys the archived-ride map warrants.
///
/// A key is only honest when the line it describes is on the map. A ride started
/// without a route used to show a Planned route key with no orange line under
/// it, which sends the rider hunting for geometry that was never there (#211).
///
/// The `length >= 2` test deliberately mirrors `MapGeoJson.lines`, which is what
/// decides whether a line exists at all; the two have to move together.
@visibleForTesting
({bool planned, bool traveled}) archivedRideLegend(CompletedRide ride) => (
  planned: _hasDrawableLine(ride.plannedRoute),
  traveled: _hasDrawableLine(ride.traveledRoute),
);

bool _hasDrawableLine(ImportedRoute? route) =>
    route?.paths.any((path) => path.points.length >= 2) ?? false;

@visibleForTesting
ml.LatLngBounds archivedRideBounds(List<GeoPoint> points) {
  if (points.isEmpty) {
    throw ArgumentError.value(points, 'points', 'Must not be empty');
  }
  var south = points.first.latitude;
  var north = points.first.latitude;
  var west = points.first.longitude;
  var east = points.first.longitude;
  for (final point in points.skip(1)) {
    south = math.min(south, point.latitude);
    north = math.max(north, point.latitude);
    west = math.min(west, point.longitude);
    east = math.max(east, point.longitude);
  }
  return ml.LatLngBounds(
    southwest: ml.LatLng(south, west),
    northeast: ml.LatLng(north, east),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 18,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 11)),
    ],
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 130,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF8994A2),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}

String _duration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  return hours == 0 ? '${minutes}m' : '${hours}h ${minutes}m';
}
