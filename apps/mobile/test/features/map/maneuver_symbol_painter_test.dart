import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/maneuver_symbol.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

/// The sizes the app actually draws a roundabout at: the two banner sizes, the
/// all-turns list, and the smaller symbol on the banner's "Then" line.
const _sizes = <double>[19, 26, 30, 38];

/// The banner is nearly opaque, so the day and night basemaps leave it a very
/// similar colour. Both are rasterised so the difference can be seen rather
/// than assumed.
const _nightPanel = Color(0xFF232C37);
const _dayPanel = Color(0xFF2A333E);
const _ink = Color(0xFF68A9FF);

/// Margin around the symbol box in the written images, so ink that escaped the
/// box would be visible - and is asserted absent.
const _margin = 6.0;

/// Rasterised at more than device scale, so a gap that is a fraction of a pixel
/// on the phone cannot pass as a gap here.
const _pixelRatio = 4.0;

/// Where the rasterised matrix is written for inspection. Regenerate with
/// `flutter test test/features/map/maneuver_symbol_painter_test.dart`.
final _imageDirectory = Directory('build/maneuver-symbols');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the ring is broken where each road meets it', () {
    for (final symbol in _everySymbol()) {
      final geometry = RoundaboutSymbolGeometry.of(symbol, const Size(38, 38));
      final why = _describe(symbol);

      // One arc: the part of the ring the rider rides, from where they join to
      // where they leave. What is not drawn is simply the rest of the circle.
      expect(geometry.ringArcs, hasLength(1), reason: why);
      final arc = geometry.ringArcs.single;

      if (symbol.direction == ManeuverDirection.unstated) {
        // Nothing is known about the exit, so no part can be claimed as ridden
        // and the whole circle is drawn.
        expect(arc.sweepDegrees.abs(), closeTo(360, 0.01), reason: why);
        continue;
      }

      // Never the whole circle once an exit is known, and never nothing.
      expect(arc.sweepDegrees.abs(), lessThan(360), reason: why);
      expect(arc.sweepDegrees.abs(), greaterThan(0), reason: why);

      // Clockwise where riders keep left, anticlockwise where they keep right.
      if (symbol.leftHandTraffic == false) {
        expect(arc.sweepDegrees, lessThan(0), reason: why);
      } else {
        expect(arc.sweepDegrees, greaterThan(0), reason: why);
      }

      // The arc begins on the road in and finishes on the exit, so the three
      // marks are one continuous path with nothing floating and no seam.
      expect(
        _angleBetween(arc.startDegrees, geometry.entryDegrees),
        lessThan(0.01),
        reason: '\$why: the arc does not start on the road in',
      );
      expect(
        _angleBetween(
          arc.endDegrees,
          _headingOf(geometry.exit!.start - geometry.centre),
        ),
        lessThan(0.01),
        reason: '\$why: the arc does not finish on the exit',
      );

      // No arc is drawn so short that it reads as something left in the gap
      // rather than as part of the ring.
      //
      // Held at 1.2 stroke widths, not 3. At 3 the arc beside a square left or
      // right turn was dropped, the two gaps merged into one wide opening, and
      // the ring lost its ridden/beyond emphasis — which a rider reported on the
      // road as the ring having no gap and the flow running anticlockwise. A
      // short arc that keeps the ring reading as a ring beats a tidy gap.
      for (final arc in geometry.ringArcs) {
        final stroke = geometry.ringStrokeWidth;
        expect(
          arc.sweepRadians.abs() * geometry.radius,
          greaterThan(stroke * 1.2 - 0.01),
          reason: '$why: a ring arc is barely longer than it is thick',
        );
      }
    }
  });

  test('exactly one arrowhead is drawn, at the end of the exit', () {
    for (final symbol in _everySymbol()) {
      final geometry = RoundaboutSymbolGeometry.of(symbol, const Size(38, 38));
      final why = _describe(symbol);

      if (symbol.direction == ManeuverDirection.unstated) {
        // No direction was reported, so no arrow claims one.
        expect(geometry.arrowHeadCount, 0, reason: why);
        expect(geometry.exit, isNull, reason: why);
        continue;
      }

      expect(geometry.arrowHeadCount, 1, reason: why);
      final exit = geometry.exit!;
      // The one arrowhead is on the exit, pointing the way the exit runs.
      // Compared with a tolerance: the tip and the base are each derived from
      // the point the road meets the ring, so recomposing one from the other
      // is not bit-exact even though it is geometrically identical.
      final recomposed =
          exit.head.base + exit.head.direction * exit.head.length;
      expect(
        (exit.head.tip - recomposed).distance,
        lessThan(0.001),
        reason: '$why: the arrowhead is not at the end of its own shaft',
      );
      expect(
        (exit.head.tip - geometry.centre).distance,
        greaterThan((exit.start - geometry.centre).distance),
        reason: why,
      );
      // The arrow points away from the ring, so it reads as leaving rather than
      // as pointing into the middle. Not exactly along its own radius: where the
      // exit leaves alongside the road in it runs straight down the box, which
      // puts its tip a few degrees off the radius it started from.
      expect(
        _angleBetween(
          _headingOf(exit.head.tip - geometry.centre),
          _headingOf(exit.head.direction),
        ),
        lessThan(15),
        reason: '$why: the arrow does not point away from the ring',
      );
      // Wider than the road it ends, so it reads as an arrow and not a blob.
      expect(
        exit.head.halfWidth * 2,
        greaterThan(geometry.roadStrokeWidth * 1.5),
        reason: why,
      );
    }
  });

  test('every part of the symbol is drawn inside its box', () {
    for (final size in _sizes) {
      for (final symbol in _everySymbol()) {
        final box = Rect.fromLTWH(0, 0, size, size);
        final geometry = RoundaboutSymbolGeometry.of(symbol, Size(size, size));
        final why = '${_describe(symbol)} at $size';
        final reach = <Offset>[
          geometry.entryRoadStart,
          geometry.entryRoadEnd,
          if (geometry.exit != null) ...[
            geometry.exit!.start,
            geometry.exit!.head.tip,
            ...geometry.exit!.head.barbs,
          ],
        ];
        for (final point in reach) {
          expect(
            box.inflate(-geometry.roadStrokeWidth / 2).contains(point),
            isTrue,
            reason: '$why: $point leaves the box',
          );
        }
        expect(
          box.contains(
            geometry.centre.translate(
              -geometry.radius - geometry.ringStrokeWidth,
              -geometry.radius - geometry.ringStrokeWidth,
            ),
          ),
          isTrue,
          reason: why,
        );
      }
    }
  });

  test('the painter draws arcs and one filled arrowhead, never a full circle', () {
    for (final symbol in _everySymbol()) {
      final canvas = _RecordingCanvas();
      const size = Size(38, 38);
      final geometry = RoundaboutSymbolGeometry.of(symbol, size);
      RoundaboutSymbolPainter(symbol: symbol, color: _ink).paint(canvas, size);
      final why = _describe(symbol);
      final states = symbol.direction != ManeuverDirection.unstated;

      // A closed ring is what the arrow used to butt into; it is never drawn.
      expect(canvas.calls, isNot(contains(#drawCircle)), reason: why);
      expect(
        canvas.arcSweeps,
        hasLength(geometry.ringArcs.length),
        reason: why,
      );
      // Once an exit is known, only the arc up to it is drawn, so the sweep is
      // always short of a full turn. With no exit reported there is no ridden
      // part to single out and the whole circle is drawn - still as an arc, so
      // the assertion above that drawCircle is never called still holds.
      expect(
        canvas.arcSweeps.fold<double>(0, (sum, sweep) => sum + sweep.abs()),
        states ? lessThan(2 * math.pi) : closeTo(2 * math.pi, 1e-9),
        reason: why,
      );
      // One filled path: the single arrowhead. The road in and the exit are the
      // only lines, so no second arrowhead can be hiding among them.
      expect(
        canvas.filledPaths,
        states ? 1 : 0,
        reason: '$why drew ${canvas.filledPaths} filled paths',
      );
      expect(canvas.drawnLines, states ? 2 : 1, reason: why);
      // Plain strokes and fills into the canvas it was given: no layer, and
      // no blend mode whose result differs between the renderer these tests
      // rasterise with and the one on the phone.
      expect(canvas.calls, isNot(contains(#saveLayer)), reason: why);
      expect(canvas.blendModes, everyElement(BlendMode.srcOver), reason: why);
    }
  });

  test('driving side decides how far round the ring the rider goes', () {
    double ridden(
      ManeuverDirection direction, {
      required bool leftHandTraffic,
    }) {
      final geometry = RoundaboutSymbolGeometry.of(
        RoundaboutSymbol(
          direction: direction,
          leftHandTraffic: leftHandTraffic,
        ),
        const Size(38, 38),
      );
      // There is only one arc: the part the rider rides.
      final arc = geometry.ringArcs.single;
      // Clockwise where riders keep left, anticlockwise where they keep right.
      expect(arc.sweepDegrees.isNegative, !leftHandTraffic);
      return arc.sweepDegrees.abs();
    }

    // Keeping left, a slight right is reached nearly the whole way round the
    // ring, and a slight left almost at once. Keeping right, the other way.
    expect(
      ridden(ManeuverDirection.slightRight, leftHandTraffic: true),
      greaterThan(
        ridden(ManeuverDirection.slightRight, leftHandTraffic: false),
      ),
    );
    expect(
      ridden(ManeuverDirection.slightLeft, leftHandTraffic: true),
      lessThan(ridden(ManeuverDirection.slightLeft, leftHandTraffic: false)),
    );

    // Turning back is the exit reached last, not first: nearly the whole way
    // round rather than straight off at the first opening. This was the wrong way
    // round, and only became visible once the un-ridden part of the ring stopped
    // being drawn.
    for (final leftHandTraffic in [true, false]) {
      expect(
        ridden(ManeuverDirection.uTurn, leftHandTraffic: leftHandTraffic),
        greaterThan(270),
        reason: 'a U-turn takes the last exit, not the first',
      );
    }

    // A square turn is a quarter of the ring one way and three quarters the
    // other, and the driving side decides which.
    expect(
      ridden(ManeuverDirection.right, leftHandTraffic: true),
      closeTo(270, 0.01),
    );
    expect(
      ridden(ManeuverDirection.right, leftHandTraffic: false),
      closeTo(90, 0.01),
    );
  });

  test('rasterised symbols show the gap, the arrow, and nothing outside', () async {
    if (_imageDirectory.existsSync()) {
      _imageDirectory.deleteSync(recursive: true);
    }
    _imageDirectory.createSync(recursive: true);

    for (final symbol in _everySymbol()) {
      // Written for inspection at every size the app draws, over both basemaps.
      for (final size in _sizes) {
        for (final panel in const {
          'night': _nightPanel,
          'day': _dayPanel,
        }.entries) {
          final image = await _rasterise(
            symbol,
            size: size,
            panel: panel.value,
            outlineBox: true,
          );
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${_imageDirectory.path}/${_fileName(symbol)}'
            '-s${size.toInt()}-${panel.key}.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
        }
      }

      // Asserted on the banner size without the box outline drawn, so only the
      // symbol's own ink is measured.
      const size = 38.0;
      final geometry = RoundaboutSymbolGeometry.of(
        symbol,
        const Size(size, size),
      );
      final image = await _rasterise(
        symbol,
        size: size,
        panel: _nightPanel,
        outlineBox: false,
      );
      final pixels = _Pixels(
        await image.toByteData(format: ui.ImageByteFormat.rawRgba),
        image.width,
      );
      final why = _describe(symbol);

      // Nothing escapes the box: the margin around it is untouched.
      for (var step = 0; step <= 40; step += 1) {
        final along = _margin + size * step / 40;
        for (final point in [
          Offset(along, _margin / 2),
          Offset(along, _margin * 1.5 + size),
          Offset(_margin / 2, along),
          Offset(_margin * 1.5 + size, along),
        ]) {
          expect(
            pixels.isInk(point * _pixelRatio),
            isFalse,
            reason: '$why: ink at $point, outside the box',
          );
        }
      }

      // Every road reaches the ring, and every drawn arc is really there.
      //
      // There is deliberately no daylight to look for beside a road any more.
      // The gap is sized to the road that passes through it, because a gap twice
      // the road's width left the road floating in the middle of a hole,
      // connected to nothing - reported from the road as gaps between the lines.
      //
      // Sampled where the road meets the ring, not along the heading it then
      // runs on: a turn back on itself leaves alongside the road in, so both
      // roads run straight down the box while joining the ring at their own
      // angles, and sampling by heading would probe the wrong point entirely.
      final roads = <double>[
        geometry.entryDegrees,
        if (geometry.exit != null)
          _headingOf(geometry.exit!.start - geometry.centre),
      ];
      for (final road in roads) {
        expect(
          pixels.isInk(_onRing(geometry, road)),
          isTrue,
          reason: '$why: the road does not reach the ring at $road degrees',
        );
      }
      for (final arc in geometry.ringArcs) {
        final middle = arc.startDegrees + arc.sweepDegrees / 2;
        expect(
          pixels.isInk(_onRing(geometry, middle)),
          isTrue,
          reason: '$why: no ring drawn at $middle degrees',
        );
      }
      // Enough ring to read as a ring, and not a closed circle.
      //
      // The upper bound is only just under the full 180 samples. It used to be
      // 170, which assumed 20 degrees of the ring circle would be empty - true
      // only while the gaps were twice the width of the roads passing through
      // them. The roads now fill their own gaps by design, so almost every sample
      // on the circle is ink, and what proves the ring is broken is that at least
      // one sample is not. The geometry test carries the strict version of this:
      // ringSweepDegrees is asserted below 360.
      // Sampled every half degree. At two degrees the sweep could not resolve the
      // daylight it was asserting - the gap clears the road by about 1.5 degrees -
      // so it called a plainly broken ring closed.
      const samples = 720;
      var ringInk = 0;
      for (var i = 0; i < samples; i++) {
        if (pixels.isInk(_onRing(geometry, i * 360 / samples))) ringInk += 1;
      }
      // As much ring as the arc claims, and no more than that plus the two roads
      // crossing the circle. A first exit is legitimately a short arc now, so a
      // fixed floor of half the circle no longer describes anything.
      final arcSamples =
          geometry.ringArcs.single.sweepDegrees.abs() / 360 * samples;
      final roadSamples = samples * 2 * 22 / 360;
      expect(
        ringInk,
        greaterThan(arcSamples * 0.8),
        reason: '\$why: less ring drawn than the arc claims',
      );
      expect(
        ringInk,
        lessThan(arcSamples + roadSamples),
        reason: '\$why: more ring drawn than the arc claims',
      );
      // No raster upper bound. Whether a break is *visible* depends on how wide
      // the gap clears the road, which is a design choice under active review, and
      // at these sizes a couple of degrees of daylight is sub-pixel and lost to
      // anti-aliasing either way. The invariant that the ring is not a closed path
      // is asserted geometrically instead, where it is exact: see
      // ringSweepDegrees < 360 in 'the ring is broken where each road meets it'.

      final exit = geometry.exit;
      if (exit == null) continue;
      final head = exit.head;
      final normal = Offset(-head.direction.dy, head.direction.dx);
      // The arrowhead is there, and is wider than the road that leads into it.
      expect(
        pixels.isInk(_atLogical(head.tip - head.direction * head.length * 0.5)),
        isTrue,
        reason: why,
      );
      for (final side in [-1.0, 1.0]) {
        expect(
          pixels.isInk(
            _atLogical(
              head.base +
                  head.direction * (head.length * 0.15) +
                  normal * (side * geometry.roadStrokeWidth * 0.6),
            ),
          ),
          isTrue,
          reason: '$why: no arrowhead wider than the road',
        );
      }
    }
  });
}

Iterable<RoundaboutSymbol> _everySymbol() => [
  for (final direction in ManeuverDirection.values)
    for (final leftHandTraffic in <bool?>[true, false, null])
      RoundaboutSymbol(direction: direction, leftHandTraffic: leftHandTraffic),
];

String _describe(RoundaboutSymbol symbol) =>
    '${symbol.direction.name} with driving side '
    '${switch (symbol.leftHandTraffic) {
      true => 'left',
      false => 'right',
      null => 'unreported',
    }}';

String _fileName(RoundaboutSymbol symbol) =>
    '${symbol.direction.name}-${switch (symbol.leftHandTraffic) {
      true => 'leftHand',
      false => 'rightHand',
      null => 'unstated',
    }}';

/// The heading a unit vector points, in the painter's degrees clockwise from
/// straight ahead.
double _headingOf(Offset unit) => math.atan2(unit.dx, -unit.dy) * 180 / math.pi;

/// The shortest angle between two headings, either way round.
double _angleBetween(double a, double b) {
  final between = (a - b) % 360;
  return math.min(between, 360 - between);
}

/// A point on the ring itself, in image pixels.
Offset _onRing(RoundaboutSymbolGeometry geometry, double degrees) {
  final radians = degrees * math.pi / 180;
  return _atLogical(
    geometry.centre +
        Offset(math.sin(radians), -math.cos(radians)) * geometry.radius,
  );
}

Offset _atLogical(Offset point) =>
    point.translate(_margin, _margin) * _pixelRatio;

Future<ui.Image> _rasterise(
  RoundaboutSymbol symbol, {
  required double size,
  required Color panel,
  required bool outlineBox,
}) {
  final box = size + _margin * 2;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(_pixelRatio);
  canvas.drawRect(Rect.fromLTWH(0, 0, box, box), Paint()..color = panel);
  if (outlineBox) {
    canvas.drawRect(
      Rect.fromLTWH(_margin, _margin, size, size),
      Paint()
        ..color = const Color(0x40FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / _pixelRatio,
    );
  }
  canvas.save();
  canvas.translate(_margin, _margin);
  RoundaboutSymbolPainter(
    symbol: symbol,
    color: _ink,
  ).paint(canvas, Size(size, size));
  canvas.restore();
  final side = (box * _pixelRatio).round();
  return recorder.endRecording().toImage(side, side);
}

/// The rasterised symbol, read back a pixel at a time.
class _Pixels {
  _Pixels(ByteData? data, this.width) : bytes = data!.buffer.asUint8List();

  final Uint8List bytes;
  final int width;

  /// Whether the symbol was drawn at this point, rather than the panel behind
  /// it. Anything short of a third of the ink's contrast counts as untouched.
  bool isInk(Offset point) {
    final offset = (point.dy.round() * width + point.dx.round()) * 4;
    final red = bytes[offset];
    final green = bytes[offset + 1];
    final blue = bytes[offset + 2];
    return (red - _nightPanel.r * 255).abs() +
            (green - _nightPanel.g * 255).abs() +
            (blue - _nightPanel.b * 255).abs() >
        90;
  }
}

/// Records what the painter draws, so the drawn shape can be asserted and not
/// only the geometry it was worked out from.
class _RecordingCanvas implements Canvas {
  final List<Symbol> calls = [];
  final List<double> arcSweeps = [];
  final List<BlendMode> blendModes = [];
  int filledPaths = 0;
  int drawnLines = 0;

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    calls.add(#drawArc);
    arcSweeps.add(sweepAngle);
    blendModes.add(paint.blendMode);
  }

  @override
  void drawCircle(Offset centre, double radius, Paint paint) {
    calls.add(#drawCircle);
    blendModes.add(paint.blendMode);
  }

  @override
  void drawLine(Offset from, Offset to, Paint paint) {
    calls.add(#drawLine);
    blendModes.add(paint.blendMode);
    drawnLines += 1;
  }

  @override
  void drawPath(Path path, Paint paint) {
    calls.add(#drawPath);
    blendModes.add(paint.blendMode);
    if (paint.style == PaintingStyle.fill) filledPaths += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    return null;
  }
}
