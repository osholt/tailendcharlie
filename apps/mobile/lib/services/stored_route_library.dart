import 'package:uuid/uuid.dart';

import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';
import '../domain/imported_route.dart';
import '../domain/recorded_route_store.dart';
import 'approximate_place_index.dart';
import 'recorded_track_cleaner.dart';

/// What a stored route actually is, which decides how it may be offered.
///
/// The distinction is the whole point: a plan was drawn as a route, a track is
/// a record of what a bike did. Presenting the second as the first is the
/// dishonesty #155 exists to prevent.
enum StoredRouteOrigin {
  /// Deliberately recorded ahead of a ride, from `RouteRecorderController`
  /// via [RecordedRouteStore].
  recordedRoute,

  /// The route a previous ride was actually planned with.
  previousRidePlan,

  /// The GPS trail a previous ride produced.
  previousRideTrack,
}

/// Whether a recording is offered tidied or exactly as it was recorded.
enum StoredRouteVariant { tidied, raw }

/// One selectable piece of geometry already on this phone.
class StoredRouteCandidate {
  const StoredRouteCandidate({
    required this.id,
    required this.origin,
    required this.title,
    required this.storedAt,
    required this.geometry,
    this.rideCode,
  });

  /// Stable within a listing, so the picker can key rows and compare
  /// selections without holding onto geometry.
  final String id;

  final StoredRouteOrigin origin;

  /// Route name, or the ride's own title.
  final String title;

  /// When this geometry came into being: the recording time, or the ride's
  /// start. Never "when it was archived" — a rider chooses by when they rode.
  final DateTime storedAt;

  /// The ride code, for the two origins that have one. A rider who rode two
  /// similar loops on the same day has nothing else to tell them apart.
  final String? rideCode;

  /// The stored geometry, exactly as persisted. Never pre-tidied: the raw
  /// track has to stay available.
  final ImportedRoute geometry;

  /// True when this is a recording rather than a plan, and therefore when the
  /// tidied/raw choice applies.
  bool get isRecording => origin != StoredRouteOrigin.previousRidePlan;

  int get pointCount => geometry.pathPointCount;

  List<RoutePath> get _ridablePaths => geometry.paths
      .where((path) => path.points.length >= 2)
      .toList(growable: false);

  GeoPoint? get startPoint =>
      _ridablePaths.isEmpty ? null : _ridablePaths.first.points.first;

  GeoPoint? get endPoint =>
      _ridablePaths.isEmpty ? null : _ridablePaths.last.points.last;
}

/// A rider's answer to "which of these, and how".
class StoredRouteSelection {
  const StoredRouteSelection({
    required this.candidate,
    this.variant = StoredRouteVariant.tidied,
    this.reversed = false,
  });

  final StoredRouteCandidate candidate;
  final StoredRouteVariant variant;

  /// Ride it from the original finish back to the original start. Riding a
  /// route home is the obvious second use of a previous ride.
  final bool reversed;

  StoredRouteSelection copyWith({
    StoredRouteVariant? variant,
    bool? reversed,
  }) => StoredRouteSelection(
    candidate: candidate,
    variant: variant ?? this.variant,
    reversed: reversed ?? this.reversed,
  );
}

/// A stored route turned into the same thing a GPX import produces, together
/// with the plain statements the rider must see before confirming it.
class PreparedStoredRoute {
  const PreparedStoredRoute({required this.route, required this.notes});

  final ImportedRoute route;

  /// Shown on the route review screen through its existing `warnings` channel,
  /// so "this is a recording, not a plan" arrives in the same place as every
  /// other caveat about a candidate route.
  final List<String> notes;
}

/// The stored geometry on this phone, offered as a route source.
///
/// This is deliberately a thin adapter. It produces [ImportedRoute] — the one
/// route representation the app has — so a route chosen here is
/// indistinguishable downstream from the same route imported as GPX: same
/// review screen, same `RouteStore`, same `RouteProgressTracker`, same
/// breadcrumbs, same manoeuvre extraction. There is no second route model
/// (#155).
class StoredRouteLibrary {
  StoredRouteLibrary({
    required this.recordedRoutes,
    required this.completedRides,
    this.cleaner = const RecordedTrackCleaner(),
    this.approximatePlaceIndex,
    String Function()? idFactory,
    DateTime Function()? clock,
  }) : _idFactory = idFactory ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final RecordedRouteStore recordedRoutes;
  final CompletedRideStore completedRides;
  final RecordedTrackCleaner cleaner;
  final ApproximatePlaceIndex? approximatePlaceIndex;
  final String Function() _idFactory;
  final DateTime Function() _clock;

  /// Everything selectable, recorded routes first and then previous rides,
  /// each group newest first.
  ///
  /// Retention is **not** extended to make this work. Ride geometry lives and
  /// dies with the ride's own archive entry: a ride whose geometry was never
  /// captured, was damaged on disk, or has been deleted simply produces no
  /// candidate, so it cannot be selected.
  Future<List<StoredRouteCandidate>> list() async {
    final candidates = <StoredRouteCandidate>[];
    for (final route in await recordedRoutes.list()) {
      if (!_hasRidableGeometry(route)) continue;
      candidates.add(
        StoredRouteCandidate(
          id: 'recorded:${route.id}',
          origin: StoredRouteOrigin.recordedRoute,
          title: route.name,
          storedAt: route.importedAt,
          geometry: route,
        ),
      );
    }
    for (final ride in await completedRides.list()) {
      // The plan first: where a ride had one it is a better route than the
      // recording of riding it.
      if (ride.plannedRoute case final plan? when _hasRidableGeometry(plan)) {
        candidates.add(
          _fromRide(ride, plan, StoredRouteOrigin.previousRidePlan),
        );
      }
      if (ride.traveledRoute case final track?
          when _hasRidableGeometry(track)) {
        candidates.add(
          _fromRide(ride, track, StoredRouteOrigin.previousRideTrack),
        );
      }
    }
    return List.unmodifiable(candidates);
  }

  StoredRouteCandidate _fromRide(
    CompletedRide ride,
    ImportedRoute geometry,
    StoredRouteOrigin origin,
  ) => StoredRouteCandidate(
    id:
        'ride:${ride.rideId}:'
        '${origin == StoredRouteOrigin.previousRidePlan ? 'plan' : 'track'}',
    origin: origin,
    title: ride.title,
    storedAt: ride.startedAt,
    rideCode: ride.rideCode,
    geometry: geometry,
  );

  /// A route needs a line to ride, so a single fix or an empty path is not a
  /// candidate. Waypoints alone are excluded too: turning them into geometry
  /// needs a routing engine, and a route offered here has to work offline.
  bool _hasRidableGeometry(ImportedRoute route) =>
      route.paths.any((path) => path.points.length >= 2);

  /// Builds the selection into a route, and states plainly what it is.
  PreparedStoredRoute prepare(StoredRouteSelection selection) {
    final candidate = selection.candidate;
    final tidying =
        candidate.isRecording && selection.variant == StoredRouteVariant.tidied;
    var paths = candidate.geometry.paths;
    if (tidying) {
      paths = [
        for (final path in paths)
          RoutePath(
            kind: path.kind,
            name: path.name,
            points: path.points.length >= 2
                ? cleaner.clean(path.points)
                : path.points,
          ),
      ];
    }
    var waypoints = candidate.geometry.waypoints;
    // Manoeuvres describe turns taken in one direction; read backwards they
    // are wrong. Dropping them leaves a reversed route in exactly the state a
    // GPX track import is in, and the review step's road matching regenerates
    // them when there is a connection.
    var maneuvers = selection.reversed
        ? const <RouteManeuver>[]
        : candidate.geometry.maneuvers;
    if (selection.reversed) {
      paths = [
        for (final path in paths.reversed)
          RoutePath(
            kind: path.kind,
            name: path.name,
            points: _reversePoints(path.points),
          ),
      ];
      waypoints = waypoints.reversed.toList(growable: false);
    }

    return PreparedStoredRoute(
      route: ImportedRoute(
        // A fresh identity: this is a new route for a new ride, and
        // `RouteProgressTracker` keys its progress on it.
        id: _idFactory(),
        name: selection.reversed
            ? '${candidate.title} (reversed)'
            : candidate.title,
        description: _description(candidate),
        importedAt: _clock(),
        sourceFileName: _sourceLabel(candidate),
        paths: List.unmodifiable(paths),
        waypoints: waypoints,
        maneuvers: maneuvers,
      ),
      notes: _notes(candidate, tidied: tidying, reversed: selection.reversed),
    );
  }

  /// Timestamps run forwards. Kept on an unreversed track — the GPX exporter
  /// writes them out — and dropped when the direction is flipped rather than
  /// exported as a track that appears to travel backwards through time.
  List<GeoPoint> _reversePoints(List<GeoPoint> points) => [
    for (final point in points.reversed)
      GeoPoint(
        latitude: point.latitude,
        longitude: point.longitude,
        elevationMeters: point.elevationMeters,
      ),
  ];

  String _description(StoredRouteCandidate candidate) =>
      switch (candidate.origin) {
        StoredRouteOrigin.recordedRoute => 'Recorded on this phone.',
        StoredRouteOrigin.previousRidePlan =>
          'The planned route of ride ${candidate.rideCode}.',
        StoredRouteOrigin.previousRideTrack =>
          'Recorded while riding ride ${candidate.rideCode}.',
      };

  /// Stands in for the file name a GPX import carries, so every surface that
  /// shows provenance keeps showing something true. It is not a real file, and
  /// nothing was written to one: no export step is involved in choosing a
  /// stored route.
  String _sourceLabel(StoredRouteCandidate candidate) =>
      switch (candidate.origin) {
        StoredRouteOrigin.recordedRoute => 'recorded-route',
        StoredRouteOrigin.previousRidePlan => 'ride-${candidate.rideCode}-plan',
        StoredRouteOrigin.previousRideTrack =>
          'ride-${candidate.rideCode}-track',
      };

  List<String> _notes(
    StoredRouteCandidate candidate, {
    required bool tidied,
    required bool reversed,
  }) => [
    switch (candidate.origin) {
      StoredRouteOrigin.previousRidePlan =>
        'This is the route that ride was planned with, not a recording of it.',
      _ when tidied =>
        'This is a tidied recording, not a planned route. Stops and GPS '
            'wander were removed. Every road the bike actually took is kept, '
            'including any wrong turns and car park loops.',
      _ =>
        'This is the raw recorded track: every fix as it was recorded, '
            'including stops, GPS wander and any wrong turns.',
    },
    if (reversed)
      'Reversed: it runs from the original finish to the original start. '
          'Turn instructions recorded in the original direction were dropped.',
  ];
}
