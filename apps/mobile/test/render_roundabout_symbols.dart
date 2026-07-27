// Renders the roundabout symbol to PNG so it can be inspected by eye.
//
// #127, #130 and #137 all changed this painter and all passed their tests, and the
// symbol was still wrong on the road three times. Every one of those tests asserted
// on geometry values rather than on the drawn result, so none of them could have
// caught a symbol that reads wrongly. This harness exists to close that gap: run it
// and look at the output.
//
//   flutter test test/render_roundabout_symbols.dart
//
// Writes build/roundabout-render/<case>.png

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/maneuver_symbol.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

const _outputDirectory = 'build/roundabout-render';
const _tile = 120.0;
const _largeTile = 300.0;

/// Every direction a roundabout exit can carry, including straight ahead, which
/// is the one reported drawn as a slight right.
const _cases = <String, ManeuverDirection>{
  'straight': ManeuverDirection.straight,
  'slight-right': ManeuverDirection.slightRight,
  'right': ManeuverDirection.right,
  'sharp-right': ManeuverDirection.sharpRight,
  'u-turn': ManeuverDirection.uTurn,
  'sharp-left': ManeuverDirection.sharpLeft,
  'left': ManeuverDirection.left,
  'slight-left': ManeuverDirection.slightLeft,
  'unstated': ManeuverDirection.unstated,
};

Future<void> _writeGrid({
  required String name,
  required bool? leftHandTraffic,
}) async {
  final recorder = ui.PictureRecorder();
  final columns = _cases.length;
  final width = _tile * columns;
  const height = _tile + 26;
  final canvas = Canvas(recorder);

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF101216),
  );

  var index = 0;
  for (final entry in _cases.entries) {
    final origin = Offset(_tile * index, 0);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);

    // A box outline, so a symbol drifting outside its bounds is obvious.
    canvas.drawRect(
      Rect.fromLTWH(4, 4, _tile - 8, _tile - 8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = const Color(0x33FFFFFF),
    );

    // Crosshair through the centre: straight ahead must run up this line.
    final centre = Offset(_tile / 2, _tile / 2);
    final guide = Paint()
      ..strokeWidth = 0.5
      ..color = const Color(0x22FF0055);
    canvas.drawLine(Offset(centre.dx, 4), Offset(centre.dx, _tile - 4), guide);
    canvas.drawLine(Offset(4, centre.dy), Offset(_tile - 4, centre.dy), guide);

    final symbol = RoundaboutSymbol(
      direction: entry.value,
      leftHandTraffic: leftHandTraffic,
      exitNumber: index + 1,
    );
    RoundaboutSymbolPainter(
      symbol: symbol,
      color: const Color(0xFFFFFFFF),
    ).paint(canvas, const Size(_tile, _tile));

    final label = TextPainter(
      text: TextSpan(
        text: entry.key,
        style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _tile);
    label.paint(canvas, Offset((_tile - label.width) / 2, _tile + 6));

    canvas.restore();
    index++;
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.round(), height.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_outputDirectory/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  stdout.writeln('wrote ${file.path}');
}

Future<void> _writeLarge(String key, ManeuverDirection direction) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, _largeTile, _largeTile),
    Paint()..color = const Color(0xFF101216),
  );
  const centre = Offset(_largeTile / 2, _largeTile / 2);
  final guide = Paint()
    ..strokeWidth = 1
    ..color = const Color(0x33FF0055);
  canvas.drawLine(Offset(centre.dx, 0), Offset(centre.dx, _largeTile), guide);
  canvas.drawLine(Offset(0, centre.dy), Offset(_largeTile, centre.dy), guide);
  RoundaboutSymbolPainter(
    symbol: RoundaboutSymbol(
      direction: direction,
      leftHandTraffic: true,
      exitNumber: 2,
    ),
    color: const Color(0xFFFFFFFF),
  ).paint(canvas, const Size(_largeTile, _largeTile));
  final image = await recorder.endRecording().toImage(
    _largeTile.round(),
    _largeTile.round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_outputDirectory/large-$key.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  stdout.writeln('wrote ${file.path}');
}

/// The sizes the banner and the all-turns list really draw at, rendered at 6x so
/// legibility at 19 and 26 logical pixels can be judged by eye.
Future<void> _writeActualSizes() async {
  const sizes = <double>[19, 26, 30, 38];
  const scale = 6.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final width = sizes.fold<double>(0, (a, s) => a + s * scale + 8);
  final height = 38 * scale + 8;
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF232C37),
  );
  var x = 4.0;
  for (final size in sizes) {
    canvas.save();
    canvas.translate(x, 4);
    canvas.scale(scale);
    RoundaboutSymbolPainter(
      symbol: const RoundaboutSymbol(
        direction: ManeuverDirection.right,
        leftHandTraffic: true,
        exitNumber: 3,
      ),
      color: const Color(0xFF68A9FF),
    ).paint(canvas, Size(size, size));
    canvas.restore();
    x += size * scale + 8;
  }
  final image = await recorder.endRecording().toImage(
    width.round(),
    height.round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_outputDirectory/actual-sizes-right.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  stdout.writeln('wrote ${file.path}');
}

/// Loads a real font so the exit number renders as a digit.
///
/// `flutter test` ships no fonts, so any text draws as a filled rectangle. That
/// is fine for layout assertions and useless for judging legibility, which is the
/// entire point of this harness.
Future<void> _loadFont() async {
  for (final path in [
    '/System/Library/Fonts/Supplemental/Arial.ttf',
    '/Library/Fonts/Arial Unicode.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader('Roboto')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    stdout.writeln('loaded font from $path');
    return;
  }
  stdout.writeln('WARNING no system font found; digits will draw as boxes');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render roundabout symbols for visual inspection', () async {
    await _loadFont();
    for (final key in [
      'straight',
      'slight-right',
      'right',
      'sharp-right',
      'u-turn',
    ]) {
      await _writeLarge(key, _cases[key]!);
    }
    await _writeGrid(name: 'left-hand-traffic-uk', leftHandTraffic: true);
    await _writeActualSizes();
    await _writeGrid(name: 'right-hand-traffic', leftHandTraffic: false);
    await _writeGrid(name: 'driving-side-unknown', leftHandTraffic: null);
  });
}
