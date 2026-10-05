import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';
import 'package:ride_relay/services/discovery_layer_preferences.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/ride_plan_router.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic places; none is a rider's start, finish or home.
const _here = GeoPoint(latitude: 52.00, longitude: -1.00);
const _meet = GeoPoint(latitude: 52.02, longitude: -1.05);
const _cafe = GeoPoint(latitude: 52.10, longitude: -1.00);
const _pass = GeoPoint(latitude: 52.20, longitude: -1.00);
const _town = GeoPoint(latitude: 52.30, longitude: -1.00);

const _townPlace = RidePlanPlace(point: _town, label: 'Town');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a destination alone plans from the rider\'s location', (
    tester,
  ) async {
    final harness = _Harness(location: _here);
    await harness.open(tester, RidePlan.toDestination(_townPlace));

    expect(
      find.descendant(
        of: find.byKey(const Key('ride-plan-start')),
        matching: find.text('Your location'),
      ),
      findsOneWidget,
    );
    expect(harness.routing.calls.single.first, _here);
    expect(harness.routing.calls.single.last, _town);
    expect(_confirmLabel(tester), 'Start');

    await harness.confirm(tester);

    final outcome = harness.outcome!;
    expect(outcome.plan.startsAtCurrentLocation, isTrue);
    expect(outcome.route.waypoints.first.description, 'Current location');
    expect(outcome.route.waypoints.last.name, 'Town');
  });

  testWidgets('no fix yet waits for one instead of refusing the destination', (
    tester,
  ) async {
    final harness = _Harness(location: null);
    await harness.open(tester, RidePlan.toDestination(_townPlace));

    expect(harness.routing.calls, isEmpty);
    expect(find.textContaining('waiting for your location'), findsOneWidget);
    expect(_confirmButton(tester).onPressed, isNull);
    expect(harness.locationRequests, 1);

    harness.position.value = _here;
    await tester.pumpAndSettle();

    expect(harness.routing.calls.single.first, _here);
    expect(_confirmButton(tester).onPressed, isNotNull);
  });

  testWidgets('the start can be changed to a place and back', (tester) async {
    final harness = _Harness(location: _here);
    await harness.open(tester, RidePlan.toDestination(_townPlace));

    await harness.choosePlace(
      tester,
      rowButton: const Key('ride-plan-change-start'),
      query: 'meeting point',
      result: 'Meeting point, Shire',
    );

    expect(
      find.descendant(
        of: find.byKey(const Key('ride-plan-start')),
        matching: find.text('Meeting point'),
      ),
      findsOneWidget,
    );
    expect(harness.routing.calls.last.first, _meet);

    await _tapVisible(tester, find.byKey(const Key('ride-plan-change-start')));
    await tester.tap(find.byKey(const Key('place-search-current-location')));
    await tester.pumpAndSettle();

    expect(harness.routing.calls.last.first, _here);
    expect(
      find.descendant(
        of: find.byKey(const Key('ride-plan-start')),
        matching: find.text('Your location'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a place search only runs when it is submitted', (tester) async {
    final harness = _Harness(location: _here);
    await harness.open(tester, RidePlan.toDestination(_townPlace));

    await _tapVisible(tester, find.byKey(const Key('ride-plan-add-stop')));
    await tester.enterText(find.byKey(const Key('place-search-field')), 'cafe');
    await tester.pump();

    // Nominatim forbids autocomplete against the public instance
    // (docs/geocoder-decision.md).
    expect(harness.search.queries, isEmpty);

    await tester.tap(find.byKey(const Key('place-search-submit')));
    await tester.pumpAndSettle();
    expect(harness.search.queries, ['cafe']);
  });

  testWidgets('named stops are added, reordered and removed', (tester) async {
    final harness = _Harness(location: _here);
    await harness.open(tester, RidePlan.toDestination(_townPlace));

    await harness.choosePlace(
      tester,
      rowButton: const Key('ride-plan-add-stop'),
      query: 'cafe',
      result: 'Cafe, Shire',
    );
    await harness.choosePlace(
      tester,
      rowButton: const Key('ride-plan-add-stop'),
      query: 'pass',
      result: 'Pass, Shire',
    );
    expect(harness.routing.calls.last, [_here, _cafe, _pass, _town]);
    expect(_stopLabels(tester), ['Cafe', 'Pass']);

    await _tapVisible(
      tester,
      find.byKey(const Key('ride-plan-move-stop-up-1')),
    );
    expect(_stopLabels(tester), ['Pass', 'Cafe']);
    expect(harness.routing.calls.last, [_here, _pass, _cafe, _town]);

    await _tapVisible(tester, find.byKey(const Key('ride-plan-remove-stop-0')));
    expect(_stopLabels(tester), ['Cafe']);
    expect(harness.routing.calls.last, [_here, _cafe, _town]);

    await harness.confirm(tester);
    expect(harness.outcome!.route.waypoints.map((waypoint) => waypoint.name), [
      'Start',
      'Cafe',
      'Town',
    ]);
  });

  testWidgets('drawn adjustments are on the map, never in the stop list', (
    tester,
  ) async {
    final harness = _Harness(location: _here);
    final routed = await RidePlanRouter(routingService: harness.routing).route(
      RidePlan.toDestination(_townPlace)
          .addStop(const RidePlanPlace(point: _cafe, label: 'Cafe'))
          .withShapingPoints(const [
            RouteShapingPoint(
              id: 'drawn',
              point: GeoPoint(latitude: 52.2, longitude: -1.03),
              legIndex: 1,
            ),
          ]),
      currentLocation: _here,
    );
    harness.routing.calls.clear();

    await harness.open(
      tester,
      RidePlan.fromRoute(routed.route),
      route: routed.route,
    );

    // Already this plan, routed: nothing to recalculate on opening.
    expect(harness.routing.calls, isEmpty);
    expect(_stopLabels(tester), ['Cafe']);
    expect(find.byKey(const Key('ride-plan-stop-1')), findsNothing);
    await _scrollTo(tester, find.text('1 stop'));
    expect(find.text('1 stop'), findsOneWidget);
    await _scrollTo(tester, find.text('Adjustment 1'));
    expect(find.text('Adjustment 1'), findsOneWidget);
    expect(
      find.byKey(const Key('ride-plan-adjustments-heading')),
      findsOneWidget,
    );

    // Removing the stop keeps the adjustment as an adjustment.
    await _tapVisible(tester, find.byKey(const Key('ride-plan-remove-stop-0')));

    expect(_stopLabels(tester), isEmpty);
    expect(harness.routing.shapingIndexes.last, {1});
    await _scrollTo(tester, find.text('Adjustment 1'));
    expect(find.text('Adjustment 1'), findsOneWidget);
  });

  testWidgets('solo or group is chosen on the plan', (tester) async {
    final harness = _Harness(location: _here, offerCoordinationChoice: true);
    await harness.open(tester, RidePlan.toDestination(_townPlace));

    expect(find.byKey(const Key('ride-plan-party')), findsOneWidget);
    expect(_confirmLabel(tester), 'Start');

    await _tapVisible(tester, find.text('Group'));
    await tester.pumpAndSettle();
    expect(_confirmLabel(tester), 'Create group ride');

    await _tapVisible(
      tester,
      find.byKey(const Key('ride-plan-mode-keepTogether')),
    );

    await harness.confirm(tester);
    expect(
      harness.outcome!.plan.coordinationMode,
      RideCoordinationMode.keepTogether,
    );
    // Choosing company does not re-plan the route.
    expect(harness.routing.calls, hasLength(1));
  });

  testWidgets('route options re-plan the route in place', (tester) async {
    final harness = _Harness(location: _here);
    await harness.open(tester, RidePlan.toDestination(_townPlace));

    await _tapVisible(tester, find.text('Route options'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(const Key('avoid-motorways-switch')));
    await tester.pumpAndSettle();

    expect(harness.routing.preferences.last.avoidMotorways, isTrue);
    await harness.confirm(tester);
    expect(harness.outcome!.route.preferences?.avoidMotorways, isTrue);
  });

  testWidgets('a confirmed route reopens with its stops and can change', (
    tester,
  ) async {
    final harness = _Harness(location: _here);
    final confirmed = (await RidePlanRouter(routingService: harness.routing)
        .route(
          RidePlan.toDestination(
            _townPlace,
          ).addStop(const RidePlanPlace(point: _cafe, label: 'Cafe')),
          currentLocation: _here,
        ));
    harness.routing.calls.clear();

    await harness.open(
      tester,
      RidePlan.fromRoute(confirmed.route),
      route: confirmed.route,
      confirmLabel: 'Update route',
    );

    expect(_stopLabels(tester), ['Cafe']);
    expect(_confirmLabel(tester), 'Update route');

    await harness.choosePlace(
      tester,
      rowButton: const Key('ride-plan-add-stop'),
      query: 'pass',
      result: 'Pass, Shire',
    );
    await harness.confirm(tester);

    final outcome = harness.outcome!;
    expect(outcome.route.id, confirmed.route.id);
    expect(outcome.plan.stops.map((stop) => stop.label), ['Cafe', 'Pass']);
  });
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _scrollTo(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The review list builds lazily, so anything below the fold has to be
/// scrolled to before it exists to be found.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final list = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  if (finder.evaluate().isEmpty) {
    // Back to the top, then down until it is built.
    await tester.fling(list, const Offset(0, 3000), 3000);
    await tester.pumpAndSettle();
  }
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 120, scrollable: list);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

List<String> _stopLabels(WidgetTester tester) {
  final labels = <String>[];
  for (var index = 0; ; index += 1) {
    final finder = find.byKey(Key('ride-plan-stop-$index'));
    if (finder.evaluate().isEmpty) return labels;
    final title = tester.widget<ListTile>(finder).title! as Text;
    labels.add(title.data!);
  }
}

TextButton _confirmButton(WidgetTester tester) =>
    tester.widget<TextButton>(find.byKey(const Key('confirm-reviewed-route')));

String _confirmLabel(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('confirm-reviewed-route')),
        matching: find.byType(Text),
      ),
    )
    .data!;

class _Harness {
  _Harness({GeoPoint? location, this.offerCoordinationChoice = false})
    : position = ValueNotifier<GeoPoint?>(location);

  final ValueNotifier<GeoPoint?> position;
  final bool offerCoordinationChoice;
  final routing = _RecordingRouting();
  final search = _FakeSearch({
    'meeting point': const [
      DestinationMatch(label: 'Meeting point, Shire', point: _meet),
    ],
    'cafe': const [DestinationMatch(label: 'Cafe, Shire', point: _cafe)],
    'pass': const [DestinationMatch(label: 'Pass, Shire', point: _pass)],
  });
  int locationRequests = 0;
  RidePlanOutcome? outcome;

  Future<void> open(
    WidgetTester tester,
    RidePlan plan, {
    ImportedRoute? route,
    String? confirmLabel,
  }) async {
    final router = RidePlanRouter(routingService: routing);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                outcome = await RouteReviewScreen.showPlan(
                  context,
                  planning: RidePlanEditing(
                    plan: plan,
                    route: (plan, location) => router.route(
                      plan,
                      currentLocation: location,
                      base: route,
                    ),
                    searchService: search,
                    currentLocation: position,
                    acquireCurrentLocation: () async {
                      locationRequests += 1;
                      return position.value;
                    },
                    offerCoordinationChoice: offerCoordinationChoice,
                    confirmLabel: (plan) =>
                        confirmLabel ??
                        (plan.isGroup ? 'Create group ride' : 'Start'),
                  ),
                  route: route,
                  distanceUnit: DistanceUnit.kilometres,
                  basemapConfiguration: const BasemapConfiguration(),
                  pointOfInterestLoader: () async => BikerPlaceCatalogue.empty,
                  discoveryLoader: () async =>
                      const MotorcycleDiscoveryCatalogue([]),
                  discoveryPreferencesLoader: DiscoveryLayerPreferences.load,
                );
              },
              child: const Text('plan'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('plan'));
    await tester.pumpAndSettle();
  }

  Future<void> choosePlace(
    WidgetTester tester, {
    required Key rowButton,
    required String query,
    required String result,
  }) async {
    await _tapVisible(tester, find.byKey(rowButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('place-search-field')), query);
    await tester.tap(find.byKey(const Key('place-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('place-search-result-$result')));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    await tester.pumpAndSettle();
  }
}

class _RecordingRouting
    implements RoadRoutingService, ShapingPointRoadRoutingService {
  final calls = <List<GeoPoint>>[];
  final shapingIndexes = <Set<int>>[];
  final preferences = <RoutePreferences>[];

  Future<RoadRouteResult> _route(
    List<GeoPoint> waypoints,
    Set<int> shaping,
    RoutePreferences? preferences,
  ) async {
    calls.add(waypoints);
    shapingIndexes.add(shaping);
    this.preferences.add(preferences ?? RoutePreferences.defaults);
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: 20000 + 1000.0 * calls.length,
      duration: const Duration(minutes: 30),
      maneuvers: [RoadRouteManeuver(position: waypoints.last, type: 'arrive')],
    );
  }

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) => _route(waypoints, const {}, preferences);

  @override
  Future<RoadRouteResult> routeThroughShapingPoints(
    List<GeoPoint> waypoints, {
    required Set<int> shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    RoadRoutingCosting costing = RoadRoutingCosting.preferred,
    double? originBearingDegrees,
  }) => _route(waypoints, shapingPointIndexes, preferences);
}

class _FakeSearch implements DestinationSearchService {
  _FakeSearch(this.results);

  final Map<String, List<DestinationMatch>> results;
  final queries = <String>[];

  @override
  Future<List<DestinationMatch>> search(String query) async {
    queries.add(query);
    return results[query.toLowerCase()] ?? const [];
  }
}
