import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';
import '../domain/imported_route.dart';
import '../domain/recorded_route_store.dart';

class RideLibraryBackupResult {
  const RideLibraryBackupResult({
    required this.completedRideCount,
    required this.recordedRouteCount,
  });

  final int completedRideCount;
  final int recordedRouteCount;
}

/// A portable, secret-free backup of the routes and completed rides held on
/// one device. Restoring merges by stable ID and never erases newer local data.
class RideLibraryBackupService {
  const RideLibraryBackupService({
    required this.completedRides,
    required this.recordedRoutes,
  });

  static const schemaVersion = 1;
  static const _type = XTypeGroup(
    label: 'Tail End Charlie ride backup',
    extensions: ['tecbackup', 'json'],
    mimeTypes: ['application/json'],
    uniformTypeIdentifiers: ['public.json'],
  );

  final CompletedRideStore completedRides;
  final RecordedRouteStore recordedRoutes;

  Future<String> encode({DateTime? exportedAt}) async => jsonEncode({
    'schemaVersion': schemaVersion,
    'exportedAt': (exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
    'completedRides': [
      for (final ride in await completedRides.list()) ride.toJson(),
    ],
    'recordedRoutes': [
      for (final route in await recordedRoutes.list()) route.toJson(),
    ],
  });

  Future<void> share({Rect? sharePositionOrigin}) async {
    final source = await encode();
    final date = DateTime.now().toUtc().toIso8601String().split('T').first;
    await SharePlus.instance.share(
      ShareParams(
        subject: 'Tail End Charlie Ride Library backup',
        text: 'Ride Library backup created $date.',
        sharePositionOrigin: sharePositionOrigin,
        files: [
          XFile.fromData(
            Uint8List.fromList(utf8.encode(source)),
            mimeType: 'application/json',
            name: 'tail-end-charlie-rides-$date.tecbackup',
          ),
        ],
      ),
    );
  }

  Future<RideLibraryBackupResult?> restoreFromPicker() async {
    final file = await openFile(acceptedTypeGroups: const [_type]);
    if (file == null) return null;
    return restore(await file.readAsString());
  }

  Future<RideLibraryBackupResult> restore(String source) async {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['schemaVersion'] != schemaVersion) {
      throw const FormatException('Unsupported Ride Library backup.');
    }
    final rawRides = decoded['completedRides'];
    final rawRoutes = decoded['recordedRoutes'];
    if (rawRides is! List || rawRoutes is! List) {
      throw const FormatException('Ride Library backup is incomplete.');
    }

    // Parse the entire file before changing either store. A malformed entry
    // must not leave a half-restored library.
    final rides = rawRides
        .map(
          (value) =>
              CompletedRide.fromJson(Map<String, Object?>.from(value as Map)),
        )
        .toList(growable: false);
    final routes = rawRoutes
        .map(
          (value) =>
              ImportedRoute.fromJson(Map<String, Object?>.from(value as Map)),
        )
        .toList(growable: false);
    if ({for (final ride in rides) ride.rideId}.length != rides.length ||
        {for (final route in routes) route.id}.length != routes.length) {
      throw const FormatException(
        'Ride Library backup contains duplicate IDs.',
      );
    }

    final existingRideIds = {
      for (final ride in await completedRides.list()) ride.rideId,
    };
    final existingRouteIds = {
      for (final route in await recordedRoutes.list()) route.id,
    };
    final newRides = rides
        .where((ride) => !existingRideIds.contains(ride.rideId))
        .toList(growable: false);
    final newRoutes = routes
        .where((route) => !existingRouteIds.contains(route.id))
        .toList(growable: false);
    for (final ride in newRides) {
      await completedRides.save(ride);
    }
    for (final route in newRoutes) {
      await recordedRoutes.save(route);
    }
    return RideLibraryBackupResult(
      completedRideCount: newRides.length,
      recordedRouteCount: newRoutes.length,
    );
  }
}
