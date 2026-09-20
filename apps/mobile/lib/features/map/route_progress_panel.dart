import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../domain/riding_display_size.dart';
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
    this.onStop,
    this.displaySize = RidingDisplaySize.small,
  });

  final RouteJourneyProgress progress;
  final DistanceUnit distanceUnit;
  final bool showClock;
  final RidingDisplaySize displaySize;

  /// Stops navigating, where the host offers a way out here (#615).
  ///
  /// On this card and not only in the overflow menu, because this card is the
  /// surface that says "you are navigating" — a rider looking to stop looks at
  /// the thing telling them they haven't. Offered in words, not an icon (#306).
  /// Null hides the action entirely; a ride's route is the group's and leaves
  /// through the ride's own controls.
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final formatter = MeasurementFormatter(distanceUnit);
    final timeRemaining = _durationLabel(progress.remainingTime);
    final arrival = _timeLabel(context, progress.arrivalTime);
    final nextName = progress.nextWaypointName;
    final nextDistance = progress.nextWaypointDistanceMeters;
    final nextArrival = _timeLabel(context, progress.nextWaypointArrivalTime);
    final scale = displaySize.scale;
    final enlarged = displaySize != RidingDisplaySize.small;
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
        constraints: BoxConstraints(maxWidth: 230 * scale),
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
                Icon(
                  Icons.route,
                  size: 15 * scale,
                  color: const Color(0xFFFFA04A),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: enlarged
                      ? Wrap(
                          spacing: 8,
                          children: [
                            Text(
                              timeRemaining,
                              key: const Key('eta-remaining-time'),
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13 * scale,
                              ),
                            ),
                            Text(
                              formatter.distance(
                                progress.remainingDistanceMeters,
                              ),
                              key: const Key('eta-remaining-distance'),
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13 * scale,
                              ),
                            ),
                          ],
                        )
                      : Text(
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
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    enlarged ? 'ETA $arrival' : 'Route ETA $arrival',
                    key: const Key('eta-arrival'),
                    maxLines: enlarged ? null : 1,
                    overflow: enlarged ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xFFF0F4F8),
                      fontSize: 11 * scale,
                      height: 1.35,
                    ),
                  ),
                ),
                if (showClock) ...[
                  const SizedBox(width: 7),
                  RideClock(
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12 * scale,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                ],
              ],
            ),
            if (nextName != null && nextDistance != null) ...[
              const SizedBox(height: 4),
              Container(height: 1, color: const Color(0x335E6B7B)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.flag_outlined,
                    size: 14 * scale,
                    color: const Color(0xFF9FC8FF),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      nextName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12 * scale,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${formatter.distance(nextDistance)} · $nextArrival',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        color: const Color(0xFFD7DEE7),
                        fontSize: 11 * scale,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (onStop != null) ...[
              const SizedBox(height: 4),
              Container(height: 1, color: const Color(0x335E6B7B)),
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: 32 * scale),
                child: TextButton.icon(
                  key: const Key('stop-navigating'),
                  onPressed: onStop,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFFB27A),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: Icon(Icons.close, size: 15 * scale),
                  label: Text(
                    'Stop navigating',
                    style: TextStyle(
                      fontSize: 12 * scale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
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
