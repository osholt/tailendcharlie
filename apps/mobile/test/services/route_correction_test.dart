import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_correction.dart';

void main() {
  test('corrected copy has its own identity and no invented actual timing', () {
    final source = original();
    final before = source.toJsonString();
    final copy = RouteCorrection.copyOf(source);
    expect(copy.id, isNot(source.id));
    expect(copy.derivedFromRouteId, source.id);
    expect(
      copy.sourceRouteId,
      isNull,
      reason: 'a later ride must compare against this edited plan itself',
    );
    expect(copy.plannedDuration, isNull);
    expect(copy.maneuvers, isEmpty);
    expect(copy.allPoints.every((point) => point.recordedAt == null), isTrue);
    final saved = ImportedRoute.fromJson(
      copy.withLibraryDetails(name: 'Fixed loop').toJson(),
    );
    expect(saved.derivedFromRouteId, source.id);
    expect(source.toJsonString(), before);
  });
  test(
    'selected detour is replaced by provider road geometry and undo source stays intact',
    () async {
      final copy = RouteCorrection.copyOf(original());
      final router = FakeRouter();
      final fixed = await RouteCorrection.replaceSection(copy, 1, 3, router);
      expect(router.requested!.first.longitude, .01);
      expect(router.requested!.last.longitude, .03);
      expect(
        fixed.paths.single.points.any((p) => p.latitude == .01),
        isFalse,
        reason: 'detour removed',
      );
      expect(
        fixed.paths.single.points.any((p) => p.latitude == .001),
        isTrue,
        reason: 'use the router shape, never a straight deletion chord',
      );
      expect(fixed.paths.single.points.first.longitude, 0);
      expect(fixed.paths.single.points.last.longitude, .04);
      expect(copy.paths.single.points[2].latitude, .01);
      expect(fixed.id, copy.id);
      expect(fixed.derivedFromRouteId, 'actual');
    },
  );
  test('trimming preserves gaps outside explicitly replaced sections', () {
    final draft = RouteCorrection.copyOf(
      ImportedRoute.fromJson({
        ...original().toJson(),
        'paths': [
          RoutePath(
            kind: RoutePathKind.track,
            points: original().paths.single.points.take(2).toList(),
          ).toJson(),
          RoutePath(
            kind: RoutePathKind.track,
            points: original().paths.single.points.skip(2).toList(),
          ).toJson(),
        ],
      }),
    );
    final trimmed = RouteCorrection.trim(draft, 1, 4);
    expect(trimmed.paths, hasLength(2));
    expect(trimmed.pathPointCount, 4);
    expect(() => RouteCorrection.trim(draft, 3, 1), throwsFormatException);
  });
  test(
    'failed or far-away router result cannot silently overwrite the selection',
    () async {
      final draft = RouteCorrection.copyOf(original());
      await expectLater(
        RouteCorrection.replaceSection(draft, 1, 3, FakeRouter(farAway: true)),
        throwsFormatException,
      );
      expect(draft.paths.single.points[2].latitude, .01);
    },
  );
}

ImportedRoute original() => ImportedRoute(
  id: 'actual',
  name: 'As ridden',
  importedAt: DateTime.utc(2026),
  sourceFileName: 'actual.gpx',
  plannedDuration: const Duration(hours: 1),
  paths: [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        for (var i = 0; i < 5; i++)
          GeoPoint(
            latitude: i == 2 ? .01 : 0,
            longitude: i * .01,
            recordedAt: DateTime.utc(2026).add(Duration(minutes: i)),
          ),
      ],
    ),
  ],
  waypoints: const [],
);

class FakeRouter implements RoadRoutingService {
  FakeRouter({this.farAway = false});
  final bool farAway;
  List<GeoPoint>? requested;
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> points, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    requested = points;
    return RoadRouteResult(
      points: [
        farAway ? const GeoPoint(latitude: 20, longitude: 20) : points.first,
        const GeoPoint(latitude: .001, longitude: .02),
        points.last,
      ],
      distanceMeters: 2200,
      duration: const Duration(minutes: 2),
    );
  }
}
