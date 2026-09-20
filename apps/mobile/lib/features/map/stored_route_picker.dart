import 'package:flutter/material.dart';

import 'ride_library_browser.dart';
import 'route_correction_screen.dart';
import 'cached_route_preview.dart';

import '../../domain/completed_ride.dart';
import '../../domain/distance_unit.dart';
import '../../domain/ride_library_organisation.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/measurement_formatter.dart';
import '../../services/approximate_place_index.dart';
import '../../services/basemap_configuration.dart';
import '../../services/ride_library_backup.dart';
import '../../services/stored_route_library.dart';
import '../ride/route_sketch.dart';
import 'flutter_vector_route_preview.dart';
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
    this.basemapConfiguration = const BasemapConfiguration(),
    this.openPreviousRide,
  });

  final StoredRouteLibrary library;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;
  final Future<StoredRouteSelection?> Function(
    BuildContext context,
    CompletedRide ride,
  )?
  openPreviousRide;

  static Future<StoredRouteSelection?> show(
    BuildContext context, {
    required StoredRouteLibrary library,
    required DistanceUnit distanceUnit,
    BasemapConfiguration? basemapConfiguration,
    Future<StoredRouteSelection?> Function(
      BuildContext context,
      CompletedRide ride,
    )?
    openPreviousRide,
  }) {
    final resolvedBasemap =
        basemapConfiguration ??
        BasemapConfiguration.fromEnvironment().forBrightness(
          dark: MediaQuery.platformBrightnessOf(context) == Brightness.dark,
        );
    return Navigator.of(context).push<StoredRouteSelection>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StoredRoutePickerScreen(
          library: library,
          distanceUnit: distanceUnit,
          basemapConfiguration: resolvedBasemap,
          openPreviousRide: openPreviousRide,
        ),
      ),
    );
  }

  @override
  State<StoredRoutePickerScreen> createState() =>
      _StoredRoutePickerScreenState();
}

class _StoredRoutePickerScreenState extends State<StoredRoutePickerScreen> {
  late Future<_StoredRoutePickerData> _data = _load();
  bool _backupBusy = false;

  Future<_StoredRoutePickerData> _load() async {
    final candidates = await widget.library.list(includeInactive: true);
    final rides = await widget.library.completedRides.list();
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
        final savedRoutes = candidates
            .where(
              (candidate) =>
                  candidate.origin == StoredRouteOrigin.recordedRoute,
            )
            .toList(growable: false);
        final importedRoutes = savedRoutes
            .where(
              (candidate) =>
                  !storedRouteWasRecordedOnDevice(candidate) &&
                  candidate.geometry.libraryStatus == RideLibraryStatus.active,
            )
            .toList(growable: false);
        final recordings = savedRoutes
            .where(
              (candidate) =>
                  storedRouteWasRecordedOnDevice(candidate) &&
                  candidate.geometry.libraryStatus == RideLibraryStatus.active,
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
        return DefaultTabController(
          length: 3,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(key: Key('ride-library-imported-tab'), text: 'Imported'),
                  Tab(key: Key('ride-library-rides-tab'), text: 'Rides'),
                  Tab(key: Key('ride-library-bin-tab'), text: 'Bin'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _routeList(
                      candidates: importedRoutes,
                      places: places,
                      heading: 'Imported routes',
                      emptyTitle: 'No imported routes',
                      emptyBody:
                          'GPX files and routes shared with Tail End Charlie '
                          'will appear here.',
                    ),
                    _rideList(
                      rides: rides,
                      recordings: recordings,
                      archived: archived,
                      places: places,
                    ),
                    _rideList(
                      rides: deleted,
                      recordings: savedRoutes
                          .where(
                            (candidate) =>
                                candidate.geometry.libraryStatus ==
                                RideLibraryStatus.deleted,
                          )
                          .toList(),
                      archived: const [],
                      places: places,
                      bin: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget _routeList({
    required List<StoredRouteCandidate> candidates,
    required ApproximatePlaceIndex places,
    required String heading,
    required String emptyTitle,
    required String emptyBody,
  }) => RideLibraryBrowser(
    key: ValueKey('browser-$heading'),
    distanceUnit: widget.distanceUnit,
    basemap: widget.basemapConfiguration,
    entries: [
      for (final candidate in candidates)
        RideLibraryEntry(
          id: candidate.id,
          title: candidate.title,
          organisation: candidate.geometry.organisation,
          locationLabel: approximateEndpointLabel(
            index: places,
            start: candidate.startPoint,
            end: candidate.endPoint,
          ),
          distanceMeters: routeLengthMeters(candidate.geometry),
          paths: [for (final path in candidate.geometry.paths) path.points],
          open: () => _chooseOptions(candidate),
        ),
    ],
    listBuilder: (ids, filtered) => _routeListBody(
      candidates: candidates
          .where((candidate) => ids.contains(candidate.id))
          .toList(),
      places: places,
      heading: heading,
      emptyTitle: emptyTitle,
      emptyBody: emptyBody,
    ),
  );

  Widget _rideList({
    required List<CompletedRide> rides,
    required List<CompletedRide> archived,
    required List<StoredRouteCandidate> recordings,
    required ApproximatePlaceIndex places,
    bool bin = false,
  }) => RideLibraryBrowser(
    key: ValueKey(bin ? 'browser-bin' : 'browser-previous-rides'),
    distanceUnit: widget.distanceUnit,
    basemap: widget.basemapConfiguration,
    allowRating: true,
    entries: [
      for (final candidate in recordings)
        RideLibraryEntry(
          id: candidate.id,
          title: candidate.title,
          organisation: candidate.geometry.organisation,
          locationLabel: approximateEndpointLabel(
            index: places,
            start: candidate.startPoint,
            end: candidate.endPoint,
          ),
          distanceMeters: routeLengthMeters(candidate.geometry),
          paths: [for (final path in candidate.geometry.paths) path.points],
          open: () => _chooseOptions(candidate),
        ),
      for (final ride in rides)
        RideLibraryEntry(
          id: ride.rideId,
          title: ride.title,
          organisation: ride.organisation,
          rating: ride.rating,
          locationLabel: _rideLocation(ride, places),
          distanceMeters: ride.totalDistanceMeters,
          paths: [
            for (final path
                in (ride.traveledRoute ?? ride.plannedRoute)?.paths ?? [])
              path.points,
          ],
          open: () => _openRide(ride),
        ),
    ],
    listBuilder: (ids, filtered) => _rideListBody(
      rides: rides.where((ride) => ids.contains(ride.rideId)).toList(),
      archived: filtered ? [] : archived,
      recordings: recordings
          .where((candidate) => ids.contains(candidate.id))
          .toList(),
      bin: bin,
      places: places,
    ),
  );

  String _rideLocation(CompletedRide ride, ApproximatePlaceIndex places) {
    final paths = (ride.traveledRoute ?? ride.plannedRoute)?.paths
        .where((path) => path.points.isNotEmpty)
        .toList();
    return approximateEndpointLabel(
      index: places,
      start: paths?.firstOrNull?.points.first,
      end: paths?.lastOrNull?.points.last,
    );
  }

  Widget _routeListBody({
    required List<StoredRouteCandidate> candidates,
    required ApproximatePlaceIndex places,
    required String heading,
    required String emptyTitle,
    required String emptyBody,
  }) => ListView(
    key: PageStorageKey<String>('ride-library-$heading'),
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
    children: [
      if (candidates.isEmpty)
        _InlineEmpty(title: emptyTitle, body: emptyBody)
      else ...[
        _SectionHeading(heading),
        for (final candidate in candidates) _tile(candidate, places),
      ],
      const SizedBox(height: 10),
      Text(
        places.attribution,
        style: const TextStyle(color: Color(0xFF778391), fontSize: 11),
      ),
    ],
  );

  Widget _rideListBody({
    required List<CompletedRide> rides,
    required List<CompletedRide> archived,
    required List<StoredRouteCandidate> recordings,
    required ApproximatePlaceIndex places,
    bool bin = false,
  }) {
    final rows = <({DateTime time, Widget tile})>[
      for (final ride in rides)
        (time: ride.startedAt, tile: _rideTile(ride, places)),
      for (final recording in recordings)
        (time: recording.storedAt, tile: _tile(recording, places)),
    ]..sort((a, b) => b.time.compareTo(a.time));
    return ListView(
      key: PageStorageKey<String>(
        bin ? 'ride-library-bin' : 'ride-library-rides',
      ),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
      children: [
        if (rows.isEmpty && archived.isEmpty)
          _InlineEmpty(
            title: bin ? 'Bin is empty' : 'No recorded rides',
            body: bin
                ? 'Removed rides and GPX files can be restored here.'
                : 'Your rides and recordings appear here when you save them.',
          ),
        if (rows.isNotEmpty) ...[
          _SectionHeading(bin ? 'Bin' : 'Rides'),
          for (final row in rows) row.tile,
        ],
        if (archived.isNotEmpty)
          ExpansionTile(
            title: const Text('Archived'),
            children: [for (final ride in archived) _rideTile(ride, places)],
          ),
        const SizedBox(height: 10),
        Text(
          places.attribution,
          style: const TextStyle(color: Color(0xFF778391), fontSize: 11),
        ),
      ],
    );
  }

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
          basemapConfiguration: widget.basemapConfiguration,
          onTap: () => _chooseOptions(candidate),
          trailing: _entryMenu(
            'route-${candidate.geometry.id}',
            candidate.geometry.libraryStatus,
            (action) => _manageRoute(candidate, action),
          ),
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
            geometry: geometry.withLibraryDetails(
              organisation: ride.organisation,
            ),
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
                : StoredRouteMapPreview(
                    candidate: candidate,
                    basemapConfiguration: widget.basemapConfiguration,
                    interactive: false,
                  ),
          ),
          title: Text(ride.title),
          subtitle: Text(
            '$endpointLabel\n${_date(ride.startedAt)} · '
            '${MeasurementFormatter(widget.distanceUnit).distance(ride.totalDistanceMeters)} · '
            '${ride.riderCount} rider${ride.riderCount == 1 ? '' : 's'}$rating'
            '${_organisationLabel(ride.organisation)}',
          ),
          isThreeLine: true,
          trailing: _entryMenu(
            'ride-${ride.rideId}',
            ride.libraryStatus,
            (action) => _manageRide(ride, action),
          ),
          onTap: () => _openRide(ride),
        ),
      ),
    );
  }

  Future<void> _chooseOptions(StoredRouteCandidate candidate) async {
    if (candidate.geometry.libraryStatus == RideLibraryStatus.deleted) return;
    final selection = await showModalBottomSheet<StoredRouteSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StoredRouteOptionsSheet(
        candidate: candidate,
        distanceUnit: widget.distanceUnit,
        basemapConfiguration: widget.basemapConfiguration,
      ),
    );
    if (selection == null || !mounted) return;
    Navigator.of(context).pop(selection);
  }

  Future<void> _openRide(CompletedRide ride) async {
    if (widget.openPreviousRide == null) {
      if (ride.libraryStatus == RideLibraryStatus.deleted) return;
      final geometry = ride.traveledRoute ?? ride.plannedRoute;
      if (geometry != null) {
        await _chooseOptions(
          StoredRouteCandidate(
            id: 'ride:${ride.rideId}:track',
            origin: ride.traveledRoute != null
                ? StoredRouteOrigin.previousRideTrack
                : StoredRouteOrigin.previousRidePlan,
            title: ride.title,
            storedAt: ride.startedAt,
            geometry: geometry.withLibraryDetails(
              organisation: ride.organisation,
            ),
            rideCode: ride.rideCode,
          ),
        );
      }
      return;
    }
    final selection = await widget.openPreviousRide!(context, ride);
    if (!mounted) return;
    if (selection != null) {
      Navigator.of(context).pop(selection);
      return;
    }
    await _reload();
  }

  Widget _entryMenu(
    String id,
    RideLibraryStatus status,
    ValueChanged<_EntryAction> onSelected,
  ) => PopupMenuButton<_EntryAction>(
    key: Key('library-actions-$id'),
    tooltip: 'Manage ride',
    onSelected: onSelected,
    itemBuilder: (_) => [
      const PopupMenuItem(value: _EntryAction.rename, child: Text('Rename')),
      if (status == RideLibraryStatus.active)
        const PopupMenuItem(
          value: _EntryAction.correct,
          child: Text('Make a corrected copy'),
        ),
      const PopupMenuItem(
        value: _EntryAction.organise,
        child: Text('Tags, folder & colour'),
      ),
      if (status == RideLibraryStatus.active)
        const PopupMenuItem(value: _EntryAction.bin, child: Text('Move to Bin'))
      else
        const PopupMenuItem(
          value: _EntryAction.restore,
          child: Text('Restore'),
        ),
    ],
  );

  Future<String?> _rename(String title) async {
    var name = title;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextFormField(
          key: const Key('library-name-field'),
          initialValue: title,
          autofocus: true,
          maxLength: 120,
          onChanged: (value) => name = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.trim().isNotEmpty) Navigator.pop(context, name.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _manageRoute(
    StoredRouteCandidate candidate,
    _EntryAction action,
  ) async {
    final route = candidate.geometry;
    await _mutate(() async {
      if (action == _EntryAction.correct) {
        final copy = await RouteCorrectionScreen.show(
          context,
          source: route,
          basemapConfiguration: widget.basemapConfiguration,
        );
        if (copy != null) await widget.library.recordedRoutes.save(copy);
        return;
      }
      if (action == _EntryAction.organise) {
        final organisation = await _editOrganisation(route.organisation);
        if (organisation != null) {
          await widget.library.recordedRoutes.save(
            route.withLibraryDetails(organisation: organisation),
          );
        }
        return;
      }

      final name = action == _EntryAction.rename
          ? await _rename(route.name)
          : null;
      if (action == _EntryAction.rename && name == null) return;
      await widget.library.recordedRoutes.save(
        route.withLibraryDetails(
          name: name,
          status: switch (action) {
            _EntryAction.bin => RideLibraryStatus.deleted,
            _EntryAction.restore => RideLibraryStatus.active,
            _ => null,
          },
        ),
      );
    });
  }

  Future<void> _manageRide(CompletedRide ride, _EntryAction action) async {
    await _mutate(() async {
      if (action == _EntryAction.correct) {
        final route = ride.traveledRoute ?? ride.comparisonPlan;
        if (route == null) {
          throw const FormatException(
            'This ride has no route geometry to copy.',
          );
        }
        final copy = await RouteCorrectionScreen.show(
          context,
          source: route.withLibraryDetails(
            name: ride.title,
            organisation: ride.organisation,
          ),
          basemapConfiguration: widget.basemapConfiguration,
        );
        if (copy != null) await widget.library.recordedRoutes.save(copy);
        return;
      }
      if (action == _EntryAction.organise) {
        final organisation = await _editOrganisation(ride.organisation);
        if (organisation != null) {
          await widget.library.completedRides.save(
            ride.copyWith(organisation: organisation),
          );
        }
        return;
      }

      final name = action == _EntryAction.rename
          ? await _rename(ride.title)
          : null;
      if (action == _EntryAction.rename && name == null) return;
      await widget.library.completedRides.save(
        ride.copyWith(
          libraryName: name,
          libraryStatus: switch (action) {
            _EntryAction.bin => RideLibraryStatus.deleted,
            _EntryAction.restore => RideLibraryStatus.active,
            _ => null,
          },
          deletedAt: action == _EntryAction.bin ? DateTime.now().toUtc() : null,
          clearDeletedAt: action == _EntryAction.restore,
        ),
      );
    });
  }

  Future<RideLibraryOrganisation?> _editOrganisation(
    RideLibraryOrganisation initial,
  ) async {
    final data = await _data;
    if (!mounted) return null;
    final folders = <String>{
      for (final candidate in data.candidates)
        candidate.geometry.organisation.folder,
      for (final ride in data.rides) ride.organisation.folder,
    }..remove('');
    return showDialog<RideLibraryOrganisation>(
      context: context,
      builder: (_) => _OrganisationDialog(
        initial: initial,
        folders: folders.toList()..sort(),
      ),
    );
  }

  Future<void> _mutate(Future<void> Function() change) async {
    try {
      await change();
      if (mounted) await _reload();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update the library: $error')),
        );
      }
    }
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

enum _EntryAction { rename, organise, correct, bin, restore }

/// One choosable stored route: its shape, what it is, when it was ridden and
/// how far it goes. A list of dates is not choosable.
class StoredRouteCandidateTile extends StatelessWidget {
  const StoredRouteCandidateTile({
    super.key,
    required this.candidate,
    this.endpointLabel,
    required this.distanceUnit,
    this.basemapConfiguration = const BasemapConfiguration(),
    required this.onTap,
    this.trailing,
  });

  final StoredRouteCandidate candidate;
  final String? endpointLabel;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: Key('stored-route-candidate-${candidate.id}'),
      contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      leading: SizedBox.square(
        dimension: 52,
        child: StoredRouteMapPreview(
          candidate: candidate,
          basemapConfiguration: basemapConfiguration,
          interactive: false,
        ),
      ),
      title: Text(candidate.title),
      subtitle: Text(
        '${endpointLabel == null ? '' : '$endpointLabel\n'}'
        '${storedRouteKindLabel(candidate.origin)} · '
        '${_date(candidate.storedAt)}\n'
        '${MeasurementFormatter(distanceUnit).distance(routeLengthMeters(candidate.geometry))} · '
        '${candidate.pointCount} points'
        '${candidate.rideCode == null ? '' : ' · ride ${candidate.rideCode}'}'
        '${_organisationLabel(candidate.geometry.organisation)}',
      ),
      isThreeLine: true,
      trailing: trailing ?? const Icon(Icons.chevron_right),
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

/// Uses real vector tiles when this build has a basemap, with the old local
/// route sketch as an offline/unconfigured fallback.
class StoredRouteMapPreview extends StatelessWidget {
  const StoredRouteMapPreview({
    super.key,
    required this.candidate,
    required this.basemapConfiguration,
    this.interactive = true,
    this.reversed = false,
  });

  final StoredRouteCandidate candidate;
  final BasemapConfiguration basemapConfiguration;
  final bool interactive;
  final bool reversed;

  @override
  Widget build(BuildContext context) {
    if (!basemapConfiguration.usesMapLibre) {
      return StoredRouteShapePreview(candidate: candidate);
    }
    final sourcePaths = candidate.geometry.paths
        .where((path) => path.points.length >= 2)
        .toList(growable: false);
    final orderedPaths = reversed ? sourcePaths.reversed : sourcePaths;
    final paths = [
      for (final path in orderedPaths)
        reversed ? path.points.reversed.toList(growable: false) : path.points,
    ];
    if (!interactive) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedRoutePreview(
          paths: paths,
          configuration: basemapConfiguration,
          colour: Color(candidate.geometry.organisation.colourArgb),
          fallback: StoredRouteShapePreview(candidate: candidate),
        ),
      );
    }
    final map = Stack(
      fit: StackFit.expand,
      children: [
        StoredRouteShapePreview(candidate: candidate),
        FlutterVectorRoutePreview(
          paths: paths,
          basemapConfiguration: basemapConfiguration,
          interactive: interactive,
          routeColour: Color(candidate.geometry.organisation.colourArgb),
        ),
      ],
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: interactive ? map : IgnorePointer(child: map),
    );
  }
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
      color: Color(candidate.geometry.organisation.colourArgb),
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
    this.basemapConfiguration = const BasemapConfiguration(),
  });

  final StoredRouteCandidate candidate;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;

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
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.88,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    const SizedBox(height: 14),
                    SizedBox(
                      key: const Key('stored-route-map-preview'),
                      height: 220,
                      child: StoredRouteMapPreview(
                        candidate: candidate,
                        basemapConfiguration: widget.basemapConfiguration,
                        reversed: _reversed,
                      ),
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
                        style: const TextStyle(
                          color: Color(0xFF98A3B1),
                          height: 1.4,
                        ),
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
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
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
              ),
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

/// Whether this route came from TEC's dedicated route recorder.
///
/// Recorded-route storage predates origin metadata, so the recorder's stable
/// source name is the backwards-compatible distinction for existing libraries.
bool storedRouteWasRecordedOnDevice(StoredRouteCandidate candidate) =>
    candidate.origin == StoredRouteOrigin.recordedRoute &&
    candidate.geometry.sourceFileName.toLowerCase() == 'recorded.gpx';

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

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 14),
    child: Column(
      children: [
        const Icon(Icons.route_outlined, size: 42, color: Color(0xFF7F8A98)),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFFABB5C1), height: 1.4),
        ),
      ],
    ),
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

String _organisationLabel(RideLibraryOrganisation value) => [
  if (value.folder.isNotEmpty) value.folder,
  if (value.tags.isNotEmpty) value.tags.map((tag) => '#$tag').join(' '),
].map((label) => '\n$label').join();

class _OrganisationDialog extends StatefulWidget {
  const _OrganisationDialog({required this.initial, required this.folders});
  final RideLibraryOrganisation initial;
  final List<String> folders;
  @override
  State<_OrganisationDialog> createState() => _OrganisationDialogState();
}

class _OrganisationDialogState extends State<_OrganisationDialog> {
  final _form = GlobalKey<FormState>();
  late final _folder = TextEditingController(text: widget.initial.folder);
  late String _tags = widget.initial.tags.map((tag) => '#$tag').join(' ');
  late int _colour = widget.initial.colourArgb;
  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Organise ride'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('library-tags-field'),
                initialValue: _tags,
                decoration: const InputDecoration(
                  labelText: 'Tags',
                  helperText: '#fun #long #wet #twisty',
                  helperMaxLines: 2,
                ),
                onChanged: (value) => _tags = value,
                validator: (value) {
                  final tags = (value ?? '')
                      .split(RegExp(r'[\s,#]+'))
                      .where((tag) => tag.isNotEmpty)
                      .toList();
                  if (tags.length > 20) return 'Use up to 20 tags.';
                  if (tags.any(
                    (tag) => !RegExp(
                      r'^[\p{L}\p{N}_-]{1,32}$',
                      unicode: true,
                    ).hasMatch(tag),
                  )) {
                    return 'Use letters, numbers, hyphens or underscores (up to 32 per tag).';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('library-folder-field'),
                controller: _folder,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Folder',
                  hintText: 'Trips/France · leave empty for Unfiled',
                ),
              ),
              if (widget.folders.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final folder in widget.folders)
                      ActionChip(
                        label: Text(folder),
                        onPressed: () => _folder.text = folder,
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              const Text('Map colour'),
              Wrap(
                spacing: 8,
                children: [
                  for (
                    var i = 0;
                    i < RideLibraryOrganisation.colours.length;
                    i++
                  )
                    ChoiceChip(
                      key: Key('library-colour-$i'),
                      label: Text(
                        const [
                          'Teal',
                          'Blue',
                          'Orange',
                          'Pink',
                          'Purple',
                          'Gold',
                        ][i],
                      ),
                      avatar: Icon(
                        Icons.circle,
                        color: Color(RideLibraryOrganisation.colours[i]),
                        size: 18,
                      ),
                      selected: _colour == RideLibraryOrganisation.colours[i],
                      onSelected: (_) => setState(
                        () => _colour = RideLibraryOrganisation.colours[i],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              RideLibraryOrganisation.fromInput(
                tags: _tags,
                folder: _folder.text,
                colourArgb: _colour,
              ),
            );
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
