// Renders the reported-hazard symbols to PNG so they can be inspected by eye.
//
// The sibling of `render_roundabout_symbols.dart`, and it exists for the same
// reason: #127, #130 and #137 all changed a symbol, all passed their tests, and
// all shipped something that read wrongly on the road, because every one of those
// tests asserted on geometry values rather than on the drawn result. #135 adds a
// camera, a police shield and a road-defect triangle at three stages of age, in
// two badge shapes, over two basemaps. Run it and look at the output.
//
//   flutter test test/render_hazard_symbols.dart
//
// Writes build/hazard-render/<case>.png
//
// No fonts are needed: these symbols are vector paths, not icon-font glyphs,
// precisely so that `flutter test` - which ships no fonts and draws text as
// filled boxes - can render the real artwork.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/features/map/hazard_map_symbol.dart';
import 'package:ride_relay/features/map/route_trail_style.dart';

const _outputDirectory = 'build/hazard-render';

/// The badge box, and the scale each grid is drawn at so it can be judged.
const _tile = HazardMapSymbols.extentPixels;

/// Every symbol a rider can raise, in the order a rider meets them.
const _kinds = <String, HazardType>{
  'camera': HazardType.speedCamera,
  'police': HazardType.policeActivity,
  'pothole': HazardType.pothole,
};

Future<void> _write(
  String name,
  ui.Picture picture,
  int width,
  int height,
) async {
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_outputDirectory/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  stdout.writeln('wrote ${file.path}');
}

HazardMapSymbol _symbol(HazardType type, HazardMapFreshness freshness) =>
    HazardMapSymbols.symbolFor(
      glyph: HazardMapSymbols.glyphFor(type),
      severity: HazardSeverity.serious,
      freshness: freshness,
    );

/// Every kind against every freshness stage, on one basemap surface, at [scale].
///
/// Rows are kinds, columns are ages. Reading down a column says "can I tell a
/// camera from a police sighting"; reading along a row says "can I tell a fresh
/// report from one about to expire".
Future<void> _writeGrid({
  required String name,
  required Color background,
  required double scale,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const gutter = 10.0;
  final cell = (_tile + gutter) * scale;
  final width = cell * HazardMapFreshness.values.length + gutter * scale;
  final height = cell * _kinds.length + gutter * scale;

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = background,
  );

  var row = 0;
  for (final kind in _kinds.entries) {
    var column = 0;
    for (final freshness in HazardMapFreshness.values) {
      canvas.save();
      canvas.translate(
        gutter * scale + cell * column,
        gutter * scale + cell * row,
      );
      canvas.scale(scale);
      // A faint box at the badge's layout bounds, so a symbol drifting outside
      // them is obvious.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, _tile, _tile),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.4
          ..color = const Color(0x33FF0055),
      );
      HazardMapSymbolPainter(
        symbol: _symbol(kind.value, freshness),
      ).paint(canvas, const Size(_tile, _tile));
      canvas.restore();
      column += 1;
    }
    row += 1;
  }

  await _write(name, recorder.endRecording(), width.round(), height.round());
}

/// The badges at the size they really draw at, over both basemaps, side by side
/// with a rider badge for comparison - the thing they must not be confused with.
Future<void> _writeActualSize() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final symbols = <HazardMapSymbol>[
    for (final kind in _kinds.values)
      for (final freshness in HazardMapFreshness.values)
        _symbol(kind, freshness),
  ];
  const gutter = 6.0;
  final width = (_tile + gutter) * symbols.length + gutter;
  final surfaces = <Color>[
    RouteTrailStyle.darkBasemapSurfaces['background']!,
    RouteTrailStyle.darkBasemapSurfaces['motorway']!,
    RouteTrailStyle.lightBasemapSurfaces['minor road']!,
    RouteTrailStyle.lightBasemapSurfaces['motorway']!,
  ];
  final height = (_tile + gutter) * surfaces.length + gutter;

  var row = 0;
  for (final surface in surfaces) {
    final top = gutter + (_tile + gutter) * row;
    canvas.drawRect(
      Rect.fromLTWH(0, top - gutter / 2, width, _tile + gutter),
      Paint()..color = surface,
    );
    var column = 0;
    for (final symbol in symbols) {
      canvas.save();
      canvas.translate(gutter + (_tile + gutter) * column, top);
      HazardMapSymbolPainter(
        symbol: symbol,
      ).paint(canvas, const Size(_tile, _tile));
      canvas.restore();
      column += 1;
    }
    row += 1;
  }

  await _write(
    'actual-size-on-basemaps',
    recorder.endRecording(),
    width.round(),
    height.round(),
  );
}

/// One symbol, large, with a crosshair - for judging the glyph itself.
Future<void> _writeLarge(String name, HazardMapSymbol symbol) async {
  const scale = 8.0;
  const size = _tile * scale;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()..color = const Color(0xFF101216),
  );
  final guide = Paint()
    ..strokeWidth = 1
    ..color = const Color(0x33FF0055);
  canvas.drawLine(
    const Offset(size / 2, 0),
    const Offset(size / 2, size),
    guide,
  );
  canvas.drawLine(
    const Offset(0, size / 2),
    const Offset(size, size / 2),
    guide,
  );
  canvas.scale(scale);
  HazardMapSymbolPainter(
    symbol: symbol,
  ).paint(canvas, const Size(_tile, _tile));
  await _write(
    'large-$name',
    recorder.endRecording(),
    size.round(),
    size.round(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render hazard symbols for visual inspection', () async {
    for (final kind in _kinds.entries) {
      await _writeLarge(
        kind.key,
        _symbol(kind.value, HazardMapFreshness.fresh),
      );
    }
    await _writeLarge(
      'camera-fading',
      _symbol(HazardType.speedCamera, HazardMapFreshness.fading),
    );
    await _writeGrid(
      name: 'grid-dark-basemap',
      background: RouteTrailStyle.darkBasemapSurfaces['background']!,
      scale: 4,
    );
    await _writeGrid(
      name: 'grid-light-basemap',
      background: RouteTrailStyle.lightBasemapSurfaces['minor road']!,
      scale: 4,
    );
    await _writeActualSize();
  });
}
