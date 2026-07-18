import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

import '../domain/ride_event.dart';
import '../domain/ride_session.dart';

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
  });

  final String rideId;
  final String rideCode;
  final String displayName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime generatedAt;
  final int eventCount;
  final List<MarkerSessionSummary> markerSessions;

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

  RideSummary summarize(
    RideSession session,
    Iterable<RideEvent> events, {
    required DateTime generatedAt,
  }) {
    final ordered = events.toList(growable: false)
      ..sort((left, right) {
        final time = left.createdAt.compareTo(right.createdAt);
        return time != 0 ? time : left.id.compareTo(right.id);
      });
    final startedAt = ordered.isEmpty
        ? session.joinedAt
        : _earlier(session.joinedAt, ordered.first.createdAt);
    final endedAt = ordered
        .where((event) => event.type == RideEventType.rideEnded)
        .map((event) => event.createdAt)
        .lastOrNull;

    final completed = <MarkerSessionSummary>[];
    final active = <String, _MarkerAccumulator>{};
    for (final event in ordered) {
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

    return RideSummary(
      rideId: session.rideId,
      rideCode: session.rideCode,
      displayName: session.displayName,
      startedAt: startedAt,
      endedAt: endedAt,
      generatedAt: generatedAt,
      eventCount: ordered.length,
      markerSessions: List.unmodifiable(completed),
    );
  }

  String toPlainText(RideSummary summary) {
    final buffer = StringBuffer()
      ..writeln('Tail End Charlie summary · ${summary.rideCode}')
      ..writeln('Rider: ${summary.displayName}')
      ..writeln('Started: ${summary.startedAt.toLocal().toIso8601String()}')
      ..writeln(
        'Ended: ${summary.endedAt?.toLocal().toIso8601String() ?? 'ride still active'}',
      )
      ..writeln('Ride time: ${_duration(summary.rideDuration)}')
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
    Rect? sharePositionOrigin,
  });
}

class SystemRideSummarySharer implements RideSummarySharer {
  const SystemRideSummarySharer({this.exporter = const RideSummaryExporter()});

  final RideSummaryExporter exporter;

  @override
  Future<void> share(
    RideSession session,
    Iterable<RideEvent> events, {
    Rect? sharePositionOrigin,
  }) async {
    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.now(),
    );
    final fileName = exporter.fileName(summary);
    await SharePlus.instance.share(
      ShareParams(
        title: 'Ride summary ${summary.rideCode}',
        subject: 'Tail End Charlie summary ${summary.rideCode}',
        text: exporter.toPlainText(summary),
        files: [
          XFile.fromData(
            Uint8List.fromList(utf8.encode(exporter.toCsv(summary))),
            mimeType: 'text/csv',
            name: fileName,
          ),
        ],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}
