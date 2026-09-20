import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../domain/imported_route.dart';
import 'basemap_configuration.dart';
import 'flutter_vector_style.dart';

enum MapPlaceKind { fuel, food, stop }

class MapPlace {
  const MapPlace({
    required this.id,
    required this.name,
    required this.kind,
    required this.point,
  });
  final String id;
  final String name;
  final MapPlaceKind kind;
  final GeoPoint point;
  String get label =>
      '${switch (kind) {
        MapPlaceKind.fuel => 'Fuel',
        MapPlaceKind.food => 'Food',
        MapPlaceKind.stop => 'Stop',
      }} · $name';
  bool visibleAt(double zoom) =>
      zoom >=
      switch (kind) {
        MapPlaceKind.fuel => 11,
        MapPlaceKind.food => 12,
        MapPlaceKind.stop => 13,
      };
}

/// OMT emits ordinary POIs only at z14. Fetch a bounded set of those tiles for
/// city views, then display their actual mapped points. Never invent labels or
/// assume changing a style's minzoom can create missing source features.
class MapPlacesService {
  MapPlacesService(
    this.configuration, {
    Future<vmt.Style> Function()? loadStyle,
  }) : _loadStyle =
           loadStyle ??
           (() => readFlutterVectorStyle(
             configuration.forBrightness(dark: false),
           ));
  final BasemapConfiguration configuration;
  final Future<vmt.Style> Function() _loadStyle;
  Future<vmt.Style>? _style;
  final Map<vmt.TileIdentity, List<MapPlace>> _decoded = {};
  bool get supported =>
      configuration.lightStyleUrl == BasemapConfiguration.defaultLightStyleUrl;

  static List<vmt.TileIdentity> tilesFor(
    List<GeoPoint> corners, {
    int maximum = 64,
  }) {
    if (corners.length < 2 || maximum <= 0) return const [];
    final south = corners.map((p) => p.latitude).reduce(math.min);
    final north = corners.map((p) => p.latitude).reduce(math.max);
    final west = corners.map((p) => p.longitude).reduce(math.min);
    final east = corners.map((p) => p.longitude).reduce(math.max);
    if (![south, north, west, east].every((v) => v.isFinite) ||
        east - west > 180 ||
        south < -85 ||
        north > 85) {
      return const [];
    }
    final nw = _project(north, west, 14), se = _project(south, east, 14);
    final cx = (nw.$1 + se.$1) / 2, cy = (nw.$2 + se.$2) / 2;
    // Never enumerate a whole country accidentally. At wider views, a centred
    // 64-tile neighbourhood bounds data use; pan to browse a different area.
    final minX = math.max(nw.$1, cx.floor() - 4),
        maxX = math.min(se.$1, cx.floor() + 4);
    final minY = math.max(nw.$2, cy.floor() - 4),
        maxY = math.min(se.$2, cy.floor() + 4);
    final tiles = [
      for (var x = minX; x <= maxX; x++)
        for (var y = minY; y <= maxY; y++) vmt.TileIdentity(14, x, y),
    ];
    tiles.sort(
      (a, b) => ((a.x - cx) * (a.x - cx) + (a.y - cy) * (a.y - cy)).compareTo(
        (b.x - cx) * (b.x - cx) + (b.y - cy) * (b.y - cy),
      ),
    );
    return tiles.take(maximum).toList();
  }

  Future<List<MapPlace>> load(
    List<GeoPoint> corners, {
    required bool Function() keepGoing,
  }) async {
    if (!supported || !keepGoing()) return const [];
    final tiles = tilesFor(corners);
    if (tiles.isEmpty) return const [];
    vmt.Style style;
    try {
      style = await (_style ??= _loadStyle());
    } on Object {
      _style = null;
      rethrow;
    }
    final provider = style.providers.tileProviderBySource['openmaptiles'];
    if (provider == null || provider.maximumZoom < 14) return const [];
    var next = 0;
    final results = <MapPlace>[];
    Future<void> worker() async {
      while (next < tiles.length && keepGoing()) {
        final tile = tiles[next++];
        try {
          final cached = _decoded.remove(tile);
          final List<MapPlace> places;
          if (cached == null) {
            final bytes = await provider
                .provide(tile)
                .timeout(const Duration(seconds: 15));
            if (!keepGoing()) return;
            places = await compute(_decode, (bytes, tile.x, tile.y, tile.z));
          } else {
            places = cached;
          }
          _decoded[tile] = places;
          while (_decoded.length > 128) {
            _decoded.remove(_decoded.keys.first);
          }
          results.addAll(places);
        } on Object {
          /* A failed tile must not erase the map or fabricate a place. */
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return results;
  }
}

List<MapPlace> _decode((Uint8List, int, int, int) input) =>
    decodeMapPlaces(input.$1, vmt.TileIdentity(input.$4, input.$2, input.$3));

List<MapPlace> decodeMapPlaces(Uint8List bytes, vmt.TileIdentity tile) {
  final layers = vtr.VectorTileReader().read(bytes).layers;
  final result = <MapPlace>[];
  for (final layer in layers.where((l) => l.name == 'poi')) {
    for (final feature in layer.features) {
      if (feature.type?.name != 'POINT') continue;
      final properties = feature.decodeProperties();
      final category =
          (properties['subclass']?.value ?? properties['class']?.value)
              ?.toString();
      final kind = switch (category) {
        'fuel' => MapPlaceKind.fuel,
        'cafe' || 'restaurant' || 'fast_food' => MapPlaceKind.food,
        'hotel' ||
        'motel' ||
        'hostel' ||
        'camp_site' ||
        'parking' ||
        'hospital' ||
        'toilets' => MapPlaceKind.stop,
        _ => null,
      };
      if (kind == null) continue;
      final rawName =
          (properties['name:latin']?.value ?? properties['name']?.value)
              ?.toString()
              .trim();
      final name = rawName == null || rawName.isEmpty
          ? category!.replaceAll('_', ' ')
          : rawName;
      for (final xy in feature.decodePoint()) {
        final size = 1 << tile.z;
        final worldX = (tile.x + xy[0] / layer.extent) / size;
        final worldY = (tile.y + xy[1] / layer.extent) / size;
        final radians = math.pi * (1 - 2 * worldY);
        final point = GeoPoint(
          latitude:
              math.atan((math.exp(radians) - math.exp(-radians)) / 2) *
              180 /
              math.pi,
          longitude: worldX * 360 - 180,
        );
        result.add(
          MapPlace(
            id: '${feature.id}:$category:${point.latitude.toStringAsFixed(5)}:${point.longitude.toStringAsFixed(5)}',
            name: name,
            kind: kind,
            point: point,
          ),
        );
      }
    }
  }
  return result;
}

List<MapPlace> selectMapPlaces(
  List<MapPlace> places,
  List<GeoPoint> corners,
  double zoom,
) {
  if (corners.length < 2 || zoom < 11 || zoom >= 14) return const [];
  final south = corners.map((p) => p.latitude).reduce(math.min),
      north = corners.map((p) => p.latitude).reduce(math.max);
  final west = corners.map((p) => p.longitude).reduce(math.min),
      east = corners.map((p) => p.longitude).reduce(math.max);
  final candidates = places
      .where(
        (p) =>
            p.visibleAt(zoom) &&
            p.point.latitude >= south &&
            p.point.latitude <= north &&
            p.point.longitude >= west &&
            p.point.longitude <= east,
      )
      .toList();
  final cx = (west + east) / 2, cy = (south + north) / 2;
  candidates.sort((a, b) {
    final kind = a.kind.index.compareTo(b.kind.index);
    if (kind != 0) return kind;
    double distance(MapPlace p) =>
        math.pow(p.point.latitude - cy, 2).toDouble() +
        math.pow(p.point.longitude - cx, 2).toDouble();
    return distance(a).compareTo(distance(b));
  });
  final cells = <(int, int)>{}, ids = <String>{};
  final result = <MapPlace>[];
  final scale = 256 * math.pow(2, zoom);
  for (final place in candidates) {
    final lat = place.point.latitude * math.pi / 180;
    final x = (place.point.longitude + 180) / 360 * scale;
    final y =
        (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * scale;
    if (!ids.add(place.id) ||
        !cells.add(((x / 145).floor(), (y / 48).floor()))) {
      continue;
    }
    result.add(place);
    if (result.length == 32) break;
  }
  return result;
}

(int, int) _project(double latitude, double longitude, int z) {
  final n = 1 << z, r = latitude * math.pi / 180;
  return (
    ((longitude + 180) / 360 * n).floor().clamp(0, n - 1),
    ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)
        .floor()
        .clamp(0, n - 1),
  );
}
