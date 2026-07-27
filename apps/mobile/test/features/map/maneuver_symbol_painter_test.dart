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

      expect(geometry.ringArcs, isNotEmpty, reason: why);
      // Not a closed path: the ring always stops short of a full turn, by at
      // least the width of the road passing through it.
      expect(geometry.ringSweepDegrees, lessThan(360), reason: why);
      expect(
        geometry.ringGapDegrees,
        greaterThan(geometry.ringGapHalfDegrees * 2 - 0.01),
        reason: why,
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
        final stroke = arc.segment == RoundaboutRingSegment.beyond
            ? geometry.beyondRingStrokeWidth
            : geometry.riddenRingStrokeWidth;
        expect(
          arc.sweepRadians.abs() * geometry.radius,
          greaterThan(stroke * 1.2 - 0.01),
          reason: '$why: a ring arc is barely longer than it is thick',
        );
      }

      // Every gap is where a road is, and every road has daylight either side.
      //
      // Measured where each road meets the ring, which is not the same as the
      // direction it then runs: where the exit leaves alongside the road in, both
      // roads run straight down the box while still joining the ring at their own
      // angles.
      final roads = <double>[
        geometry.entryDegrees,
        if (geometry.exit != null)
          _headingOf(geometry.exit!.start - geometry.centre),
      ];
      for (final arc in geometry.ringArcs) {
        for (final end in [arc.startDegrees, arc.endDegrees]) {
          for (final road in roads) {
            expect(
              _angleBetween(end, road),
              greaterThanOrEqualTo(geometry.ringGapHalfDegrees - 0.01),
              reason: '$why: an arc ends across the road at $road degrees',
            );
          }
        }
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
      final recomposed = exit.head.base + exit.head.direction * exit.head.length;
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
              -geometry.radius - geometry.riddenRingStrokeWidth,
              -geometry.radius - geometry.riddenRingStrokeWidth,
            ),
          ),
          isTrue,
          reason: why,
        );
      }
    }
  });

  test(
    'the painter draws arcs and one filled arrowhead, never a full circle',
    () {
      for (final symbol in _everySymbol()) {
        final canvas = _RecordingCanvas();
        const size = Size(38, 38);
        final geometry = RoundaboutSymbolGeometry.of(symbol, size);
        RoundaboutSymbolPainter(
          symbol: symbol,
          color: _ink,
        ).paint(canvas, size);
        final why = _describe(symbol);
        final states = symbol.direction != ManeuverDirection.unstated;

        // A closed ring is what the arrow used to butt into; it is never drawn.
        expect(canvas.calls, isNot(contains(#drawCircle)), reason: why);
        expect(
          canvas.arcSweeps,
          hasLength(geometry.ringArcs.length),
          reason: why,
        );
        expect(
          canvas.arcSweeps.fold<double>(0, (sum, sweep) => sum + sweep.abs()),
          lessThan(2 * math.pi),
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
    },
  );

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
      final arc = geometry.ringArcs
          .where((arc) => arc.segment == RoundaboutRingSegment.ridden)
          .single;
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

    // A square left or right exit leaves a short arc between the two roads. It
    // used to be dropped as a speck, which merged the two gaps into one wide
    // opening and left the ring as a single undirected arc — and a rider reported
    // exactly that on the road: the ring appeared to have no gap and to circulate
    // the wrong way. It is now kept, so both gaps stay distinct and the ring
    // keeps the ridden/beyond emphasis that shows which way round traffic goes.
    for (final direction in [ManeuverDirection.left, ManeuverDirection.right]) {
      for (final leftHandTraffic in <bool?>[true, false, null]) {
        final geometry = RoundaboutSymbolGeometry.of(
          RoundaboutSymbol(
            direction: direction,
            leftHandTraffic: leftHandTraffic,
          ),
          const Size(38, 38),
        );
        expect(geometry.ringArcs, hasLength(2));
        // Where the driving side is known, the ring says which way round the
        // rider goes; where it is not, neither arc may claim it.
        expect(
          geometry.ringArcs.map((arc) => arc.segment).toSet(),
          leftHandTraffic == null
              ? {RoundaboutRingSegment.undirected}
              : {
                  RoundaboutRingSegment.ridden,
                  RoundaboutRingSegment.beyond,
                },
        );
      }
    }

    // With no driving side reported, no part of the ring is claimed as ridden.
    for (final direction in ManeuverDirection.values) {
      final geometry = RoundaboutSymbolGeometry.of(
        RoundaboutSymbol(direction: direction, leftHandTraffic: null),
        const Size(38, 38),
      );
      expect(
        geometry.ringArcs.map((arc) => arc.segment),
        everyElement(RoundaboutRingSegment.undirected),
      );
    }
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

      // Daylight on both sides of every road where it crosses the ring, and
      // ink on the ring away from the roads.
      //
      // Taken from where the road meets the ring, not from the heading it then
      // runs on: a turn back on itself leaves alongside the road in, so both
      // roads run straight down the box while joining the ring at their own
      // angles, and sampling by heading would probe the wrong point entirely.
      final roads = <double>[
        geometry.entryDegrees,
        if (geometry.exit != null)
          _headingOf(geometry.exit!.start - geometry.centre),
      ];
      for (final road in roads) {
        expect(pixels.isInk(_onRing(geometry, road)), isTrue, reason: why);
        for (final side in [-1, 1]) {
          final beside = road + side * geometry.ringGapHalfDegrees * 0.75;
          expect(
            pixels.isInk(_onRing(geometry, beside)),
            isFalse,
            reason: '$why: no gap in the ring at $beside degrees',
          );
        }
      }
      var ringInk = 0;
      for (var degrees = 0; degrees < 360; degrees += 2) {
        if (pixels.isInk(_onRing(geometry, degrees.toDouble()))) ringInk += 1;
      }
      expect(ringInk, greaterThan(90), reason: '$why: too little ring drawn');
      expect(ringInk, lessThan(170), reason: '$why: the ring has no gap');

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
