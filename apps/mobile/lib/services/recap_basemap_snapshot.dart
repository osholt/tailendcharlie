import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Why a recap export has, or has not, got a basemap behind its route.
///
/// Every value other than [captured] must produce a usable image anyway: the
/// recap falls back to the plain route sketch and says which happened. An export
/// that silently ships an empty map is the bug this replaces (#157).
enum RecapBasemapOutcome {
  /// A basemap image was rasterised and can be drawn.
  captured,

  /// No basemap is configured on this build, so there is nothing to snapshot.
  notConfigured,

  /// The map had not finished loading its style or tiles in time.
  timedOut,

  /// The snapshot call failed, or returned bytes that are not an image.
  failed,
}

@immutable
class RecapBasemapSnapshot {
  const RecapBasemapSnapshot._({required this.outcome, this.image});

  const RecapBasemapSnapshot.captured(ui.Image image)
    : this._(outcome: RecapBasemapOutcome.captured, image: image);

  const RecapBasemapSnapshot.unavailable(RecapBasemapOutcome outcome)
    : this._(outcome: outcome);

  final RecapBasemapOutcome outcome;
  final ui.Image? image;

  bool get hasImage => image != null;

  /// What the rider is told when there is no basemap. Never silence: a recap
  /// without tiles is the reported defect, so if it happens again it says so.
  String? get degradedMessage => switch (outcome) {
    RecapBasemapOutcome.captured => null,
    RecapBasemapOutcome.notConfigured =>
      'No map style is configured on this build, so the recap shows the route '
          'outline only.',
    RecapBasemapOutcome.timedOut =>
      'The map did not finish loading in time, so the recap shows the route '
          'outline only. Try again in a moment.',
    // "Load" rather than "capture": the same outcome now describes both the
    // snapshot path and the live recap map, and a rider does not care which
    // half of it failed.
    RecapBasemapOutcome.failed =>
      'The map could not load, so the recap shows the route outline only.',
  };
}

/// Rasterises the ride's basemap for the recap image.
///
/// Takes the snapshot through the map's own snapshot API rather than through
/// `RepaintBoundary.toImage`, because MapLibre draws in a platform view that
/// `toImage` cannot see - it would capture a blank rectangle. The bytes come back
/// here, are decoded to a `ui.Image`, and are handed to the card as an ordinary
/// image, so by capture time the export contains only Flutter-drawn layers.
class RecapBasemapSnapshotter {
  const RecapBasemapSnapshotter({
    this.timeout = const Duration(seconds: 6),
    this.decode = _decodeImage,
  });

  /// Long enough for a vector style to finish over a poor connection, short
  /// enough that Share does not appear to have hung. The export states the
  /// degraded outcome rather than waiting indefinitely.
  final Duration timeout;

  /// Injected so the decode step is testable without a real map.
  final Future<ui.Image> Function(Uint8List bytes) decode;

  /// [takeSnapshot] is `MapLibreMapController.takeSnapshot`. Passed in rather
  /// than reached for, so this is testable without a platform view - the one
  /// thing a widget test cannot provide.
  ///
  /// [basemapConfigured] is false on a build with no style, where there is
  /// nothing to snapshot and the honest answer is to say so.
  Future<RecapBasemapSnapshot> capture({
    required Future<Uint8List> Function()? takeSnapshot,
    required bool basemapConfigured,
  }) async {
    if (takeSnapshot == null || !basemapConfigured) {
      return const RecapBasemapSnapshot.unavailable(
        RecapBasemapOutcome.notConfigured,
      );
    }
    try {
      final bytes = await takeSnapshot().timeout(timeout);
      if (bytes.isEmpty) {
        return const RecapBasemapSnapshot.unavailable(
          RecapBasemapOutcome.failed,
        );
      }
      return RecapBasemapSnapshot.captured(await decode(bytes));
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Recap basemap snapshot failed: $error\n$stackTrace');
      }
      // A timeout is worth distinguishing: it is the one a rider can fix by
      // waiting a moment and pressing Share again.
      return RecapBasemapSnapshot.unavailable(
        error is TimeoutException
            ? RecapBasemapOutcome.timedOut
            : RecapBasemapOutcome.failed,
      );
    }
  }
}

Future<ui.Image> _decodeImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}
