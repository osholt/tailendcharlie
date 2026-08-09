import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/road_routing.dart';

import 'osrm_maneuver_fixtures.dart';

void main() {
  _guidanceStateTests();
  // The mini-roundabout layer is a bundled asset.
  TestWidgetsFlutterBinding.ensureInitialized();
  _turnDirectionTests();
  const planner = NavigationGuidancePlanner();

  test('selects the next useful maneuver by monotonic route progress', () {
    final route = _route();

    final beforeFirst = planner.plan(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0.005),
      progressMeters: 556,
    );
    final afterFirst = planner.plan(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0.012),
      progressMeters: 1334,
    );

    expect(beforeFirst?.maneuver.name, 'First Road');
    expect(beforeFirst?.distanceMeters, closeTo(556, 15));
    expect(afterFirst?.maneuver.name, 'Second Road');
    expect(afterFirst?.distanceMeters, closeTo(890, 20));
  });

  test('holds the current instruction briefly while crossing the turn', () {
    final guidance = planner.plan(
      route: _route(),
      position: const GeoPoint(latitude: 0, longitude: 0.0101),
      progressMeters: 1123,
    );

    expect(guidance?.maneuver.name, 'First Road');
    expect(guidance?.distanceMeters, 0);
  });

  test('hides guidance when the rider is clearly away from the route', () {
    final guidance = planner.plan(
      route: _route(),
      position: const GeoPoint(latitude: 0.01, longitude: 0.005),
      progressMeters: 556,
    );

    expect(guidance, isNull);
  });

  test('keeps the next instruction visible when it is more than 5 km away', () {
    final route = ImportedRoute(
      id: 'long-leg',
      name: 'Long leg',
      importedAt: DateTime.utc(2026, 7, 29),
      sourceFileName: 'long-leg.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.2),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 0, longitude: 0.1),
          type: 'turn',
          modifier: 'left',
          name: 'Distant turn',
        ),
      ],
    );

    final assessment = planner.assess(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0),
      progressMeters: 0,
    );

    expect(assessment.state, NavigationGuidanceState.active);
    expect(assessment.guidance?.maneuver.name, 'Distant turn');
    expect(assessment.guidance!.distanceMeters, greaterThan(10000));
  });

  test('diagnoses every non-active guidance state', () {
    expect(
      planner.assess(route: null, position: null, progressMeters: 0).state,
      NavigationGuidanceState.noRoute,
    );
    expect(
      planner.assess(route: _route(), position: null, progressMeters: 0).state,
      NavigationGuidanceState.waitingForLocation,
    );
    expect(
      planner
          .assess(
            route: _route(),
            position: const GeoPoint(latitude: 0.01, longitude: 0.005),
            progressMeters: 556,
          )
          .state,
      NavigationGuidanceState.offRoute,
    );
    expect(
      planner
          .assess(
            route: _route(),
            position: const GeoPoint(latitude: 0, longitude: 0.02),
            progressMeters: 10000,
          )
          .state,
      NavigationGuidanceState.complete,
    );
    final noManeuvers = ImportedRoute(
      id: 'no-maneuvers',
      name: 'No manoeuvres',
      importedAt: DateTime.utc(2026, 7, 29),
      sourceFileName: 'no-maneuvers.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.01),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [],
    );
    expect(
      planner
          .assess(
            route: noManeuvers,
            position: const GeoPoint(latitude: 0, longitude: 0),
            progressMeters: 0,
          )
          .state,
      NavigationGuidanceState.noManeuvers,
    );
  });

  // A route without turn prompts and a route with no line at all shared one
  // message, so a rider whose map showed a perfectly good route was told turn
  // guidance was "unavailable for this route" and read it as a failure (#303).
  group('a route that cannot be narrated', () {
    ImportedRoute routeWith({
      required List<RoutePath> paths,
      List<RouteManeuver> maneuvers = const [],
    }) => ImportedRoute(
      id: 'r',
      name: 'R',
      importedAt: DateTime.utc(2026, 8, 2),
      sourceFileName: 'r.gpx',
      paths: paths,
      waypoints: const [],
      maneuvers: maneuvers,
    );

    const followableLine = RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.01),
      ],
    );

    test('a followable line without prompts says to follow the line', () {
      final assessment = planner.assess(
        route: routeWith(paths: const [followableLine]),
        position: const GeoPoint(latitude: 0, longitude: 0),
        progressMeters: 0,
      );

      expect(assessment.state, NavigationGuidanceState.noManeuvers);
      expect(
        assessment.message,
        NavigationGuidancePlanner.noTurnInstructionsMessage,
      );
      expect(
        assessment.message,
        contains('follow the line'),
        reason: 'the route is usable; only the prompts are missing',
      );
    });

    test('a route with no line at all says something different', () {
      final assessment = planner.assess(
        route: routeWith(paths: const []),
        position: const GeoPoint(latitude: 0, longitude: 0),
        progressMeters: 0,
      );

      expect(assessment.state, NavigationGuidanceState.noManeuvers);
      expect(assessment.message, NavigationGuidancePlanner.noRouteLineMessage);
    });

    test('a one-point line is treated as no line, not as no prompts', () {
      final assessment = planner.assess(
        route: routeWith(
          paths: const [
            RoutePath(
              kind: RoutePathKind.track,
              points: [GeoPoint(latitude: 0, longitude: 0)],
            ),
          ],
          // Manoeuvres present, so this cannot fall through the empty-manoeuvre
          // branch and must be caught by the path-length check.
          maneuvers: [
            RouteManeuver(
              position: const GeoPoint(latitude: 0, longitude: 0),
              type: 'turn',
              modifier: 'left',
            ),
          ],
        ),
        position: const GeoPoint(latitude: 0, longitude: 0),
        progressMeters: 0,
      );

      expect(assessment.message, NavigationGuidancePlanner.noRouteLineMessage);
    });

    test('the two messages are not the same words', () {
      // The whole point of the change. A single shared message is what made a
      // good route and a broken one indistinguishable on the ride.
      expect(
        NavigationGuidancePlanner.noTurnInstructionsMessage,
        isNot(NavigationGuidancePlanner.noRouteLineMessage),
      );
      // #325 now offers road matching during import and review. These remain
      // riding-state messages: someone who chose the original line should not
      // be sent back into route preparation while moving.
      for (final message in [
        NavigationGuidancePlanner.noTurnInstructionsMessage,
        NavigationGuidancePlanner.noRouteLineMessage,
      ]) {
        expect(message.toLowerCase(), isNot(contains('get directions')));
      }
    });
  });

  test('skips non-instructional route-engine steps', () {
    final route = ImportedRoute(
      id: 'route',
      name: 'Route',
      importedAt: DateTime.utc(2026, 7, 22),
      sourceFileName: 'route.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.02),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 0, longitude: 0.002),
          type: 'depart',
          modifier: 'straight',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 0, longitude: 0.01),
          type: 'turn',
          modifier: 'left',
          ref: 'A420',
        ),
      ],
    );

    final guidance = planner.plan(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0),
      progressMeters: 0,
    );

    expect(guidance?.maneuver.type, 'turn');
    expect(guidance?.roadLabel, 'A420');
  });

  test('includes a second manoeuvre when turns are close together', () {
    final route = ImportedRoute(
      id: 'close-turns',
      name: 'Close turns',
      importedAt: DateTime.utc(2026, 7, 24),
      sourceFileName: 'close-turns.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.003),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 0, longitude: 0.001),
          type: 'turn',
          modifier: 'left',
          name: 'First turn',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 0, longitude: 0.002),
          type: 'turn',
          modifier: 'right',
          name: 'Second turn',
        ),
      ],
    );

    final guidance = planner.plan(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0),
      progressMeters: 0,
    );

    expect(guidance?.maneuver.name, 'First turn');
    expect(guidance?.followingManeuver?.name, 'Second turn');
    expect(guidance?.followingDistanceMeters, closeTo(111, 5));
  });

  test('a UK roundabout ridden straight through is one instruction', () async {
    final route = await routeFromOsrmResponse(ukRoundaboutStraightOnResponse());

    final steps = planner.instructions(route);
    final roundabout = steps.first.instruction;

    // The engine reported joining the ring and leaving it, both as slight lefts.
    expect(route.maneuvers.map((maneuver) => maneuver.type), [
      'depart',
      'roundabout',
      'exit roundabout',
      'arrive',
    ]);
    expect(steps.map((step) => step.instruction.text), [
      '2nd exit, straight on',
      'Arrive at the destination',
    ]);
    expect(roundabout.kind, ManeuverKind.roundabout);
    expect(roundabout.direction, ManeuverDirection.straight);
    expect(roundabout.exitNumber, 2);
    expect(roundabout.stepCount, 2);
    // Driving side is kept for ring rendering only.
    expect(roundabout.leftHandTraffic, isTrue);
    expect(roundabout.lanes, hasLength(3));
    expect(roundabout.roadLabel, 'Wells Road · A37');
  });

  test(
    'a third-exit roundabout states the exit number and direction',
    () async {
      final route = await routeFromOsrmResponse(
        roundaboutThirdExitRightResponse(),
      );

      final roundabout = planner.instructions(route).first.instruction;

      expect(roundabout.text, '3rd exit, right');
      expect(roundabout.direction, ManeuverDirection.right);
      expect(roundabout.exitNumber, 3);
      expect(roundabout.roadLabel, 'Redcliffe Way · A4');
    },
  );

  test('a split gyratory ring collapses into a single roundabout', () async {
    final route = await routeFromOsrmResponse(gyratoryResponse());

    final steps = planner.instructions(route);

    expect(route.maneuvers, hasLength(5));
    expect(steps.map((step) => step.instruction.text), [
      '2nd exit, straight on',
      'Arrive at the destination',
    ]);
    expect(steps.first.instruction.stepCount, 3);
    expect(steps.first.instruction.roadLabel, 'West Street');
  });

  test('adjacent urban roundabouts each keep one instruction', () async {
    final route = await routeFromOsrmResponse(multiRoundaboutUrbanResponse());

    final steps = planner.instructions(route);

    expect(steps.map((step) => step.instruction.text), [
      '3rd exit, right',
      '2nd exit, left',
      '4th exit, left',
      'Turn right',
      'Arrive at the destination',
    ]);
    expect(steps.map((step) => step.instruction.isRoundabout), [
      true,
      true,
      true,
      false,
      false,
    ]);
    // Distances increase along the route so the list reads in riding order.
    final distances = steps
        .map((step) => step.distanceFromStartMeters)
        .toList(growable: false);
    expect(distances, orderedEquals(<double>[...distances]..sort()));
  });

  test('no fixture route announces one roundabout twice', () async {
    final responses = [
      ukRoundaboutStraightOnResponse(),
      roundaboutThirdExitRightResponse(),
      gyratoryResponse(),
      multiRoundaboutUrbanResponse(),
    ];

    for (final response in responses) {
      final route = await routeFromOsrmResponse(response);
      final steps = planner.instructions(route);
      expect(
        steps.every((step) => step.instruction.isGuidance),
        isTrue,
        reason: 'route bookkeeping steps must not be announced',
      );
      // Leaving a ring is never an instruction of its own.
      expect(
        steps.map((step) => step.maneuver.type),
        everyElement(isNot(anyOf('exit roundabout', 'exit rotary'))),
      );
      for (var index = 1; index < steps.length; index += 1) {
        final previous = steps[index - 1];
        final current = steps[index];
        if (!previous.instruction.isRoundabout ||
            !current.instruction.isRoundabout) {
          continue;
        }
        // Two roundabout instructions are only allowed where they are far
        // enough apart to be different junctions.
        expect(
          current.distanceFromStartMeters - previous.distanceFromStartMeters,
          greaterThan(60),
          reason:
              'two instructions for one junction: '
              '"${previous.instruction.text}" then "${current.instruction.text}"',
        );
      }
    }
  });

  test('live guidance announces the collapsed roundabout once', () async {
    final route = await routeFromOsrmResponse(ukRoundaboutStraightOnResponse());

    final approaching = planner.plan(
      route: route,
      position: route.paths.first.points.first,
      progressMeters: 0,
    );

    expect(approaching?.instruction.text, '2nd exit, straight on');
    expect(approaching?.maneuver.type, 'roundabout');
    // The exit step must not resurface as the closely following manoeuvre.
    expect(approaching?.followingInstruction?.text, isNot(contains('exit')));
  });

  test('a roundabout without engine bearings claims no direction', () {
    final route = ImportedRoute(
      id: 'legacy',
      name: 'Legacy roundabout',
      importedAt: DateTime.utc(2026, 7, 25),
      sourceFileName: 'legacy.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.47, longitude: -2.59),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        // A route persisted before bearings were stored. The entry modifier
        // describes joining the ring, so it must not be read as the exit.
        RouteManeuver(
          position: GeoPoint(latitude: 51.46, longitude: -2.59),
          type: 'roundabout',
          modifier: 'slight left',
          exitNumber: 2,
          drivingSide: 'left',
        ),
      ],
    );

    final instruction = planner.instructions(route).single.instruction;

    expect(instruction.text, 'Take the 2nd exit');
    expect(instruction.standaloneText, 'Roundabout, take the 2nd exit');
    expect(instruction.direction, ManeuverDirection.unstated);
    expect(instruction.text, isNot(contains('left')));
  });

  test('a roundabout names itself only where no symbol is shown', () {
    ManeuverInstruction roundabout({int? exitNumber, bool bearings = true}) =>
        collapseManeuvers([
          RouteManeuver(
            position: const GeoPoint(latitude: 51.46, longitude: -2.59),
            type: 'roundabout',
            modifier: 'slight left',
            drivingSide: 'left',
            exitNumber: exitNumber,
            bearingBeforeDegrees: bearings ? 0 : null,
            bearingAfterDegrees: bearings ? 290 : null,
          ),
          RouteManeuver(
            position: const GeoPoint(latitude: 51.4602, longitude: -2.59),
            type: 'exit roundabout',
            modifier: 'slight left',
            bearingBeforeDegrees: bearings ? 200 : null,
            bearingAfterDegrees: bearings ? 90 : null,
          ),
        ]).single;

    // Beside the drawn ring the wording states the exit and the direction only.
    // A rider who cannot see the ring is told which junction it is.
    final counted = roundabout(exitNumber: 3);
    expect(counted.text, '3rd exit, right');
    expect(counted.standaloneText, 'Roundabout, 3rd exit, right');

    final uncounted = roundabout();
    expect(uncounted.text, 'Take the exit right');
    expect(uncounted.standaloneText, 'Roundabout, take the exit right');

    // Neither an exit number nor a direction: nothing is invented, and the
    // wording still reads as an instruction rather than as nothing at all.
    final bare = roundabout(bearings: false);
    expect(bare.direction, ManeuverDirection.unstated);
    expect(bare.exitNumber, isNull);
    expect(bare.text, 'Follow the route');
    expect(bare.standaloneText, 'Roundabout ahead, follow the route');

    // Every other manoeuvre reads the same either way: only a roundabout has a
    // drawn symbol standing in for a word.
    final turn = collapseManeuvers(const [
      RouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.59),
        type: 'turn',
        modifier: 'right',
      ),
    ]).single;
    expect(turn.text, 'Turn right');
    expect(turn.standaloneText, turn.text);
  });

  test('a roundabout with no exit count still states the direction', () {
    final instruction = collapseManeuvers(const [
      RouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.59),
        type: 'roundabout',
        modifier: 'slight left',
        drivingSide: 'left',
        bearingBeforeDegrees: 10,
        bearingAfterDegrees: 300,
      ),
      RouteManeuver(
        position: GeoPoint(latitude: 51.4602, longitude: -2.59),
        type: 'exit roundabout',
        modifier: 'slight left',
        bearingBeforeDegrees: 40,
        bearingAfterDegrees: 12,
      ),
    ]).single;

    expect(instruction.text, 'Take the exit straight on');
    expect(instruction.exitNumber, isNull);
  });

  test('merged gyratory rings do not invent a combined exit count', () {
    final instruction = collapseManeuvers(const [
      RouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.59),
        type: 'roundabout',
        exitNumber: 2,
        bearingBeforeDegrees: 270,
        bearingAfterDegrees: 200,
      ),
      RouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.5899),
        type: 'roundabout',
        exitNumber: 1,
        bearingBeforeDegrees: 210,
        bearingAfterDegrees: 190,
      ),
      RouteManeuver(
        position: GeoPoint(latitude: 51.4601, longitude: -2.5899),
        type: 'exit roundabout',
        bearingBeforeDegrees: 190,
        bearingAfterDegrees: 268,
      ),
    ]).single;

    expect(instruction.exitNumber, isNull);
    expect(instruction.text, 'Take the exit straight on');
  });

  test('a small roundabout reported as a turn keeps its own modifier', () {
    final instruction = collapseManeuvers(const [
      RouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.59),
        type: 'roundabout turn',
        modifier: 'left',
        drivingSide: 'left',
      ),
    ]).single;

    expect(instruction.kind, ManeuverKind.roundabout);
    expect(instruction.direction, ManeuverDirection.left);
    expect(instruction.text, 'Take the exit left');
  });

  test('progress along a route can be measured for review surfaces', () async {
    final route = await routeFromOsrmResponse(multiRoundaboutUrbanResponse());

    final progress = planner.progressMetersAt(
      route,
      route.paths.first.points[1],
    );
    final away = planner.progressMetersAt(
      route,
      const GeoPoint(latitude: 52.5, longitude: -2.55),
    );

    expect(progress, closeTo(333, 30));
    expect(away, isNull);
  });

  // #163: "The double roundabout on New Cheltenham Road in Kingswood didn't show
  // up on the navigation directions."
  //
  // Ground truth from OpenStreetMap: the pair is two mini-roundabouts, mapped as
  // `highway=mini_roundabout` nodes at 51.46705,-2.50050 and 51.46721,-2.50106 -
  // **42 m apart**. That is outside the 25 m gyratory threshold as ring centres,
  // and easily inside it measured from the first ring's exit to the second's
  // entry, which is what the collapse used to compare.
  group('the New Cheltenham Road double roundabout', () {
    const firstRing = GeoPoint(latitude: 51.46721, longitude: -2.50106);
    const secondRing = GeoPoint(latitude: 51.46705, longitude: -2.50050);
    // Leaving the first ring puts the rider most of the way to the second, which
    // is exactly why an exit-to-entry measurement reads as one junction.
    const firstExit = GeoPoint(latitude: 51.46712, longitude: -2.50075);
    const secondExit = GeoPoint(latitude: 51.46695, longitude: -2.50020);

    test(
      'a captured route restores both junctions and advances between them',
      () async {
        // #163's defect: two mapped mini-roundabouts 42 m apart, omitted by the
        // engine, announced as one junction. What restores them is now the
        // general OpenStreetMap layer rather than a catalogue naming these two.
        final catalogue = await MappedMiniRoundaboutCatalogue.load();
        final route = await routeFromOsrmResponse(
          newCheltenhamRoadOmittedRoundaboutsResponse(),
          id: 'issue-163-live-route',
          readMiniRoundabouts: () async => catalogue,
        );
        final restored = planner
            .instructions(route)
            .where(
              (step) =>
                  step.instruction.isRoundabout &&
                  (step.instruction.maneuver.position.longitude - -2.5008)
                          .abs() <
                      0.0006,
            )
            .toList(growable: false);

        expect(
          restored,
          hasLength(2),
          reason: 'a rider meets two junctions and needs telling about both',
        );
        expect(
          restored.last.distanceFromStartMeters -
              restored.first.distanceFromStartMeters,
          closeTo(42, 5),
          reason: 'they must not be merged into one instruction',
        );
        // No exit number is claimed from a layer that carries no arm bearings.
        expect(
          restored.map((step) => step.instruction.exitNumber),
          everyElement(isNull),
        );

        final approaching = planner.plan(
          route: route,
          position: route.paths.first.points.first,
          progressMeters: 0,
        );
        expect(
          approaching?.maneuver.position.longitude,
          closeTo(-2.5010632, 1e-7),
        );
        expect(
          approaching?.followingManeuver?.position.longitude,
          closeTo(-2.5005026, 1e-7),
        );

        // At the second ring, which must by then be the current instruction.
        const secondPosition = secondRing;
        final afterFirst = planner.plan(
          route: route,
          position: secondPosition,
          progressMeters: planner.progressMetersAt(route, secondPosition)!,
        );
        expect(
          afterFirst?.maneuver.position.longitude,
          closeTo(-2.5005026, 1e-7),
          reason: 'the second junction must become current after the first',
        );
      },
    );

    test('both roundabouts survive as separate instructions', () {
      final instructions = collapseManeuvers(const [
        RouteManeuver(
          position: firstRing,
          type: 'roundabout',
          modifier: 'right',
          exitNumber: 2,
        ),
        RouteManeuver(position: firstExit, type: 'exit roundabout'),
        RouteManeuver(
          position: secondRing,
          type: 'roundabout',
          modifier: 'straight',
          exitNumber: 2,
        ),
        RouteManeuver(position: secondExit, type: 'exit roundabout'),
      ]);

      expect(
        instructions.where((item) => item.kind == ManeuverKind.roundabout),
        hasLength(2),
        reason: 'a rider meets two junctions and needs telling about both',
      );
      expect(instructions.first.exitNumber, 2);
      expect(instructions.last.exitNumber, 2);
    });

    test('a genuine gyratory inside 25 m is still one instruction', () {
      // The behaviour the threshold exists for, kept: adjacent rings of one
      // gyratory, 15 m apart.
      final instructions = collapseManeuvers(const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.46705, longitude: -2.50050),
          type: 'roundabout',
          modifier: 'right',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.467063, longitude: -2.500285),
          type: 'roundabout',
          modifier: 'straight',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.46707, longitude: -2.50020),
          type: 'exit roundabout',
        ),
      ]);

      expect(
        instructions.where((item) => item.kind == ManeuverKind.roundabout),
        hasLength(1),
      );
    });

    test('an exit from a distant later ring is not absorbed', () {
      // The unconditional absorption this replaced: any exit joined the current
      // group however far away it was.
      final instructions = collapseManeuvers(const [
        RouteManeuver(
          position: firstRing,
          type: 'roundabout',
          modifier: 'right',
        ),
        RouteManeuver(
          // ~2 km along the road.
          position: GeoPoint(latitude: 51.48500, longitude: -2.50050),
          type: 'exit roundabout',
        ),
      ]);

      expect(instructions, hasLength(2));
      expect(instructions.first.kind, ManeuverKind.roundabout);
    });
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 7, 22),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.01),
        GeoPoint(latitude: 0, longitude: 0.02),
        GeoPoint(latitude: 0, longitude: 0.03),
      ],
    ),
  ],
  waypoints: const [],
  maneuvers: const [
    RouteManeuver(
      position: GeoPoint(latitude: 0, longitude: 0.01),
      type: 'turn',
      modifier: 'left',
      name: 'First Road',
    ),
    RouteManeuver(
      position: GeoPoint(latitude: 0, longitude: 0.02),
      type: 'turn',
      modifier: 'right',
      name: 'Second Road',
    ),
  ],
);

/// One ordinary turn, described both ways: what the engine called it, and the
/// bearings the same step carried.
ManeuverDirection _directionFor({
  required String? modifier,
  double? bearingBefore,
  double? bearingAfter,
}) {
  final route = ImportedRoute(
    id: 'turn',
    name: 'Turn',
    importedAt: DateTime.utc(2026, 8, 8),
    sourceFileName: 'turn.gpx',
    waypoints: const [],
    paths: const [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 51.45, longitude: -2.60),
          GeoPoint(latitude: 51.45, longitude: -2.58),
          GeoPoint(latitude: 51.46, longitude: -2.57),
        ],
      ),
    ],
    maneuvers: [
      RouteManeuver(
        position: const GeoPoint(latitude: 51.45, longitude: -2.58),
        type: 'turn',
        modifier: modifier,
        name: 'Woodhouse Lane',
        drivingSide: 'left',
        bearingBeforeDegrees: bearingBefore,
        bearingAfterDegrees: bearingAfter,
      ),
    ],
  );
  return const NavigationGuidancePlanner()
      .instructions(route)
      .first
      .instruction
      .direction;
}

void _turnDirectionTests() {
  group('when the engine contradicts its own bearings', () {
    // Every case here is a real step from a sweep of 359 OSRM steps across
    // twelve UK areas, not an invented one.

    test('an ordinary turn is not announced as a sharp one (#302)', () {
      // Woodhouse Lane, Leeds: the engine called a 21 degree deviation a sharp
      // right. A rider braking for a sharp right that is barely a deviation
      // stops trusting the guidance, which is what was reported.
      expect(
        _directionFor(
          modifier: 'sharp right',
          bearingBefore: 100,
          bearingAfter: 121,
        ),
        ManeuverDirection.slightRight,
      );
    });

    test('a 90 degree turn is not announced as a U-turn', () {
      expect(
        _directionFor(modifier: 'uturn', bearingBefore: 10, bearingAfter: 103),
        ManeuverDirection.right,
      );
    });

    test('a real turn is not announced as straight on', () {
      // The dangerous direction of the same fault: a rider told to carry on
      // through an 82 degree left rides past the turn.
      expect(
        _directionFor(modifier: 'straight', bearingBefore: 90, bearingAfter: 8),
        ManeuverDirection.left,
      );
    });

    test('one bucket apart is a judgement call the engine keeps', () {
      // 45 degrees sits inside this code's slight band and outside the
      // engine's. Neither reading misleads a rider, so the engine's stands and
      // the app does not churn its wording against the router's.
      expect(
        _directionFor(modifier: 'left', bearingBefore: 90, bearingAfter: 45),
        ManeuverDirection.left,
      );
    });

    test('a U-turn is judged by how hard over it is, not by which way', () {
      // Mirrored geometry has to be treated the same. A sharp turn and a
      // U-turn are neighbours on either side.
      expect(
        _directionFor(modifier: 'uturn', bearingBefore: 0, bearingAfter: 210),
        ManeuverDirection.uTurn,
      );
      expect(
        _directionFor(modifier: 'uturn', bearingBefore: 0, bearingAfter: 150),
        ManeuverDirection.uTurn,
      );
    });

    test('the engine is still trusted when it is all there is', () {
      expect(
        _directionFor(modifier: 'sharp right'),
        ManeuverDirection.sharpRight,
      );
    });

    test('the bearings are still used when there is no modifier', () {
      expect(
        _directionFor(modifier: null, bearingBefore: 100, bearingAfter: 190),
        ManeuverDirection.right,
      );
    });
  });
}

ImportedRoute _routeWith({
  required List<RoutePath> paths,
  List<RouteManeuver> maneuvers = const [],
}) => ImportedRoute(
  id: 'state',
  name: 'State route',
  importedAt: DateTime.utc(2026, 8, 9),
  sourceFileName: 'state.gpx',
  paths: paths,
  waypoints: const [],
  maneuvers: maneuvers,
);

const _line = [
  GeoPoint(latitude: 51.45, longitude: -2.60),
  GeoPoint(latitude: 51.45, longitude: -2.58),
];

void _guidanceStateTests() {
  group('why a route has no turn prompts', () {
    // #303: "Turn guidance is unavailable for this route" persisted through an
    // active ride with a good line drawn on the map. One message covered three
    // different situations, so a rider could not tell a route working as
    // intended from one that had lost its directions.
    const planner = NavigationGuidancePlanner();
    const onRoute = GeoPoint(latitude: 51.45, longitude: -2.59);

    NavigationGuidanceAssessment assess(ImportedRoute route) =>
        planner.assess(route: route, position: onRoute, progressMeters: 0);

    test('a routed route is navigated', () {
      final assessment = assess(
        _routeWith(
          paths: const [RoutePath(kind: RoutePathKind.track, points: _line)],
          maneuvers: const [
            RouteManeuver(
              position: GeoPoint(latitude: 51.45, longitude: -2.59),
              type: 'turn',
              modifier: 'left',
              name: 'Side Road',
              bearingBeforeDegrees: 90,
              bearingAfterDegrees: 0,
            ),
          ],
        ),
      );

      expect(assessment.state, NavigationGuidanceState.active);
    });

    test('an imported track says the line is followable', () {
      // A GPX track is a line without instructions. Nothing failed, and the
      // rider can ride it.
      final assessment = assess(
        _routeWith(
          paths: const [RoutePath(kind: RoutePathKind.track, points: _line)],
        ),
      );

      expect(assessment.state, NavigationGuidanceState.noManeuvers);
      expect(assessment.message, contains('follow the line'));
    });

    test('a route whose routing failed says so instead', () {
      // `RouteGeometryEnricher` turns a `route` path into a `track` when the
      // engine answers and leaves it a `route` when the request fails. The
      // warning it returns is gone by riding time; this is what survives.
      final assessment = assess(
        _routeWith(
          paths: const [RoutePath(kind: RoutePathKind.route, points: _line)],
        ),
      );

      expect(assessment.state, NavigationGuidanceState.routingUnfinished);
      expect(assessment.message, contains('could not be built'));
      // Never the imported-track wording, which would tell a rider nothing is
      // wrong when something is.
      expect(assessment.message, isNot(contains('follow the line')));
    });

    test('the three states never share a message', () {
      final messages = {
        NavigationGuidancePlanner.noTurnInstructionsMessage,
        NavigationGuidancePlanner.noRouteLineMessage,
        NavigationGuidancePlanner.routingUnfinishedMessage,
      };

      expect(messages, hasLength(3));
    });

    test('a route with no line at all is a third thing again', () {
      final assessment = assess(_routeWith(paths: const []));

      expect(assessment.state, NavigationGuidanceState.noManeuvers);
      expect(assessment.message, contains('no path to follow'));
    });
  });
}
