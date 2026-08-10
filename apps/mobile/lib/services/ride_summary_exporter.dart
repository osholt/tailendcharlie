import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

import '../domain/distance_unit.dart';
import '../domain/geo_point.dart' as geo;
import '../domain/imported_route.dart';
import '../domain/ride_event.dart';
import '../domain/ride_session.dart';
import 'geo_calculations.dart';
import 'gpx_exporter.dart';
import 'measurement_formatter.dart';
import 'ride_lifecycle.dart';

typedef _TrailPoint = ({
  double latitude,
  double longitude,
  DateTime recordedAt,
});

class MarkerSessionSummary {
  const MarkerSessionSummary({
    required this.markerDeviceId,
    required this.startedAt,
    required this.endedAt,
    required this.uniquePassCount,
    required this.duration,
  });

  final String markerDeviceId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int uniquePassCount;
  final Duration duration;

  bool get isComplete => endedAt != null;
}

class RideSummary {
  const RideSummary({
    required this.rideId,
    required this.rideCode,
    required this.displayName,
    required this.startedAt,
    required this.endedAt,
    required this.generatedAt,
    required this.eventCount,
    required this.markerSessions,
    required this.riderCount,
    required this.totalDistanceMeters,
  });

  final String rideId;
  final String rideCode;
  final String displayName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime generatedAt;
  final int eventCount;
  final List<MarkerSessionSummary> markerSessions;
  final int riderCount;
  final double totalDistanceMeters;

  Duration get rideDuration =>
      (endedAt ?? generatedAt).difference(startedAt).abs();

  Duration get totalMarkingDuration => markerSessions.fold(
    Duration.zero,
    (total, session) => total + session.duration,
  );

  int get totalConfirmedPasses => markerSessions.fold(
    0,
    (total, session) => total + session.uniquePassCount,
  );
}

class RideSummaryExporter {
  const RideSummaryExporter();

  /// Position reports normally arrive seconds apart. Past this interval the
  /// intervening path is unknown and must not be counted or drawn (#205).
  static const maximumContinuousTrailGap = Duration(minutes: 2);

  RideSummary summarize(
    RideSession session,
    Iterable<RideEvent> events, {
    required DateTime generatedAt,
  }) {
    final ordered = _sorted(events);
    final lifecycle = RideLifecycleReducer.fromEvents(
      rideId: session.rideId,
      inviteSecret: session.inviteSecret,
      events: ordered,
    );
    final startedAt =
        lifecycle.startedAt ??
        (ordered.isEmpty
            ? session.joinedAt
            : _earlier(session.joinedAt, ordered.first.createdAt));
    final activityEvents = lifecycle.startedAt == null
        ? ordered
        : ordered
              .where((event) => !event.createdAt.isBefore(startedAt))
              .toList(growable: false);
    final endedAt = ordered
        .where((event) => event.type == RideEventType.rideEnded)
        .map((event) => event.createdAt)
        .lastOrNull;

    final completed = <MarkerSessionSummary>[];
    final active = <String, _MarkerAccumulator>{};
    for (final event in activityEvents) {
      switch (event.type) {
        case RideEventType.markerStarted:
          active.putIfAbsent(
            event.deviceId,
            () => _MarkerAccumulator(
              markerDeviceId: event.deviceId,
              startedAt: event.createdAt,
            ),
          );
        case RideEventType.markerPass:
          final riderId = event.payload['riderId'];
          if (riderId is String && riderId.isNotEmpty) {
            active[event.deviceId]?.riderIds.add(riderId);
          }
        case RideEventType.markerEnded:
          final accumulator = active.remove(event.deviceId);
          if (accumulator != null) {
            final rawRecordedPasses = event.payload['uniquePasses'];
            final recordedPasses = rawRecordedPasses is num
                ? rawRecordedPasses.toInt()
                : 0;
            completed.add(
              accumulator.finish(
                endedAt: event.createdAt,
                minimumPasses: math.max(recordedPasses, 0),
              ),
            );
          }
        default:
          break;
      }
    }
    for (final accumulator in active.values) {
      completed.add(accumulator.finish(endedAt: null, now: generatedAt));
    }
    completed.sort((left, right) => left.startedAt.compareTo(right.startedAt));

    final riderIds = {session.localRiderId, ...ordered.map((e) => e.deviceId)};
    final trail = _ownTrail(
      session.localRiderId,
      ordered,
      notBefore: lifecycle.startedAt,
    );

    return RideSummary(
      rideId: session.rideId,
      rideCode: session.rideCode,
      displayName: session.displayName,
      startedAt: startedAt,
      endedAt: endedAt,
      generatedAt: generatedAt,
      eventCount: ordered.length,
      markerSessions: List.unmodifiable(completed),
      riderCount: riderIds.length,
      totalDistanceMeters: _trailDistanceMeters(trail),
    );
  }

  /// The rider's own recorded path as a GPX-exportable track, or null if too
  /// few position fixes were recorded to plot a meaningful trail.
  ImportedRoute? traveledRoute(
    RideSession session,
    Iterable<RideEvent> events, {
    required DateTime generatedAt,
  }) {
    final ordered = _sorted(events);
    final lifecycle = RideLifecycleReducer.fromEvents(
      rideId: session.rideId,
      inviteSecret: session.inviteSecret,
      events: ordered,
    );
    final trail = _ownTrail(
      session.localRiderId,
      ordered,
      notBefore: lifecycle.startedAt,
    );
    if (trail.length < 2) return null;
    final segments = _continuousTrailSegments(trail);
    final trackName = session.rideName ?? 'Ride ${session.rideCode}';
    return ImportedRoute(
      id: session.rideId,
      name: trackName,
      importedAt: generatedAt,
      sourceFileName: '${session.rideCode}.gpx',
      paths: [
        for (final (index, segment) in segments.indexed)
          RoutePath(
            kind: RoutePathKind.track,
            name: segments.length == 1
                ? trackName
                : '$trackName · segment ${index + 1}',
            points: [
              for (final point in segment)
                GeoPoint(
                  latitude: point.latitude,
                  longitude: point.longitude,
                  recordedAt: point.recordedAt,
                ),
            ],
          ),
      ],
      waypoints: const [],
    );
  }

  String toPlainText(
    RideSummary summary, {
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
  }) {
    final distance = MeasurementFormatter(
      distanceUnit,
    ).distance(summary.totalDistanceMeters);
    final buffer = StringBuffer()
      ..writeln('Tail End Charlie summary · ${summary.rideCode}')
      ..writeln('Rider: ${summary.displayName}')
      ..writeln('Riders on this ride: ${summary.riderCount}')
      ..writeln('Started: ${summary.startedAt.toLocal().toIso8601String()}')
      ..writeln(
        'Ended: ${summary.endedAt?.toLocal().toIso8601String() ?? 'ride still active'}',
      )
      ..writeln('Ride time: ${_duration(summary.rideDuration)}')
      ..writeln('Distance covered: $distance')
      ..writeln('Events recorded: ${summary.eventCount}')
      ..writeln('Marker sessions: ${summary.markerSessions.length}')
      ..writeln(
        'Time spent marking: ${_duration(summary.totalMarkingDuration)}',
      )
      ..writeln('Confirmed marker passes: ${summary.totalConfirmedPasses}');
    for (var index = 0; index < summary.markerSessions.length; index += 1) {
      final marker = summary.markerSessions[index];
      buffer.writeln(
        'Marker ${index + 1}: ${_duration(marker.duration)}, '
        '${marker.uniquePassCount} passes${marker.isComplete ? '' : ' (active)'}.',
      );
    }
    return buffer.toString().trimRight();
  }

  String toCsv(RideSummary summary) {
    final rows = <List<Object?>>[
      ['ride_code', summary.rideCode],
      ['ride_id', summary.rideId],
      ['rider', summary.displayName],
      ['started_at_utc', summary.startedAt.toUtc().toIso8601String()],
      ['ended_at_utc', summary.endedAt?.toUtc().toIso8601String()],
      ['generated_at_utc', summary.generatedAt.toUtc().toIso8601String()],
      ['ride_duration_seconds', summary.rideDuration.inSeconds],
      ['event_count', summary.eventCount],
      ['rider_count', summary.riderCount],
      ['distance_meters', summary.totalDistanceMeters.round()],
      [],
      [
        'marker_device_id',
        'started_at_utc',
        'ended_at_utc',
        'duration_seconds',
        'unique_passes',
        'complete',
      ],
      for (final marker in summary.markerSessions)
        [
          marker.markerDeviceId,
          marker.startedAt.toUtc().toIso8601String(),
          marker.endedAt?.toUtc().toIso8601String(),
          marker.duration.inSeconds,
          marker.uniquePassCount,
          marker.isComplete,
        ],
    ];
    return '${rows.map(_csvRow).join('\r\n')}\r\n';
  }

  String fileName(RideSummary summary) =>
      'ride-relay-${summary.rideCode.toLowerCase()}-summary.csv';

  String trailFileName(RideSummary summary) =>
      'ride-relay-${summary.rideCode.toLowerCase()}-trail.gpx';

  static List<RideEvent> _sorted(Iterable<RideEvent> events) =>
      events.toList(growable: false)..sort((left, right) {
        final time = left.createdAt.compareTo(right.createdAt);
        return time != 0 ? time : left.id.compareTo(right.id);
      });

  /// Reconstructs the local rider's own position fixes from
  /// [RideEventType.riderLocationUpdated] events, walking the raw payload
  /// defensively (rather than via `RiderLocation.fromJson`) since relayed
  /// events from other devices are untrusted and a malformed one shouldn't
  /// break the whole export.
  static List<_TrailPoint> _ownTrail(
    String localRiderId,
    List<RideEvent> ordered, {
    DateTime? notBefore,
  }) {
    final trail = <_TrailPoint>[];
    for (final event in ordered) {
      if (notBefore != null && event.createdAt.isBefore(notBefore)) continue;
      final point = _ownTrailPoint(event, localRiderId);
      if (point != null &&
          (notBefore == null || !point.recordedAt.isBefore(notBefore))) {
        trail.add(point);
      }
    }
    return trail;
  }

  static _TrailPoint? _ownTrailPoint(RideEvent event, String localRiderId) {
    if (event.type != RideEventType.riderLocationUpdated) return null;
    if (event.deviceId != localRiderId) return null;
    final location = event.payload['location'];
    if (location is! Map) return null;
    final sample = location['sample'];
    if (sample is! Map) return null;
    final position = sample['position'];
    if (position is! Map) return null;
    final latitude = position['latitude'];
    final longitude = position['longitude'];
    if (latitude is! num || longitude is! num) return null;
    final recordedAt = sample['recordedAt'];
    return (
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      recordedAt: recordedAt is String
          ? (DateTime.tryParse(recordedAt)?.toLocal() ?? event.createdAt)
          : event.createdAt,
    );
  }

  static double _trailDistanceMeters(List<_TrailPoint> trail) {
    var total = 0.0;
    for (final segment in _continuousTrailSegments(trail)) {
      for (var index = 1; index < segment.length; index += 1) {
        total += GeoCalculations.distanceMeters(
          geo.GeoPoint(
            latitude: segment[index - 1].latitude,
            longitude: segment[index - 1].longitude,
          ),
          geo.GeoPoint(
            latitude: segment[index].latitude,
            longitude: segment[index].longitude,
          ),
        );
      }
    }
    return total;
  }

  static List<List<_TrailPoint>> _continuousTrailSegments(
    List<_TrailPoint> trail,
  ) {
    if (trail.isEmpty) return const [];
    final segments = <List<_TrailPoint>>[
      <_TrailPoint>[trail.first],
    ];
    for (final point in trail.skip(1)) {
      final gap = point.recordedAt.difference(segments.last.last.recordedAt);
      if (gap > maximumContinuousTrailGap) {
        segments.add(<_TrailPoint>[]);
      }
      segments.last.add(point);
    }
    return segments;
  }

  static String _csvRow(List<Object?> values) =>
      values.map((value) => _csvCell(value?.toString() ?? '')).join(',');

  static String _csvCell(String value) => '"${value.replaceAll('"', '""')}"';

  static String _duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  static DateTime _earlier(DateTime left, DateTime right) =>
      left.isBefore(right) ? left : right;
}

class _MarkerAccumulator {
  _MarkerAccumulator({required this.markerDeviceId, required this.startedAt});

  final String markerDeviceId;
  final DateTime startedAt;
  final Set<String> riderIds = {};

  MarkerSessionSummary finish({
    required DateTime? endedAt,
    DateTime? now,
    int minimumPasses = 0,
  }) {
    final effectiveEnd = endedAt ?? now ?? startedAt;
    return MarkerSessionSummary(
      markerDeviceId: markerDeviceId,
      startedAt: startedAt,
      endedAt: endedAt,
      uniquePassCount: math.max(riderIds.length, minimumPasses),
      duration: effectiveEnd.difference(startedAt).abs(),
    );
  }
}

abstract interface class RideSummarySharer {
  Future<void> share(
    RideSession session,
    Iterable<RideEvent> events, {
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    Rect? sharePositionOrigin,
    String? diagnostics,
  });
}

class SystemRideSummarySharer implements RideSummarySharer {
  const SystemRideSummarySharer({this.exporter = const RideSummaryExporter()});

  final RideSummaryExporter exporter;

  @override
  Future<void> share(
    RideSession session,
    Iterable<RideEvent> events, {
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    Rect? sharePositionOrigin,
    // Present only when an instrumented build was recording (#419). One more
    // attachment on the share a rider already does, rather than a second flow
    // and a second decision at the end of a ride.
    String? diagnostics,
  }) async {
    final generatedAt = DateTime.now();
    final summary = exporter.summarize(
      session,
      events,
      generatedAt: generatedAt,
    );
    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: generatedAt,
    );
    final csvFileName = exporter.fileName(summary);
    final gpxFileName = exporter.trailFileName(summary);
    final diagnosticsFileName =
        'tail-end-charlie-diagnostics-'
        '${summary.rideCode}.txt';
    await SharePlus.instance.share(
      ShareParams(
        title: 'Ride summary ${summary.rideCode}',
        subject: 'Tail End Charlie summary ${summary.rideCode}',
        text: exporter.toPlainText(summary, distanceUnit: distanceUnit),
        files: [
          XFile.fromData(
            Uint8List.fromList(utf8.encode(exporter.toCsv(summary))),
            mimeType: 'text/csv',
            name: csvFileName,
          ),
          if (route != null)
            XFile.fromData(
              Uint8List.fromList(
                utf8.encode(const GpxExporter().export(route)),
              ),
              mimeType: 'application/gpx+xml',
              name: gpxFileName,
            ),
          if (diagnostics != null)
            XFile.fromData(
              Uint8List.fromList(utf8.encode(diagnostics)),
              mimeType: 'text/plain',
              name: diagnosticsFileName,
            ),
        ],
        fileNameOverrides: [
          csvFileName,
          if (route != null) gpxFileName,
          if (diagnostics != null) diagnosticsFileName,
        ],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}
