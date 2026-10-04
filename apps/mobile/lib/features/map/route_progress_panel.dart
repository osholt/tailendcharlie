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
    this.strip = false,
  });

  final RouteJourneyProgress progress;
  final DistanceUnit distanceUnit;
  final bool showClock;
  final RidingDisplaySize displaySize;

  /// Lays the summary out as one full-width strip instead of a card (#848).
  ///
  /// Portrait gives the ETA a place in the bottom band, where it spans the band
  /// rather than floating in the middle of the map over the road ahead. A strip
  /// keeps the figures a rider glances at - time and distance left, and the
  /// arrival time - on one row and drops the line that only says how far has
  /// been ridden, which costs a row of band for the least useful number. The
  /// next stop and the way out of free-roam navigation keep their rows.
  final bool strip;

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
    final timeRemaining = progress.awaitingRejoin
        ? 'On route'
        : _durationLabel(progress.remainingTime);
    final arrival = _timeLabel(context, progress.arrivalTime);
    final nextName = progress.nextWaypointName;
    final nextDistance = progress.nextWaypointDistanceMeters;
    final nextArrival = _timeLabel(context, progress.nextWaypointArrivalTime);
    final scale = displaySize.scale;
    final enlarged = displaySize != RidingDisplaySize.small;
    final semantics = [
      progress.awaitingRejoin
          ? '${formatter.distance(progress.remainingDistanceMeters)} remaining on the planned route; rejoin distance and ETA pending'
          : '$timeRemaining and ${formatter.distance(progress.remainingDistanceMeters)} remaining',
      if (progress.travelledDistanceMeters > 0)
        '${formatter.distance(progress.travelledDistanceMeters)} ridden',
      if (arrival != '—') 'route ETA $arrival',
      if (nextName != null && nextDistance != null)
        'next stop $nextName, ${formatter.distance(nextDistance)}'
            '${nextArrival == '—' ? '' : ', ETA $nextArrival'}',
    ].join('. ');

    if (strip) {
      return Semantics(
        label: semantics,
        container: true,
        child: _buildStrip(
          formatter: formatter,
          timeRemaining: timeRemaining,
          arrival: arrival,
          nextArrival: nextArrival,
          scale: scale,
          enlarged: enlarged,
        ),
      );
    }

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
            if (progress.travelledDistanceMeters > 0)
              Text(
                '${formatter.distance(progress.travelledDistanceMeters)} ridden',
                key: const Key('eta-travelled-distance'),
                style: TextStyle(
                  color: const Color(0xFFF0F4F8),
                  fontSize: 11 * scale,
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    progress.awaitingRejoin
                        ? 'ETA after rejoining'
                        : enlarged
                        ? 'ETA $arrival'
                        : 'Route ETA $arrival',
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

  /// One row of figures, then the optional next stop and way out (#848).
  ///
  /// The figures sit in a [Wrap] rather than a [Row] of fixed siblings: at the
  /// larger riding sizes the time, the distance and the arrival no longer fit
  /// side by side on a narrow phone, and the contract in [RidingDisplaySize] is
  /// that enlarging never hides a figure - so they wrap onto a second line
  /// instead of being ellipsised.
  Widget _buildStrip({
    required MeasurementFormatter formatter,
    required String timeRemaining,
    required String arrival,
    required String nextArrival,
    required double scale,
    required bool enlarged,
  }) {
    final nextName = progress.nextWaypointName;
    final nextDistance = progress.nextWaypointDistanceMeters;
    // With nothing but the destination ahead the next stop *is* the figures in
    // the first row, so repeating them would spend a row of the band on nothing.
    // A named stop before the destination is information and keeps its row.
    final nextIsDestination =
        nextDistance != null &&
        (nextDistance - progress.remainingDistanceMeters).abs() <
            _destinationToleranceMeters;
    final primaryStyle = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w700,
      fontSize: 13 * scale,
    );
    final arrivalLabel = progress.awaitingRejoin
        ? 'ETA after rejoining'
        : 'ETA $arrival';
    final remainingDistance =
        '${formatter.distance(progress.remainingDistanceMeters)} left';
    return Container(
      key: const Key('route-progress-panel'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
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
              const SizedBox(width: 6),
              Expanded(
                child: Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (enlarged) ...[
                      Text(
                        timeRemaining,
                        key: const Key('eta-remaining-time'),
                        style: primaryStyle,
                      ),
                      Text(
                        remainingDistance,
                        key: const Key('eta-remaining-distance'),
                        style: primaryStyle,
                      ),
                    ] else
                      Text(
                        '$timeRemaining · $remainingDistance',
                        key: const Key('eta-remaining-time'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: primaryStyle,
                      ),
                    Text(
                      arrivalLabel,
                      key: const Key('eta-arrival'),
                      style: TextStyle(
                        color: const Color(0xFFF0F4F8),
                        fontSize: 12 * scale,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (nextName != null &&
              nextDistance != null &&
              !nextIsDestination) ...[
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
            const SizedBox(height: 2),
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
    );
  }
}

/// How close the next stop has to be to the remaining distance for it to count
/// as the destination itself. Twenty-five metres is the order of GPS error on a
/// stationary phone, so a stop that close to the end is not a separate place.
const double _destinationToleranceMeters = 25;

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
