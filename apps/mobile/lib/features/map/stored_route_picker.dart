import 'package:flutter/material.dart';

import '../../domain/completed_ride.dart';
import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/measurement_formatter.dart';
import '../../services/approximate_place_index.dart';
import '../../services/ride_library_backup.dart';
import '../../services/stored_route_library.dart';
import '../ride/route_sketch.dart';
import 'route_review_screen.dart' show routeLengthMeters;

/// Picks a route out of the geometry already on this phone.
///
/// This exists so the data the app already holds is a route source in its own
/// right. A rider who has just ridden a route, or deliberately recorded one, no
/// longer has to export a GPX and import it back to ride it again (#155).
///
/// It hands back a [StoredRouteSelection] and nothing else: building geometry
/// and activating a route stay with the map, which owns the route pipeline.
class StoredRoutePickerScreen extends StatefulWidget {
  const StoredRoutePickerScreen({
    super.key,
    required this.library,
    required this.distanceUnit,
    this.openPreviousRide,
  });

  final StoredRouteLibrary library;
  final DistanceUnit distanceUnit;
  final Future<StoredRouteSelection?> Function(
    BuildContext context,
    CompletedRide ride,
  )?
  openPreviousRide;

  static Future<StoredRouteSelection?> show(
    BuildContext context, {
    required StoredRouteLibrary library,
    required DistanceUnit distanceUnit,
    Future<StoredRouteSelection?> Function(
      BuildContext context,
      CompletedRide ride,
    )?
    openPreviousRide,
  }) => Navigator.of(context).push<StoredRouteSelection>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => StoredRoutePickerScreen(
        library: library,
        distanceUnit: distanceUnit,
        openPreviousRide: openPreviousRide,
      ),
    ),
  );

  @override
  State<StoredRoutePickerScreen> createState() =>
      _StoredRoutePickerScreenState();
}

class _StoredRoutePickerScreenState extends State<StoredRoutePickerScreen> {
  late Future<_StoredRoutePickerData> _data = _load();
  bool _backupBusy = false;

  Future<_StoredRoutePickerData> _load() async {
    final candidates = await widget.library.list();
    final rides = widget.openPreviousRide == null
        ? const <CompletedRide>[]
        : await widget.library.completedRides.list();
    if (candidates.isEmpty && rides.isEmpty) {
      return _StoredRoutePickerData(
        candidates: candidates,
        rides: rides,
        places: null,
      );
    }
    return _StoredRoutePickerData(
      candidates: candidates,
      rides: rides,
      places:
          widget.library.approximatePlaceIndex ??
          await ApproximatePlaceIndex.load(),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Ride library'),
      actions: [
        if (widget.openPreviousRide != null)
          PopupMenuButton<_RideLibraryAction>(
            tooltip: 'Back up or restore Ride Library',
            enabled: !_backupBusy,
            onSelected: _handleLibraryAction,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _RideLibraryAction.backup,
                child: Text('Back up Ride Library'),
              ),
              PopupMenuItem(
                value: _RideLibraryAction.restore,
                child: Text('Restore from backup'),
              ),
            ],
          ),
      ],
    ),
    body: FutureBuilder<_StoredRoutePickerData>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            title: 'Could not read saved routes',
            body: '${snapshot.error}',
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final candidates = data.candidates;
        if (candidates.isEmpty && data.rides.isEmpty) {
          return const _EmptyLibrary();
        }
        final places = data.places!;
        final recordings = candidates
            .where(
              (candidate) =>
                  candidate.origin == StoredRouteOrigin.recordedRoute,
            )
            .toList(growable: false);
        final routeCandidatesFromRides = candidates
            .where(
              (candidate) =>
                  candidate.origin != StoredRouteOrigin.recordedRoute,
            )
            .toList(growable: false);
        final rides = data.rides
            .where((ride) => ride.libraryStatus == RideLibraryStatus.active)
            .toList(growable: false);
        final archived = data.rides
            .where((ride) => ride.libraryStatus == RideLibraryStatus.archived)
            .toList(growable: false);
        final deleted = data.rides
            .where((ride) => ride.libraryStatus == RideLibraryStatus.deleted)
            .toList(growable: false);
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          children: [
            const Text(
              'Routes already on this phone. No file, no export step, and '
              'nothing leaves the phone to use one. Approximate place names '
              'come from the offline index.',
              style: TextStyle(color: Color(0xFFABB5C1), height: 1.4),
            ),
            if (recordings.isNotEmpty) ...[
              const _SectionHeading('Recorded routes'),
              for (final candidate in recordings) _tile(candidate, places),
            ],
            if (widget.openPreviousRide == null &&
                routeCandidatesFromRides.isNotEmpty) ...[
              const _SectionHeading('Previous rides'),
              for (final candidate in routeCandidatesFromRides)
                _tile(candidate, places),
            ],
            if (widget.openPreviousRide != null && rides.isNotEmpty) ...[
              const _SectionHeading('Previous rides'),
              for (final ride in rides) _rideTile(ride, places),
            ],
            if (widget.openPreviousRide != null && archived.isNotEmpty) ...[
              const _SectionHeading('Archived'),
              for (final ride in archived) _rideTile(ride, places),
            ],
            if (widget.openPreviousRide != null && deleted.isNotEmpty) ...[
              const _SectionHeading('Recently deleted'),
              for (final ride in deleted) _rideTile(ride, places),
            ],
            if (candidates.isNotEmpty || data.rides.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                places.attribution,
                style: const TextStyle(color: Color(0xFF778391), fontSize: 11),
              ),
            ],
          ],
        );
      },
    ),
  );

  Widget _tile(StoredRouteCandidate candidate, ApproximatePlaceIndex places) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: StoredRouteCandidateTile(
          candidate: candidate,
          endpointLabel: approximateEndpointLabel(
            index: places,
            start: candidate.startPoint,
            end: candidate.endPoint,
          ),
          distanceUnit: widget.distanceUnit,
          onTap: () => _chooseOptions(candidate),
        ),
      );

  Widget _rideTile(CompletedRide ride, ApproximatePlaceIndex places) {
    final geometry = ride.traveledRoute ?? ride.plannedRoute;
    final candidate = geometry == null
        ? null
        : StoredRouteCandidate(
            id: 'ride-record:${ride.rideId}',
            origin: ride.traveledRoute != null
                ? StoredRouteOrigin.previousRideTrack
                : StoredRouteOrigin.previousRidePlan,
            title: ride.title,
            storedAt: ride.startedAt,
            geometry: geometry,
            rideCode: ride.rideCode,
          );
    final endpointLabel = candidate == null
        ? 'No route geometry recorded'
        : approximateEndpointLabel(
            index: places,
            start: candidate.startPoint,
            end: candidate.endPoint,
          );
    final rating = ride.rating == null ? '' : ' · ${'★' * ride.rating!}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          key: Key('ride-library-record-${ride.rideId}'),
          contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          leading: SizedBox.square(
            dimension: 52,
            child: candidate == null
                ? const Icon(Icons.two_wheeler)
                : StoredRouteShapePreview(candidate: candidate),
          ),
          title: Text(ride.title),
          subtitle: Text(
            '$endpointLabel\n${_date(ride.startedAt)} · '
            '${MeasurementFormatter(widget.distanceUnit).distance(ride.totalDistanceMeters)} · '
            '${ride.riderCount} rider${ride.riderCount == 1 ? '' : 's'}$rating',
          ),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openRide(ride),
        ),
      ),
    );
  }

  Future<void> _chooseOptions(StoredRouteCandidate candidate) async {
    final selection = await showModalBottomSheet<StoredRouteSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StoredRouteOptionsSheet(
        candidate: candidate,
        distanceUnit: widget.distanceUnit,
      ),
    );
    if (selection == null || !mounted) return;
    Navigator.of(context).pop(selection);
  }

  Future<void> _openRide(CompletedRide ride) async {
    final selection = await widget.openPreviousRide!(context, ride);
    if (!mounted) return;
    if (selection != null) {
      Navigator.of(context).pop(selection);
      return;
    }
    await _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _data = _load();
    });
    await _data;
  }

  Future<void> _handleLibraryAction(_RideLibraryAction action) async {
    final backup = RideLibraryBackupService(
      completedRides: widget.library.completedRides,
      recordedRoutes: widget.library.recordedRoutes,
    );
    setState(() => _backupBusy = true);
    try {
      switch (action) {
        case _RideLibraryAction.backup:
          final box = context.findRenderObject();
          final origin = box is RenderBox && box.hasSize
              ? box.localToGlobal(Offset.zero) & box.size
              : null;
          await backup.share(sharePositionOrigin: origin);
        case _RideLibraryAction.restore:
          final result = await backup.restoreFromPicker();
          if (result == null || !mounted) return;
          await _reload();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Restored ${result.completedRideCount} rides and '
                '${result.recordedRouteCount} recorded routes.',
              ),
            ),
          );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update Ride Library: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }
}

enum _RideLibraryAction { backup, restore }

/// One choosable stored route: its shape, what it is, when it was ridden and
/// how far it goes. A list of dates is not choosable.
class StoredRouteCandidateTile extends StatelessWidget {
  const StoredRouteCandidateTile({
    super.key,
    required this.candidate,
    this.endpointLabel,
    required this.distanceUnit,
    required this.onTap,
  });

  final StoredRouteCandidate candidate;
  final String? endpointLabel;
  final DistanceUnit distanceUnit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: Key('stored-route-candidate-${candidate.id}'),
      contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      leading: SizedBox.square(
        dimension: 52,
        child: StoredRouteShapePreview(candidate: candidate),
      ),
      title: Text(candidate.title),
      subtitle: Text(
        '${endpointLabel == null ? '' : '$endpointLabel\n'}'
        '${storedRouteKindLabel(candidate.origin)} · '
        '${_date(candidate.storedAt)}\n'
        '${MeasurementFormatter(distanceUnit).distance(routeLengthMeters(candidate.geometry))} · '
        '${candidate.pointCount} points'
        '${candidate.rideCode == null ? '' : ' · ride ${candidate.rideCode}'}',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class _StoredRoutePickerData {
  const _StoredRoutePickerData({
    required this.candidates,
    required this.rides,
    required this.places,
  });

  final List<StoredRouteCandidate> candidates;
  final List<CompletedRide> rides;
  final ApproximatePlaceIndex? places;
}

/// A map-free thumbnail of the route's shape, drawn from the geometry already
/// in memory. Cheap enough for a list: no tiles, no network, and a subsample
/// rather than every recorded fix.
class StoredRouteShapePreview extends StatelessWidget {
  const StoredRouteShapePreview({super.key, required this.candidate});

  static const _maximumPreviewPoints = 120;

  final StoredRouteCandidate candidate;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: RouteSketchPainter(
      normalizeRoutePoints(_points()),
      strokeWidth: 2.5,
    ),
    child: const SizedBox.expand(),
  );

  List<GeoPoint> _points() {
    final longest = candidate.geometry.paths.fold<List<GeoPoint>>(
      const [],
      (best, path) => path.points.length > best.length ? path.points : best,
    );
    if (longest.length <= _maximumPreviewPoints) return longest;
    return List.generate(
      _maximumPreviewPoints,
      (index) =>
          longest[(index * (longest.length - 1) / (_maximumPreviewPoints - 1))
              .round()],
      growable: false,
    );
  }
}

/// States plainly which version of a recording the rider is about to ride, and
/// which direction it runs in.
class StoredRouteOptionsSheet extends StatefulWidget {
  const StoredRouteOptionsSheet({
    super.key,
    required this.candidate,
    required this.distanceUnit,
  });

  final StoredRouteCandidate candidate;
  final DistanceUnit distanceUnit;

  @override
  State<StoredRouteOptionsSheet> createState() =>
      _StoredRouteOptionsSheetState();
}

class _StoredRouteOptionsSheetState extends State<StoredRouteOptionsSheet> {
  StoredRouteVariant _variant = StoredRouteVariant.tidied;
  bool _reversed = false;

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              candidate.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '${storedRouteKindLabel(candidate.origin)} · '
              '${_date(candidate.storedAt)} · '
              '${MeasurementFormatter(widget.distanceUnit).distance(routeLengthMeters(candidate.geometry))}',
              style: const TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 16),
            if (candidate.isRecording) ...[
              SegmentedButton<StoredRouteVariant>(
                key: const Key('stored-route-variant'),
                segments: const [
                  ButtonSegment(
                    value: StoredRouteVariant.tidied,
                    label: Text('Tidied'),
                  ),
                  ButtonSegment(
                    value: StoredRouteVariant.raw,
                    label: Text('Raw track'),
                  ),
                ],
                selected: {_variant},
                onSelectionChanged: (selection) =>
                    setState(() => _variant = selection.single),
              ),
              const SizedBox(height: 10),
              Text(
                _variant == StoredRouteVariant.tidied
                    ? 'Tidied: a recording, not a planned route. Stops and GPS '
                          'wander are removed. Every road the bike actually '
                          'took is kept, including any wrong turns and car '
                          'park loops.'
                    : 'Raw track: every fix exactly as recorded, including '
                          'stops, GPS wander and any wrong turns.',
                style: const TextStyle(color: Color(0xFF98A3B1), height: 1.4),
              ),
            ] else
              const Text(
                'This is the route that ride was planned with, so it is used '
                'exactly as it was planned.',
                style: TextStyle(color: Color(0xFF98A3B1), height: 1.4),
              ),
            const SizedBox(height: 6),
            SwitchListTile(
              key: const Key('stored-route-reverse'),
              contentPadding: EdgeInsets.zero,
              value: _reversed,
              onChanged: (value) => setState(() => _reversed = value),
              title: const Text('Ride it in reverse'),
              subtitle: Text(
                _reversed
                    ? 'Runs from the original finish to the original start. '
                          'Turn instructions from the original direction are '
                          'dropped.'
                    : 'Runs in the direction it was ridden.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('use-stored-route'),
              onPressed: () => Navigator.of(context).pop(
                StoredRouteSelection(
                  candidate: candidate,
                  variant: _variant,
                  reversed: _reversed,
                ),
              ),
              icon: const Icon(Icons.route_outlined),
              label: const Text('Use this route'),
            ),
          ],
        ),
      ),
    );
  }
}

String storedRouteKindLabel(StoredRouteOrigin origin) => switch (origin) {
  StoredRouteOrigin.recordedRoute => 'Recorded route',
  StoredRouteOrigin.previousRidePlan => 'Previous ride · planned route',
  StoredRouteOrigin.previousRideTrack => 'Previous ride · recorded track',
};

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10),
    child: Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF8994A2),
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.9,
      ),
    ),
  );
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) => _Message(
    title: 'No saved routes yet',
    body:
        'Record one with "Record a route" on the home screen, or finish a ride '
        'and it will appear here. A ride whose geometry has been deleted is '
        'not listed, because there is nothing left to ride.',
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.route_outlined, size: 52, color: Color(0xFF7F8A98)),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFABB5C1), height: 1.4),
          ),
        ],
      ),
    ),
  );
}

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}
