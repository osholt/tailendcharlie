import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../services/measurement_formatter.dart';
import '../../services/route_journey_progress.dart';
import 'ride_clock.dart';

/// A compact, glanceable trip and next-stop summary for the moving map (#413).
class RouteProgressPanel extends StatelessWidget {
  const RouteProgressPanel({
    super.key,
    required this.progress,
    required this.distanceUnit,
    this.showClock = false,
  });

  final RouteJourneyProgress progress;
  final DistanceUnit distanceUnit;
  final bool showClock;

  @override
  Widget build(BuildContext context) {
    final formatter = MeasurementFormatter(distanceUnit);
    final timeRemaining = _durationLabel(progress.remainingTime);
    final arrival = _timeLabel(context, progress.arrivalTime);
    final nextName = progress.nextWaypointName;
    final nextDistance = progress.nextWaypointDistanceMeters;
    final nextArrival = _timeLabel(context, progress.nextWaypointArrivalTime);
    final semantics = [
      '$timeRemaining and ${formatter.distance(progress.remainingDistanceMeters)} remaining',
      if (arrival != '—') 'route ETA $arrival',
      if (nextName != null && nextDistance != null)
        'next stop $nextName, ${formatter.distance(nextDistance)}'
            '${nextArrival == '—' ? '' : ', ETA $nextArrival'}',
    ].join('. ');

    return Semantics(
      label: semantics,
      container: true,
      child: Container(
        key: const Key('route-progress-panel'),
        constraints: const BoxConstraints(maxWidth: 230),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: const Color(0xE6252E39),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x665E6B7B)),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 6)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.route, size: 15, color: Color(0xFFFFA04A)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '$timeRemaining · ${formatter.distance(progress.remainingDistanceMeters)} left',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (showClock) ...[
                  const SizedBox(width: 7),
                  const RideClock(
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                ],
              ],
            ),
            Text(
              'Route ETA $arrival',
              style: const TextStyle(
                color: Color(0xFFC4CDD8),
                fontSize: 11,
                height: 1.35,
              ),
            ),
            if (nextName != null && nextDistance != null) ...[
              const SizedBox(height: 4),
              Container(height: 1, color: const Color(0x335E6B7B)),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.flag_outlined,
                    size: 14,
                    color: Color(0xFF9FC8FF),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      nextName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${formatter.distance(nextDistance)} · $nextArrival',
                    style: const TextStyle(
                      color: Color(0xFFD7DEE7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _durationLabel(Duration? duration) {
  if (duration == null) return 'Time —';
  final minutes = (duration.inSeconds / 60).ceil();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainder = minutes.remainder(60);
  return remainder == 0 ? '$hours h' : '$hours h $remainder min';
}

String _timeLabel(BuildContext context, DateTime? time) => time == null
    ? '—'
    : MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(time));
