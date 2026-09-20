import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Kernels overlap adjacent cells, including diagonal neighbours. At country
/// scale keep coverage visible without claiming a precise road-width trace.
double heatmapCellRadiusPixels(
  double zoom,
  int resolution, {
  double tileSize = 256,
}) => math
    .max(8, 0.8 * tileSize * math.pow(2, zoom - resolution))
    .clamp(8, 1024)
    .toDouble();

/// Zoom remains the top-level interpolation input, as required by MapLibre.
/// The public source carries its privacy-preserving aggregation resolution.
List<Object> heatmapRadiusExpression({int? resolution}) => [
  'interpolate',
  ['exponential', 2],
  ['zoom'],
  for (var zoom = 0; zoom <= 22; zoom++) ...[
    zoom,
    if (resolution != null)
      heatmapCellRadiusPixels(zoom.toDouble(), resolution, tileSize: 512)
    else
      [
        'min',
        1024,
        [
          'max',
          8,
          [
            '*',
            409.6,
            [
              '^',
              2,
              [
                '-',
                zoom,
                ['get', 'resolution'],
              ],
            ],
          ],
        ],
      ],
  ],
];

class RideHeatPoint {
  const RideHeatPoint(this.point, this.weight);
  final LatLng point;
  final double weight;
}

class RideHeatmapLayer extends StatelessWidget {
  const RideHeatmapLayer({
    super.key,
    required this.points,
    required this.resolution,
    this.global = false,
  });
  final List<RideHeatPoint> points;
  final int resolution;
  final bool global;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: RideHeatmapPainter(
              points: [
                for (final point in points)
                  (
                    position: camera.latLngToScreenOffset(point.point),
                    weight: point.weight,
                  ),
              ],
              radius: heatmapCellRadiusPixels(camera.zoom, resolution),
              global: global,
            ),
          ),
        ),
      ),
    );
  }
}

/// A bounded canvas rather than thousands of circle widgets. Binning avoids
/// repainting the same country-scale pixel for every archived GPS cell. Samples
/// stay independent: this renderer never draws a line across a recording gap.
class RideHeatmapPainter extends CustomPainter {
  const RideHeatmapPainter({
    required this.points,
    required this.radius,
    this.global = false,
  });
  final List<({Offset position, double weight})> points;
  final double radius;
  final bool global;

  @override
  void paint(Canvas canvas, Size size) {
    final bins = <(int, int), ({Offset position, double weight})>{};
    final bounds = (Offset.zero & size).inflate(radius);
    for (final point in points) {
      if (!bounds.contains(point.position) || !point.weight.isFinite) continue;
      final key = (
        (point.position.dx / 3).floor(),
        (point.position.dy / 3).floor(),
      );
      final previous = bins[key];
      if (previous == null || previous.weight < point.weight) bins[key] = point;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final point in bins.values) {
      final weight = point.weight.clamp(0.0, 1.0);
      final color = Color.lerp(
        global ? const Color(0xFF0EA5E9) : const Color(0xFF7C3AED),
        const Color(0xFFF97316),
        weight,
      )!;
      canvas.drawCircle(
        point.position,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(
            point.position,
            radius,
            [
              color.withValues(alpha: 0.35 + 0.2 * weight),
              color.withValues(alpha: 0.22 + 0.12 * weight),
              color.withValues(alpha: 0),
            ],
            const [0, 0.45, 1],
          ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(RideHeatmapPainter old) =>
      points != old.points || radius != old.radius || global != old.global;
}
