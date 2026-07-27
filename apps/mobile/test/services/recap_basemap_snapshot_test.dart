// Every way the recap basemap can fail, and what the rider is told (#157).
//
//   "The image export still isn't rendering map tiles and should have a toggle
//    for light and dark mode just for that image."
//
// The export must never ship an empty map silently. So the outcomes are explicit,
// each carries words for the rider, and the snapshot is injected rather than
// reached for - MapLibre's snapshot needs a platform view, which a host test
// cannot provide, and pretending otherwise is how #141 went wrong three times.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/recap_basemap_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A 1x1 image, standing in for a rasterised basemap.
  Future<ui.Image> stubImage(Uint8List _) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..color = const ui.Color(0xFF123456),
    );
    return recorder.endRecording().toImage(1, 1);
  }

  RecapBasemapSnapshotter snapshotter({
    Duration timeout = const Duration(milliseconds: 50),
  }) => RecapBasemapSnapshotter(timeout: timeout, decode: stubImage);

  test('a captured snapshot carries an image and says nothing', () async {
    final result = await snapshotter().capture(
      takeSnapshot: () async => Uint8List.fromList([1, 2, 3]),
      basemapConfigured: true,
    );

    expect(result.outcome, RecapBasemapOutcome.captured);
    expect(result.hasImage, isTrue);
    expect(
      result.degradedMessage,
      isNull,
      reason: 'nothing to explain when it worked',
    );
  });

  test(
    'no configured basemap says so instead of exporting a blank map',
    () async {
      final result = await snapshotter().capture(
        takeSnapshot: () async => Uint8List.fromList([1]),
        basemapConfigured: false,
      );

      expect(result.outcome, RecapBasemapOutcome.notConfigured);
      expect(result.hasImage, isFalse);
      expect(result.degradedMessage, contains('route outline only'));
    },
  );

  test('no snapshot capability is the same honest answer', () async {
    final result = await snapshotter().capture(
      takeSnapshot: null,
      basemapConfigured: true,
    );

    expect(result.outcome, RecapBasemapOutcome.notConfigured);
  });

  test(
    'a map that has not finished loading times out and says to retry',
    () async {
      final result = await snapshotter().capture(
        // Never completes: the style or its tiles are still loading, which is
        // exactly the race that would otherwise export empty tiles.
        takeSnapshot: () => Completer<Uint8List>().future,
        basemapConfigured: true,
      );

      expect(result.outcome, RecapBasemapOutcome.timedOut);
      expect(result.hasImage, isFalse);
      expect(
        result.degradedMessage,
        contains('Try again in a moment'),
        reason: 'the one failure a rider can do something about',
      );
    },
  );

  test('a throwing snapshot degrades rather than breaking Share', () async {
    final result = await snapshotter().capture(
      takeSnapshot: () async => throw StateError('platform view gone'),
      basemapConfigured: true,
    );

    expect(result.outcome, RecapBasemapOutcome.failed);
    expect(result.degradedMessage, isNotNull);
  });

  test('empty bytes are a failure, not an empty basemap', () async {
    final result = await snapshotter().capture(
      takeSnapshot: () async => Uint8List(0),
      basemapConfigured: true,
    );

    expect(
      result.outcome,
      RecapBasemapOutcome.failed,
      reason: 'zero bytes drawn as an image is the blank map being fixed',
    );
  });

  test('every unavailable outcome has words for the rider', () async {
    for (final outcome in RecapBasemapOutcome.values) {
      final snapshot = RecapBasemapSnapshot.unavailable(outcome);
      if (outcome == RecapBasemapOutcome.captured) continue;
      expect(
        snapshot.degradedMessage,
        isNotNull,
        reason: '${outcome.name} would fail silently',
      );
      expect(snapshot.degradedMessage, isNotEmpty);
    }
  });
}
