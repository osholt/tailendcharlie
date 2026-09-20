import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/ride_heatmap_layer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('country overview remains visible and local kernels overlap a cell', () {
    for (final zoom in [3.0, 5.0, 8.0, 12.0]) {
      expect(heatmapCellRadiusPixels(zoom, 19), greaterThanOrEqualTo(8));
    }
    expect(heatmapCellRadiusPixels(19, 19), closeTo(204.8, 0.01));
    expect(heatmapCellRadiusPixels(6, 8), closeTo(51.2, 0.01));
    expect(
      heatmapCellRadiusPixels(19, 19, tileSize: 512),
      closeTo(409.6, 0.01),
    );
    final radius = heatmapCellRadiusPixels(15, 19);
    // Diagonally neighbouring cells must overlap, not merely touch.
    expect(radius * 2, greaterThan(256 / 16 * 1.4143));
  });

  test(
    'heat fades softly and joins neighbours without connecting distant tracks',
    () async {
      final recorder = ui.PictureRecorder();
      const RideHeatmapPainter(
        points: [
          (position: Offset(50, 50), weight: 1.0),
          (position: Offset(90, 50), weight: 1.0),
          (position: Offset(230, 50), weight: 1.0),
        ],
        radius: 32,
      ).paint(Canvas(recorder), const Size(280, 100));
      final picture = recorder.endRecording();
      final image = await picture.toImage(280, 100);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int alpha(int x, int y) => data.getUint8((y * 280 + x) * 4 + 3);
      expect(
        alpha(70, 50),
        greaterThan(40),
        reason: 'no hole between neighbouring cells',
      );
      expect(
        alpha(50, 50),
        greaterThan(alpha(50, 72)),
        reason: 'blurred edge, not solid dots',
      );
      expect(alpha(50, 72), greaterThan(0));
      expect(alpha(160, 50), 0, reason: 'a real recording gap stays clear');
      image.dispose();
      picture.dispose();
    },
  );
}
