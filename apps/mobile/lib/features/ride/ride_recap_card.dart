import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/measurement_formatter.dart';
import '../../services/ride_summary_exporter.dart';
import 'route_sketch.dart';

/// A shareable social-media summary card for a completed ride: route shape,
/// rider count, distance, ride time, and marker passes.
class RideRecapCard extends StatelessWidget {
  const RideRecapCard({
    super.key,
    required this.summary,
    required this.routePoints,
    this.distanceUnit = DistanceUnit.kilometres,
    this.mapLayer,
    this.basemapAttribution,
    this.dark = true,
  });

  final RideSummary summary;
  final List<GeoPoint> routePoints;
  final DistanceUnit distanceUnit;

  /// A Flutter-rendered map included directly in the exported image.
  ///
  /// This must never be a platform view: `RepaintBoundary.toImage` cannot see
  /// those. The production recap uses [FlutterVectorRoutePreview], so the map
  /// the rider frames is the map captured into the PNG (#157).
  final Widget? mapLayer;

  /// Rendered into the card, because a shared image leaves the app and the
  /// licence follows the picture rather than the screen it came from.
  final String? basemapAttribution;

  /// Which palette this export uses. A property of the image only: it never
  /// touches the app theme, the ride map, or anything stored.
  final bool dark;

  static const _background = Color(0xFF0D1117);
  static const _surface = Color(0xFF171D25);
  static const _accent = Color(0xFFFF7A1A);
  static const _muted = Color(0xFF8D98A7);

  /// Only the map panel changes with [dark]; the card itself keeps its identity
  /// so a shared recap still reads as this app's.
  static const _lightSurface = Color(0xFFE8EDF3);
  static const _lightMuted = Color(0xFF5A6472);

  @override
  Widget build(BuildContext context) {
    final formatter = MeasurementFormatter(distanceUnit);
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: _background),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Both halves shrink to fit rather than clipping, and neither can
              // starve the other.
              //
              // They were two `Flexible`s with `TextOverflow.ellipsis`. Two
              // flexible children with the same flex factor split the row
              // evenly whatever they need, so the app name got half the content
              // width — about 143 logical pixels at the export size — against
              // the roughly 170 it takes at this weight and letter spacing. It
              // clipped to "TAIL END CHA…" on every recap anyone shared (#308).
              //
              // Loose `Flexible` lets each side take less than its share, and
              // `BoxFit.scaleDown` only ever reduces: at the export size both
              // render at full size, and a narrower card shrinks them instead
              // of eating the words. The 3:2 split reflects what the two
              // strings actually need. Nothing here can end in an ellipsis,
              // which matters because this image leaves the app.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Flexible(
                    flex: 3,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'TAIL END CHARLIE',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: _accent,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    flex: 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        'RIDE ${summary.rideCode}',
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: _muted,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    width: double.infinity,
                    color: dark ? _surface : _lightSurface,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ?mapLayer,
                        if (routePoints.length < 2)
                          // #124: a ride with no route is valid, and its recap
                          // says so rather than failing.
                          Center(
                            child: Text(
                              'No recorded route for this ride',
                              style: TextStyle(
                                color: dark ? _muted : _lightMuted,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          )
                        else if (mapLayer == null)
                          // The fallback owns its route sketch. The live Flutter
                          // map already contains the geographically aligned
                          // route layer; painting this fixed sketch over it made
                          // the line stay put while the rider panned the map.
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: CustomPaint(
                              key: const Key('recap-route-sketch'),
                              size: Size.infinite,
                              painter: RouteSketchPainter(
                                normalizeRoutePoints(routePoints),
                              ),
                            ),
                          ),
                        if (basemapAttribution case final attribution?)
                          Positioned(
                            right: 6,
                            bottom: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xB30D1117),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                child: Text(
                                  attribution,
                                  key: const Key('recap-basemap-attribution'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 8,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _Stat(
                    icon: Icons.group_outlined,
                    label: 'Riders',
                    value: '${summary.riderCount}',
                  ),
                  _Stat(
                    icon: Icons.route_outlined,
                    label: 'Distance',
                    value: formatter.distance(summary.totalDistanceMeters),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _Stat(
                    icon: Icons.timer_outlined,
                    label: 'Ride time',
                    value: _duration(summary.rideDuration),
                  ),
                  _Stat(
                    icon: Icons.flag_outlined,
                    label: 'Marker passes',
                    value: '${summary.totalConfirmedPasses}',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Row(
      children: [
        Icon(icon, color: RideRecapCard._accent, size: 22),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                label,
                style: const TextStyle(
                  color: RideRecapCard._muted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
