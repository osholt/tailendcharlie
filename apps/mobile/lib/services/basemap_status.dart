import 'dart:convert';

import 'package:http/http.dart' as http;

import 'map_style_repository.dart';

/// What the ride map is actually drawing behind the rider's position and trail.
///
/// The live map had no equivalent of the recap screen's `_mapFailed`, so a
/// failed style, an unreachable tile endpoint and a genuinely empty stretch of
/// countryside all rendered the same way: a dot and a tail on a dark
/// background, with no words attached. A rider could not tell us which had
/// happened and neither could we from a screenshot, which is why #281 sat
/// undiagnosed through three passes. Every value here except [drawing] is
/// something the app already knew and did not say.
enum BasemapStatus {
  /// Roads and place names are being drawn. Whatever the rider cannot see is
  /// genuinely not there — this is the value that makes empty countryside
  /// distinguishable from a fault, by the absence of any badge.
  drawing,

  /// This build configures no MapLibre style at all. By design, not a fault.
  routeOnly,

  /// A style is configured but could not be fetched and nothing usable was
  /// cached, so the map is rendering the empty fallback style.
  styleUnavailable,

  /// The style loaded and names its tile endpoint, but that endpoint could not
  /// be reached. A different fault from [styleUnavailable] with the same
  /// appearance: the style's background colour paints, and no road ever
  /// arrives.
  tilesUnavailable,

  /// The style was resolved, but the platform map view never reported loading
  /// it. Nothing downstream of the view can run, including the app's own route
  /// and trail layers.
  viewNeverLoaded;

  /// The short badge shown on the map itself. Upper case to sit with the other
  /// map badges, and short enough not to crowd the chrome rail.
  String get badgeLabel => switch (this) {
    BasemapStatus.drawing => '',
    BasemapStatus.routeOnly => 'ROUTE-ONLY OFFLINE MAP',
    BasemapStatus.styleUnavailable => 'NO MAP BACKGROUND',
    BasemapStatus.tilesUnavailable => 'NO MAP DATA',
    BasemapStatus.viewNeverLoaded => 'MAP DID NOT LOAD',
  };

  /// What actually happened, in the words a rider could repeat back to us. Each
  /// one names a different fault, because moving the badge from one of these to
  /// another is the whole point of reporting it.
  String get explanation => switch (this) {
    BasemapStatus.drawing => '',
    BasemapStatus.routeOnly =>
      'This build has no map background configured. Your route, position and '
          'trail are drawn from the phone and work offline.',
    BasemapStatus.styleUnavailable =>
      'The map background could not be downloaded, so roads and place names '
          'are missing. Your position and trail are still being recorded.',
    BasemapStatus.tilesUnavailable =>
      'The map background loaded but its map data could not be reached, so '
          'roads and place names are missing. Your position and trail are '
          'still being recorded.',
    BasemapStatus.viewNeverLoaded =>
      'The map view did not finish loading. Your position and trail are still '
          'being recorded, but nothing is being drawn on the map.',
  };

  /// Whether this warrants telling the rider anything at all.
  bool get isFault => this != BasemapStatus.drawing;
}

/// Checks that the tile endpoint a resolved style names can actually be
/// reached.
///
/// The native map engine fetches tiles itself and reports nothing back through
/// the Flutter plugin, so a style that loads perfectly over a tile endpoint
/// that does not answer produces a blank map in complete silence. This is one
/// small request, made once per style after the view reports the style loaded,
/// purely so the map can distinguish that case from the two either side of it.
///
/// It is deliberately incapable of producing a false alarm: anything it cannot
/// work out — an unparseable style, a source with no usable endpoint, a tile
/// template using placeholders other than `{z}/{x}/{y}` — returns null, and a
/// null is reported as no fault rather than as a failure.
class BasemapTileProbe {
  const BasemapTileProbe({
    this.timeout = const Duration(seconds: 8),
    this.userAgent = 'me.osholt.ride_relay',
  });

  final Duration timeout;
  final String userAgent;

  /// True when the endpoint answered, false when it did not, and null when
  /// there was nothing to check.
  Future<bool?> reachable(String styleJson, {required http.Client client}) {
    final target = endpointFor(styleJson);
    if (target == null) return Future.value(null);
    return _get(target, client: client);
  }

  Future<bool?> _get(Uri target, {required http.Client client}) async {
    try {
      final request = http.Request('GET', target)
        ..headers['User-Agent'] = userAgent;
      final response = await client.send(request).timeout(timeout);
      // The body is drained rather than read: a vector tile can be hundreds of
      // kilobytes and none of it is wanted, only the fact that it arrived.
      await response.stream.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } on Object {
      return false;
    }
  }

  /// The single URL worth asking for, given a resolved style document.
  ///
  /// A source's TileJSON `url` is preferred over a tile template: it is the
  /// document the engine must fetch before any tile, and it is small. Exposed
  /// for tests, which is cheaper than asserting the choice through a mock
  /// client.
  static Uri? endpointFor(String styleJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(styleJson);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final sources = decoded['sources'];
    if (sources is! Map) return null;
    for (final source in sources.values) {
      if (source is! Map) continue;
      final url = source['url'];
      if (url is String) {
        final parsed = Uri.tryParse(url);
        if (parsed != null && parsed.isScheme('https')) return parsed;
      }
      final tiles = source['tiles'];
      if (tiles is! List) continue;
      for (final template in tiles) {
        if (template is! String) continue;
        final tile = _lowestZoomTile(template);
        if (tile != null) return tile;
      }
    }
    return null;
  }

  /// The `0/0/0` tile of a `{z}/{x}/{y}` template — the one tile that exists in
  /// every pyramid, so the probe never depends on where the rider happens to
  /// be. A template carrying any other placeholder is left alone rather than
  /// guessed at.
  static Uri? _lowestZoomTile(String template) {
    final substituted = template
        .replaceAll('{z}', '0')
        .replaceAll('{x}', '0')
        .replaceAll('{y}', '0');
    if (substituted.contains('{') || substituted.contains('}')) return null;
    final parsed = Uri.tryParse(substituted);
    if (parsed == null || !parsed.isScheme('https')) return null;
    return parsed;
  }
}

/// Folds a style resolution and everything observed since into one answer.
///
/// Kept out of the map widget so the decision can be tested on its own, and so
/// the precedence is stated once: a style that never arrived is reported ahead
/// of a view that never loaded, because the view had nothing to load.
///
/// A map that is merely still starting reports [BasemapStatus.drawing] and
/// therefore says nothing. Warning a rider about a map that is about to appear
/// would be the same fault as the one being fixed, in the other direction.
BasemapStatus resolveBasemapStatus({
  required MapStyleOutcome styleOutcome,
  required bool viewLoadedStyle,
  required bool viewLoadTimedOut,
  required bool? tilesReachable,
}) {
  if (styleOutcome == MapStyleOutcome.unconfigured) {
    return BasemapStatus.routeOnly;
  }
  if (styleOutcome == MapStyleOutcome.unavailable) {
    return BasemapStatus.styleUnavailable;
  }
  if (!viewLoadedStyle) {
    return viewLoadTimedOut
        ? BasemapStatus.viewNeverLoaded
        : BasemapStatus.drawing;
  }
  if (tilesReachable == false) return BasemapStatus.tilesUnavailable;
  return BasemapStatus.drawing;
}
