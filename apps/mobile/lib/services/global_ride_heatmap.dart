import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../domain/completed_ride.dart';
import '../domain/imported_route.dart';

enum HeatmapContributionConsent { never, askAfterEachRide, always }

enum GlobalHeatmapStatus { idle, loading, ready, empty, offline, failed }

class HeatmapCredential {
  const HeatmapCredential({required this.handle, required this.secret});

  final String handle;
  final String secret;

  String get authorization => 'Heatmap $handle.$secret';

  String get proof {
    final digest = Hmac(
      sha256,
      utf8.encode(secret),
    ).convert(utf8.encode('tail-end-charlie-heatmap-v1\n$handle'));
    return 'hmp1_${base64Url.encode(digest.bytes).replaceAll('=', '')}';
  }

  static HeatmapCredential generate({math.Random? random}) {
    final source = random ?? math.Random.secure();
    List<int> bytes() => List<int>.generate(32, (_) => source.nextInt(256));
    return HeatmapCredential(
      handle: 'hm1_${base64Url.encode(bytes()).replaceAll('=', '')}',
      secret: 'hms1_${base64Url.encode(bytes()).replaceAll('=', '')}',
    );
  }
}

abstract interface class HeatmapCredentialStore {
  Future<HeatmapCredential?> read();
  Future<void> write(HeatmapCredential credential);
  Future<void> delete();
}

class SecureHeatmapCredentialStore implements HeatmapCredentialStore {
  const SecureHeatmapCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _handleKey = 'global_heatmap_handle_v1';
  static const _secretKey = 'global_heatmap_secret_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<HeatmapCredential?> read() async {
    final values = await Future.wait([
      _storage.read(key: _handleKey),
      _storage.read(key: _secretKey),
    ]);
    if (values[0] == null || values[1] == null) return null;
    return HeatmapCredential(handle: values[0]!, secret: values[1]!);
  }

  @override
  Future<void> write(HeatmapCredential credential) async {
    await Future.wait([
      _storage.write(key: _handleKey, value: credential.handle),
      _storage.write(key: _secretKey, value: credential.secret),
    ]);
  }

  @override
  Future<void> delete() async {
    await Future.wait([
      _storage.delete(key: _handleKey),
      _storage.delete(key: _secretKey),
    ]);
  }
}

class HeatmapContribution {
  const HeatmapContribution({required this.cells, required this.trimMeters});

  final List<(int x, int y)> cells;
  final int trimMeters;

  bool get isEmpty => cells.isEmpty;

  Map<String, Object?> toJson({required String uploadId}) => {
    'schemaVersion': 1,
    'uploadId': uploadId,
    'trimMetersAtEachEnd': trimMeters,
    'cells': [
      for (final cell in cells) {'z': 17, 'x': cell.$1, 'y': cell.$2},
    ],
  };
}

/// Performs every privacy transformation before the transport boundary.
class HeatmapContributionBuilder {
  const HeatmapContributionBuilder({this.maximumCells = 20000});

  static const canonicalZoom = 17;
  final int maximumCells;

  HeatmapContribution build(CompletedRide ride, {required int trimMeters}) {
    if (![0, 500, 1000, 2000].contains(trimMeters)) {
      throw ArgumentError.value(trimMeters, 'trimMeters');
    }
    var paths =
        ride.traveledRoute?.paths
            .where((path) => path.kind == RoutePathKind.track)
            .map((path) => List<GeoPoint>.of(path.points))
            .where((points) => points.length >= 2)
            .toList(growable: true) ??
        <List<GeoPoint>>[];
    paths = _trimFromStart(paths, trimMeters.toDouble());
    paths = _trimFromEnd(paths, trimMeters.toDouble());
    final remainingMeters = paths.fold<double>(0, (total, path) {
      for (var index = 1; index < path.length; index += 1) {
        total += _distance(path[index - 1], path[index]);
      }
      return total;
    });
    if (remainingMeters < 1) {
      return HeatmapContribution(cells: const [], trimMeters: trimMeters);
    }
    final cells = <(int x, int y)>{};
    for (final path in paths) {
      for (var index = 1; index < path.length; index += 1) {
        for (final cell in _cellsBetween(path[index - 1], path[index])) {
          if (cells.length >= maximumCells && !cells.contains(cell)) continue;
          cells.add(cell);
        }
      }
    }
    final shuffled = cells.toList(growable: false)
      ..shuffle(math.Random.secure());
    return HeatmapContribution(cells: shuffled, trimMeters: trimMeters);
  }

  List<List<GeoPoint>> _trimFromStart(
    List<List<GeoPoint>> paths,
    double remaining,
  ) {
    final result = <List<GeoPoint>>[];
    for (final source in paths) {
      if (remaining <= 0) {
        result.add(source);
        continue;
      }
      final trimmed = <GeoPoint>[];
      for (var index = 1; index < source.length; index += 1) {
        final start = source[index - 1];
        final end = source[index];
        final length = _distance(start, end);
        if (remaining >= length) {
          remaining -= length;
          continue;
        }
        final fraction = length <= 0 ? 1.0 : remaining / length;
        trimmed.add(_interpolate(start, end, fraction));
        trimmed.addAll(source.skip(index));
        remaining = 0;
        break;
      }
      if (trimmed.length >= 2) result.add(trimmed);
    }
    return result;
  }

  List<List<GeoPoint>> _trimFromEnd(
    List<List<GeoPoint>> paths,
    double remaining,
  ) {
    final reversed = [
      for (final path in paths.reversed) path.reversed.toList(growable: false),
    ];
    return [
      for (final path in _trimFromStart(reversed, remaining).reversed)
        path.reversed.toList(growable: false),
    ];
  }

  Iterable<(int x, int y)> _cellsBetween(GeoPoint start, GeoPoint end) sync* {
    final a = _tile(start);
    final b = _tile(end);
    final steps = math.max(
      1,
      (math.max((b.$1 - a.$1).abs(), (b.$2 - a.$2).abs()) * 2).ceil(),
    );
    for (var index = 0; index <= steps; index += 1) {
      final fraction = index / steps;
      yield (
        (a.$1 + (b.$1 - a.$1) * fraction).floor(),
        (a.$2 + (b.$2 - a.$2) * fraction).floor(),
      );
    }
  }

  (double, double) _tile(GeoPoint point) {
    final scale = (1 << canonicalZoom).toDouble();
    final latitude = point.latitude.clamp(-85.05112878, 85.05112878);
    final radians = latitude * math.pi / 180;
    return (
      ((point.longitude + 180) / 360 * scale).clamp(0, scale - 0.000001),
      ((1 - math.log(math.tan(radians) + (1 / math.cos(radians))) / math.pi) /
              2 *
              scale)
          .clamp(0, scale - 0.000001),
    );
  }

  double _distance(GeoPoint a, GeoPoint b) {
    const radius = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final deltaLat = lat2 - lat1;
    final deltaLon = (b.longitude - a.longitude) * math.pi / 180;
    final value =
        math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLon / 2) *
            math.sin(deltaLon / 2);
    return radius * 2 * math.atan2(math.sqrt(value), math.sqrt(1 - value));
  }

  GeoPoint _interpolate(GeoPoint a, GeoPoint b, double fraction) => GeoPoint(
    latitude: a.latitude + (b.latitude - a.latitude) * fraction,
    longitude: a.longitude + (b.longitude - a.longitude) * fraction,
  );
}

class GlobalHeatmapCell {
  const GlobalHeatmapCell({required this.point, required this.weight});
  final GeoPoint point;
  final double weight;
}

class GlobalHeatmapSnapshot {
  const GlobalHeatmapSnapshot({
    required this.version,
    required this.date,
    required this.cells,
  });

  static const empty = GlobalHeatmapSnapshot(version: '', date: '', cells: []);
  final String version;
  final String date;
  final List<GlobalHeatmapCell> cells;

  Map<String, dynamic> toGeoJson() => {
    'type': 'FeatureCollection',
    'features': [
      for (var index = 0; index < cells.length; index += 1)
        {
          'type': 'Feature',
          'id': 'global-$version-$index',
          'properties': {'weight': cells[index].weight},
          'geometry': {
            'type': 'Point',
            'coordinates': [
              cells[index].point.longitude,
              cells[index].point.latitude,
            ],
          },
        },
    ],
  };

  factory GlobalHeatmapSnapshot.fromJson(Map<String, Object?> json) {
    final features = json['features'];
    if (features is! List) {
      throw const FormatException('Global heatmap is malformed.');
    }
    return GlobalHeatmapSnapshot(
      version: json['snapshotVersion'] as String? ?? '',
      date: json['snapshotDate'] as String? ?? '',
      cells: [
        for (final raw in features.whereType<Map>())
          if (raw['geometry'] case {'coordinates': final List coordinates})
            if (coordinates.length == 2 &&
                coordinates[0] is num &&
                coordinates[1] is num)
              GlobalHeatmapCell(
                point: GeoPoint(
                  latitude: (coordinates[1] as num).toDouble(),
                  longitude: (coordinates[0] as num).toDouble(),
                ),
                weight:
                    (((raw['properties'] as Map?)?['weight'] as num?)
                                ?.toDouble() ??
                            0.25)
                        .clamp(0, 1),
              ),
      ],
    );
  }
}

class GlobalHeatmapClient {
  GlobalHeatmapClient({required this.baseUri, http.Client? client})
    : _client = client ?? http.Client();

  final Uri? baseUri;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUri;
    if (base == null) {
      throw StateError('The global heatmap service is not configured.');
    }
    final basePath = base.path.replaceFirst(RegExp(r'/$'), '');
    return base.replace(path: '$basePath/$path', queryParameters: query);
  }

  Future<void> register(HeatmapCredential credential) async {
    final response = await _client.post(
      _uri('v1/heatmap/contributors'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'schemaVersion': 1,
        'clientHandle': credential.handle,
        'proof': credential.proof,
        'consentVersion': '2026-08-v1',
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw StateError('Heatmap registration failed (${response.statusCode}).');
    }
  }

  Future<void> contribute(
    HeatmapCredential credential,
    HeatmapContribution contribution,
  ) async {
    final response = await _client.post(
      _uri('v1/heatmap/contributions'),
      headers: {
        'content-type': 'application/json',
        'authorization': credential.authorization,
      },
      body: jsonEncode(contribution.toJson(uploadId: _randomUploadId())),
    );
    if (response.statusCode != 200) {
      throw StateError('Heatmap contribution failed (${response.statusCode}).');
    }
  }

  Future<void> revoke(HeatmapCredential credential) async {
    final response = await _client.delete(
      _uri('v1/heatmap/contributors/current'),
      headers: {'authorization': credential.authorization},
    );
    if (response.statusCode != 200 && response.statusCode != 401) {
      throw StateError('Heatmap revocation failed (${response.statusCode}).');
    }
  }

  Future<GlobalHeatmapSnapshot> fetch({
    required double west,
    required double south,
    required double east,
    required double north,
    required int zoom,
  }) async {
    final response = await _client.get(
      _uri('v1/heatmap/cells', {
        'west': '$west',
        'south': '$south',
        'east': '$east',
        'north': '$north',
        'zoom': '$zoom',
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('Global heatmap unavailable (${response.statusCode}).');
    }
    return GlobalHeatmapSnapshot.fromJson(
      Map<String, Object?>.from(jsonDecode(response.body) as Map),
    );
  }

  String _randomUploadId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'hmu1_${base64Url.encode(bytes).replaceAll('=', '')}';
  }
}
