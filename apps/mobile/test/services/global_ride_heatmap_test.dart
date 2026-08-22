import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/global_ride_heatmap.dart';

void main() {
  test('trims both ends before quantising and preserves recording gaps', () {
    final ride = _ride([
      _path(51.45, -2.60, 51.45, -2.56),
      _path(52.45, -1.60, 52.45, -1.56),
    ]);
    final untrimmed = const HeatmapContributionBuilder().build(
      ride,
      trimMeters: 0,
    );
    final trimmed = const HeatmapContributionBuilder().build(
      ride,
      trimMeters: 1000,
    );

    expect(trimmed.cells, isNotEmpty);
    expect(trimmed.cells.length, lessThan(untrimmed.cells.length));
    expect(trimmed.cells.toSet().length, trimmed.cells.length);
    final originalStart = _tile(
      const GeoPoint(latitude: 51.45, longitude: -2.60),
    );
    final originalEnd = _tile(
      const GeoPoint(latitude: 52.45, longitude: -1.56),
    );
    expect(untrimmed.cells, containsAll([originalStart, originalEnd]));
    expect(trimmed.cells, isNot(contains(originalStart)));
    expect(trimmed.cells, isNot(contains(originalEnd)));
    expect(
      trimmed.cells.length,
      lessThan(80),
      reason: 'the two tracks must not be joined across the GPS gap',
    );
  });

  test('a short ride fully removed by endpoint hiding is not uploaded', () {
    final contribution = const HeatmapContributionBuilder().build(
      _ride([_path(51.45, -2.59, 51.45, -2.585)]),
      trimMeters: 500,
    );
    expect(contribution.isEmpty, isTrue);
  });

  test('bulk coverage trims rides separately and never joins them', () {
    final bristol = _ride([
      _path(51.45, -2.60, 51.46, -2.58),
    ], rideId: 'bristol');
    final london = _ride([_path(51.50, -0.14, 51.51, -0.12)], rideId: 'london');

    final contribution = const HeatmapContributionBuilder().buildMany([
      bristol,
      london,
    ], trimMeters: 0);

    expect(
      contribution.cells,
      contains(_tile(bristol.traveledRoute!.paths[0].points.first)),
    );
    expect(
      contribution.cells,
      contains(_tile(london.traveledRoute!.paths[0].points.last)),
    );
    expect(
      contribution.cells,
      isNot(contains(_tile(const GeoPoint(latitude: 51.48, longitude: -1.36)))),
      reason: 'separate saved rides must not be connected by an invented line',
    );
  });

  test('transport contains only shuffled cells and the chosen trim', () async {
    late Map<String, Object?> uploaded;
    final client = GlobalHeatmapClient(
      baseUri: Uri.parse('https://relay.example/api'),
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/heatmap/contributions');
        uploaded = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        return http.Response('{"accepted":true}', 200);
      }),
    );
    final credential = HeatmapCredential.generate();
    final contribution = const HeatmapContributionBuilder().build(
      _ride([_path(51.45, -2.59, 51.46, -2.58)]),
      trimMeters: 500,
    );

    await client.contribute(credential, contribution);

    expect(uploaded.keys, {
      'schemaVersion',
      'uploadId',
      'trimMetersAtEachEnd',
      'cells',
    });
    expect(uploaded['trimMetersAtEachEnd'], 500);
    final encoded = jsonEncode(uploaded).toLowerCase();
    for (final forbidden in [
      'rideid',
      'rider',
      'route',
      'timestamp',
      'speed',
      'latitude',
      'longitude',
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
  });

  test('credential proof is stable but does not expose the secret', () {
    const credential = HeatmapCredential(
      handle: 'hm1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      secret: 'hms1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
    );
    expect(credential.proof, startsWith('hmp1_'));
    expect(credential.proof, isNot(contains(credential.secret)));
    expect(credential.proof, credential.proof);
  });
}

RoutePath _path(double lat1, double lon1, double lat2, double lon2) =>
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: lat1, longitude: lon1),
        GeoPoint(latitude: lat2, longitude: lon2),
      ],
    );

(int, int) _tile(GeoPoint point) {
  final scale = (1 << HeatmapContributionBuilder.canonicalZoom).toDouble();
  final radians = point.latitude * math.pi / 180;
  return (
    ((point.longitude + 180) / 360 * scale).floor(),
    ((1 - math.log(math.tan(radians) + (1 / math.cos(radians))) / math.pi) /
            2 *
            scale)
        .floor(),
  );
}

CompletedRide _ride(List<RoutePath> paths, {String rideId = 'ride-private'}) =>
    CompletedRide(
      rideId: rideId,
      rideCode: '209271',
      rideName: 'Private ride name',
      localDisplayName: 'Private rider',
      localRole: RideRole.rider,
      startedAt: DateTime.utc(2026, 8, 16, 10),
      endedAt: DateTime.utc(2026, 8, 16, 12),
      archivedAt: DateTime.utc(2026, 8, 16, 12),
      riderCount: 1,
      eventCount: 100,
      totalDistanceMeters: 10000,
      markerSessions: const [],
      plannedRoute: null,
      traveledRoute: ImportedRoute(
        id: 'travelled',
        name: 'Travelled',
        importedAt: DateTime.utc(2026, 8, 16),
        sourceFileName: 'recording.gpx',
        paths: paths,
        waypoints: const [],
      ),
    );
