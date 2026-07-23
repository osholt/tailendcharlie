import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../../controllers/completed_rides_controller.dart';
import '../../controllers/distance_unit_controller.dart';
import '../../domain/completed_ride.dart';
import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/completed_ride_sharer.dart';
import '../../services/map_geojson.dart';
import '../../services/measurement_formatter.dart';
import '../../services/ride_summary_exporter.dart';
import 'ride_recap_screen.dart';

class PreviousRidesScreen extends StatelessWidget {
  const PreviousRidesScreen({
    super.key,
    required this.completedRides,
    required this.distanceUnits,
  });

  final CompletedRidesController completedRides;
  final DistanceUnitController distanceUnits;

  static Future<void> show(
    BuildContext context,
    CompletedRidesController completedRides,
    DistanceUnitController distanceUnits,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
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
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PreviousRideDetailScreen(
                    ride: ride,
                    completedRides: completedRides,
                    distanceUnits: distanceUnits,
                  ),
                ),
              ),
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
        '${ride.traveledRoute == null ? 'No GPX trail recorded' : 'GPX ready'}',
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
          const SizedBox(height: 10),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Legend(color: Color(0xFFFF7A1A), label: 'Planned route'),
              SizedBox(width: 18),
              _Legend(color: Color(0xFF42C9E8), label: 'Your recorded trail'),
            ],
          ),
          const SizedBox(height: 18),
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
      summary: summary,
      routePoints:
          ride.traveledRoute?.paths.expand((path) => path.points).toList() ??
          ride.plannedRoute?.paths.expand((path) => path.points).toList() ??
          const [],
      distanceUnit: widget.distanceUnits.value,
    );
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
  });

  final ImportedRoute? plannedRoute;
  final ImportedRoute? traveledRoute;
  final BasemapConfiguration? basemapConfiguration;

  @override
  State<ArchivedRideMap> createState() => _ArchivedRideMapState();
}

class _ArchivedRideMapState extends State<ArchivedRideMap> {
  static const _plannedSource = 'archived-planned-source';
  static const _trackSource = 'archived-track-source';
  ml.MapLibreMapController? _controller;

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
    return Stack(
      children: [
        Positioned.fill(
          child: ml.MapLibreMap(
            key: const Key('archived-ride-map'),
            styleString: configuration.styleUrl,
            initialCameraPosition: ml.CameraPosition(
              target: ml.LatLng(first.latitude, first.longitude),
              zoom: points.length == 1 ? 14 : 10,
            ),
            onMapCreated: (controller) => _controller = controller,
            onStyleLoadedCallback: () => unawaited(_prepareStyle()),
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
      ],
    );
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
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(points.single.latitude, points.single.longitude),
          14,
        ),
      );
      return;
    }
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        archivedRideBounds(points),
        left: 28,
        top: 28,
        right: 28,
        bottom: 28,
      ),
      duration: const Duration(milliseconds: 450),
    );
  }
}

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
