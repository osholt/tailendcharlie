import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

import '../domain/completed_ride.dart';
import '../domain/distance_unit.dart';
import 'gpx_exporter.dart';
import 'measurement_formatter.dart';

abstract interface class CompletedRideSharer {
  Future<void> shareSummary(
    CompletedRide ride, {
    DistanceUnit distanceUnit,
    Rect? sharePositionOrigin,
  });

  Future<void> exportGpx(CompletedRide ride, {Rect? sharePositionOrigin});
}

class SystemCompletedRideSharer implements CompletedRideSharer {
  const SystemCompletedRideSharer({this.gpxExporter = const GpxExporter()});

  final GpxExporter gpxExporter;

  @override
  Future<void> shareSummary(
    CompletedRide ride, {
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    Rect? sharePositionOrigin,
  }) async {
    final distance = MeasurementFormatter(
      distanceUnit,
    ).distance(ride.totalDistanceMeters);
    final text = [
      'Tail End Charlie ride · ${ride.title}',
      'Ride code: ${ride.rideCode}',
      'Rider: ${ride.localDisplayName} (${ride.localRole.name})',
      'Started: ${ride.startedAt.toLocal().toIso8601String()}',
      'Ended: ${ride.endedAt.toLocal().toIso8601String()}',
      'Duration: ${_duration(ride.duration)}',
      'Distance: $distance',
      'Riders: ${ride.riderCount}',
      'Marker sessions: ${ride.markerSessions.length}',
    ].join('\n');
    await SharePlus.instance.share(
      ShareParams(
        subject: ride.title,
        text: text,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  @override
  Future<void> exportGpx(
    CompletedRide ride, {
    Rect? sharePositionOrigin,
  }) async {
    final route = ride.traveledRoute;
    if (route == null) {
      throw StateError('This ride has no recorded local trail to export.');
    }
    final fileName = gpxExporter.fileName(route);
    final bytes = Uint8List.fromList(utf8.encode(gpxExporter.export(route)));
    await SharePlus.instance.share(
      ShareParams(
        title: 'Export ${ride.title}',
        subject: 'Tail End Charlie GPX: ${ride.title}',
        text:
            'Choose Files, Downloads or a GPX-compatible app in the share sheet.',
        files: [
          XFile.fromData(
            bytes,
            mimeType: 'application/gpx+xml',
            name: fileName,
          ),
        ],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  static String _duration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    return hours == 0 ? '${minutes}m' : '${hours}h ${minutes}m';
  }
}
