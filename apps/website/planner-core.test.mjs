import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  buildGpx,
  buildRouteMarkerPlan,
  chooseRoadRoute,
  biasCircularRideCoordinates,
  circularHeatmapBiasAvailable,
  circularRideDistanceWithinTolerance,
  circularRideItinerary,
  circularRideShapingCoordinates,
  circularRouteHasUTurn,
  decodePolyline,
  dayRideDistanceMetres,
  escapeXml,
  formatDistance,
  formatDuration,
  formatRouteBendScore,
  gpxFileName,
  motorcycleCostingOptions,
  requiresMotorcycleCosting,
  routeBendScore,
  routePreferencesGpxExtension,
  routeDetourLimit,
  routeSelfCrossingArrows,
  StateHistory,
} from "./planner-core.mjs";

test("circular ride controls honour direction and alternatives", () => {
  const start = [-2.51, 51.46];
  const north = circularRideShapingCoordinates({
    start,
    distanceMetres: 100000,
    direction: "N",
  });
  const southWest = circularRideShapingCoordinates({
    start,
    distanceMetres: 100000,
    direction: "SW",
  });
  const alternative = circularRideShapingCoordinates({
    start,
    distanceMetres: 100000,
    direction: "N",
    variant: 1,
  });

  assert.ok(north[1][1] > start[1]);
  assert.ok(southWest[1][0] < start[0]);
  assert.ok(southWest[1][1] < start[1]);
  assert.notDeepEqual(alternative, north);
  assert.equal(dayRideDistanceMetres("half-day"), 220000);
  assert.equal(dayRideDistanceMetres("day"), 440000);
  assert.equal(circularRideDistanceWithinTolerance(100000, 130000), true);
  assert.equal(circularRideDistanceWithinTolerance(100000, 130001), false);
  assert.equal(circularRideDistanceWithinTolerance(100000, 0), false);
  assert.equal(circularRouteHasUTurn([{ modifier: "u-turn" }]), true);
  assert.equal(circularRouteHasUTurn([{ modifier: "left" }]), false);
});

test("web itinerary matches the shared mobile fixture", async () => {
  const fixture = JSON.parse(
    await readFile(new URL("../../fixtures/circular-itinerary.json", import.meta.url)),
  );
  for (const item of fixture.cases) {
    assert.deepEqual(
      circularRideItinerary({
        dayLength: item.dayLength,
        fuelMinutes: fixture.fuelMinutes,
        comfortMinutes: fixture.comfortMinutes,
        mealMinutes: fixture.mealMinutes,
      }),
      item.stops,
    );
  }
});

test("heatmap bias is unavailable when sparse and remains a soft nudge", () => {
  const start = [-2.51, 51.46];
  const controls = circularRideShapingCoordinates({
    start,
    distanceMetres: 80000,
    direction: "N",
  });
  const cells = Array.from({ length: 20 }, (_value, index) => ({
    coordinate: [controls[0][0] + 0.01, controls[0][1] + index * 0.00001],
    weight: 1,
  }));
  assert.equal(circularHeatmapBiasAvailable(cells.slice(0, 19)), false);
  const nearStart = Array.from({ length: 20 }, (_value, index) => ({
    coordinate: [start[0], start[1] + index * 0.00001],
    weight: 1,
  }));
  assert.equal(circularHeatmapBiasAvailable(nearStart, start), false);
  const biased = biasCircularRideCoordinates({
    controls,
    start,
    cells,
    enabled: true,
    searchRadiusMetres: 20000,
  });
  assert.notDeepEqual(biased[0], controls[0]);
  assert.notDeepEqual(biased[0], cells[0].coordinate);
});

/// A deterministic sinusoidal lane. Byte-for-byte the coordinates the mobile
/// twistiness test uses, so both implementations of the score are pinned to one
/// number.
const SINUSOIDAL_LANE = Object.freeze(
  Array.from({ length: 40 }, (_unused, index) => [
    Number((-2.5 + index * 0.004).toFixed(6)),
    Number((51.4 + Math.sin(index / 2.5) * 0.006).toFixed(6)),
  ]),
);
const SINUSOIDAL_LANE_METRES = 12963.68838;

function geometryDistance(coordinates) {
  return coordinates
    .slice(1)
    .reduce(
      (total, coordinate, index) =>
        total + coordinateDistance(coordinates[index], coordinate),
      0,
    );
}

function coordinateDistance(first, second) {
  const radians = (value) => (value * Math.PI) / 180;
  const latitudeDelta = radians(second[1] - first[1]);
  const longitudeDelta = radians(second[0] - first[0]);
  const firstLatitude = radians(first[1]);
  const secondLatitude = radians(second[1]);
  const haversine =
    Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(firstLatitude) *
      Math.cos(secondLatitude) *
      Math.sin(longitudeDelta / 2) ** 2;
  return (
    6371000 *
    2 *
    Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine))
  );
}

test("buildGpx marks its calculated track as a road route", () => {
  const gpx = buildGpx({
    rideName: "Peaks & Dales",
    stops: [
      { name: "Start <cafe>", longitude: -2.12345678, latitude: 53.12345678 },
      { name: "Finish", longitude: -1.98765432, latitude: 53.23456789 },
    ],
    routeCoordinates: [
      [-2.12345678, 53.12345678],
      [-1.98765432, 53.23456789],
    ],
    createdAt: new Date("2026-07-22T10:30:00.000Z"),
  });

  assert.match(gpx, /version="1\.1" creator="Tail End Charlie"/);
  assert.match(gpx, /<name>Peaks &amp; Dales<\/name>/);
  assert.match(gpx, /<name>Start &lt;cafe&gt;<\/name>/);
  assert.match(gpx, /<wpt lat="53\.1234568" lon="-2\.1234568">/);
  assert.match(gpx, /<tec:road-route>true<\/tec:road-route>/);
  assert.match(gpx, /<trkpt lat="53\.2345679" lon="-1\.9876543" \/>/);
  assert.match(gpx, /<time>2026-07-22T10:30:00\.000Z<\/time>/);
});

test("marker review uses app categories and survives a GPX handoff", () => {
  const routeCoordinates = [
    [-2.0, 51.0],
    [-2.0, 51.001],
    [-1.999, 51.001],
    [-1.998, 51.001],
  ];
  const maneuvers = [
    {
      position: [-2.0, 51.001],
      type: "turn",
      modifier: "right",
      bearingBefore: 0,
      bearingAfter: 90,
      lanes: [],
    },
    {
      position: [-1.999, 51.001],
      type: "off ramp",
      modifier: "slight right",
      bearingBefore: 90,
      bearingAfter: 100,
      lanes: [],
    },
  ];
  const detected = buildRouteMarkerPlan({ routeCoordinates, maneuvers });

  assert.deepEqual(
    detected.points.map(({ id, kind, label }) => ({ id, kind, label })),
    [
      {
        id: "maneuver-0",
        kind: "likely-marker",
        label: "Turn right marker",
      },
      {
        id: "maneuver-1",
        kind: "safety-review",
        label: "Motorway or dual-carriageway exit review",
      },
    ],
  );

  const markerReview = {
    rejected: [
      {
        id: "old-router-id",
        longitude: -2.0,
        latitude: 51.001,
        label: "Turn right marker",
      },
    ],
    added: [
      {
        id: "geometry-2",
        longitude: -1.999,
        latitude: 51.001,
        label: "Added marker",
      },
    ],
  };
  const reviewed = buildRouteMarkerPlan({
    routeCoordinates,
    maneuvers,
    review: markerReview,
  });
  assert.equal(reviewed.rejectedPoints[0].id, "maneuver-0");
  assert.equal(
    reviewed.points.find((point) => point.source === "manual").label,
    "Added marker",
  );

  const gpx = buildGpx({
    rideName: "Reviewed ride",
    stops: [
      { name: "Start", longitude: -2, latitude: 51 },
      { name: "Finish", longitude: -1.998, latitude: 51.001 },
    ],
    routeCoordinates,
    markerReview,
    createdAt: new Date("2026-07-29T10:00:00Z"),
  });
  assert.match(gpx, /<tec:marker-review>/);
  assert.match(
    gpx,
    /<tec:rejected id="old-router-id" lat="51\.0010000" lon="-2\.0000000"/,
  );
  assert.match(gpx, /<tec:added id="geometry-2"/);
});

test("marker review rejects a cul-de-sac double-back", () => {
  const plan = buildRouteMarkerPlan({
    routeCoordinates: [
      [-2, 51],
      [-2, 51.001],
      [-2, 51],
    ],
    maneuvers: [
      {
        position: [-2, 51.001],
        type: "turn",
        modifier: "uturn",
        bearingBefore: 0,
        bearingAfter: 180,
        lanes: [],
      },
    ],
  });

  assert.deepEqual(plan.points, []);
});

test("twisty routing chooses a bendier reasonable alternative", () => {
  const quickest = {
    duration: 600,
    distance: 10000,
    geometry: { coordinates: [[-2, 51], [-1.95, 51], [-1.9, 51]] },
  };
  const twisty = {
    duration: 750,
    distance: 11000,
    geometry: {
      coordinates: [
        [-2, 51],
        [-1.98, 51.005],
        [-1.96, 51],
        [-1.94, 51.005],
        [-1.9, 51],
      ],
    },
  };
  const excessiveDetour = {
    duration: 1000,
    distance: 12000,
    geometry: twisty.geometry,
  };

  assert.ok(routeBendScore(twisty) > routeBendScore(quickest));
  assert.equal(chooseRoadRoute([quickest, twisty], "quickest"), quickest);
  assert.equal(chooseRoadRoute([quickest, twisty], "balanced"), twisty);
  assert.equal(chooseRoadRoute([quickest, twisty], "twisty"), twisty);
  assert.equal(chooseRoadRoute([quickest, excessiveDetour], "twisty"), quickest);
  assert.equal(
    chooseRoadRoute([quickest, excessiveDetour], "very-twisty"),
    excessiveDetour,
  );
  assert.equal(routeDetourLimit("balanced"), 1.25);
  assert.equal(routeDetourLimit("very-twisty"), 1.75);
});

test("bend score is calibrated on reviewed UK routes and rejects manoeuvres", () => {
  // The fixture is a self-contained sinusoidal lane rather than a catalogue
  // feature: the catalogue is regenerated (#161, #158) and its ids move, and the
  // point of this test is that the score is reproducible. The identical
  // coordinates and expected value are pinned in the mobile suite
  // (apps/mobile/test/services/route_twistiness_test.dart), which is what stops
  // the two implementations of the score drifting apart (#182).
  const sinusoidalLane = { distance: SINUSOIDAL_LANE_METRES, geometry: { coordinates: SINUSOIDAL_LANE } };
  const score = routeBendScore(sinusoidalLane);

  assert.equal(routeBendScore(sinusoidalLane), score, "the score is deterministic");
  assert.ok(Math.abs(score - 29.115031244781) < 1e-9, `score was ${score}`);
  assert.equal(formatRouteBendScore(score), "29°/km · Twisty");
  // Geometry length alone reproduces the same score, which is the case a stored
  // route without a provider summary has.
  assert.ok(
    Math.abs(geometryDistance(SINUSOIDAL_LANE) - SINUSOIDAL_LANE_METRES) < 1e-6,
  );

  const uTurn = [
    [-3.2, 51.48],
    [-3.19, 51.48],
    [-3.2, 51.48],
  ];
  const rightAngleGrid = [
    [-3.2, 51.48],
    [-3.19, 51.48],
    [-3.19, 51.49],
    [-3.18, 51.49],
    [-3.18, 51.5],
  ];
  expectManoeuvreScoreToBeZero(uTurn);
  expectManoeuvreScoreToBeZero(rightAngleGrid);
});

function expectManoeuvreScoreToBeZero(coordinates) {
  assert.equal(
    routeBendScore({
      distance: geometryDistance(coordinates),
      geometry: { coordinates },
    }),
    0,
  );
}

test("self-crossing routes get directional arrows for both traversals", () => {
  const arrows = routeSelfCrossingArrows([
    [-2.01, 51.49],
    [-1.99, 51.51],
    [-2.01, 51.51],
    [-1.99, 51.49],
  ]);

  assert.equal(arrows.length, 2);
  assert.ok(arrows.every((arrow) => arrow.coordinate.length === 2));
  assert.ok(arrows.every((arrow) => Number.isFinite(arrow.bearing)));
  assert.ok(Math.abs(arrows[0].bearing - arrows[1].bearing) > 20);
  assert.deepEqual(
    routeSelfCrossingArrows([
      [-2.01, 51.49],
      [-2, 51.5],
      [-1.99, 51.51],
    ]),
    [],
  );
});

test("Valhalla polyline6 route shapes decode to longitude and latitude", () => {
  const encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";
  assert.deepEqual(decodePolyline(encoded, 5), [
    [-120.2, 38.5],
    [-120.95, 40.7],
    [-126.453, 43.252],
  ]);
});

test("motorcycle routing keeps motorway and major-road preferences separate", () => {
  assert.deepEqual(
    motorcycleCostingOptions({ avoidMotorways: true }),
    {
      use_highways: 1,
      use_tolls: 0.5,
      use_ferry: 0.5,
      use_trails: 0,
      exclude_highways: true,
      exclude_tolls: false,
      exclude_ferries: false,
      exclude_unpaved: true,
    },
  );
  assert.deepEqual(
    motorcycleCostingOptions({
      routeStyle: "twisty",
      avoidMajorRoads: true,
      avoidTolls: true,
      avoidFerries: true,
    }),
    {
      use_highways: 0.08,
      use_tolls: 0,
      use_ferry: 0,
      use_trails: 0,
      exclude_highways: false,
      exclude_tolls: true,
      exclude_ferries: true,
      exclude_unpaved: true,
    },
  );
  assert.equal(
    motorcycleCostingOptions({ routeStyle: "very-twisty" }).use_highways,
    0.15,
  );
});

test("unsurfaced byways are avoided by default and by surface tagging", () => {
  // The default. Documented in docs/route-twistiness.md and matched by
  // RoutePreferences.defaults in the mobile app.
  const defaults = motorcycleCostingOptions();
  assert.equal(defaults.exclude_unpaved, true);
  assert.equal(defaults.use_trails, 0);

  // A trail rider who asks for them gets both surface levers relaxed together.
  const seeking = motorcycleCostingOptions({ avoidUnsurfacedByways: false });
  assert.equal(seeking.exclude_unpaved, false);
  assert.equal(seeking.use_trails, 0.5);

  // The preference is independent of every other one.
  assert.equal(
    motorcycleCostingOptions({ avoidMotorways: true }).exclude_unpaved,
    true,
  );
  assert.equal(
    motorcycleCostingOptions({
      routeStyle: "very-twisty",
      avoidUnsurfacedByways: false,
    }).use_highways,
    0.15,
  );
});

test("the engine choice matches the mobile app's dispatch rule", () => {
  assert.equal(requiresMotorcycleCosting(), false, "defaults stay on OSRM");
  assert.equal(
    requiresMotorcycleCosting({ routeStyle: "very-twisty" }),
    false,
    "a bendier style needs only OSRM alternatives",
  );
  for (const preference of [
    "avoidMotorways",
    "avoidMajorRoads",
    "avoidTolls",
    "avoidFerries",
  ]) {
    assert.equal(
      requiresMotorcycleCosting({ [preference]: true }),
      true,
      `${preference} is a hard exclusion OSRM cannot express`,
    );
  }
  // OSRM's car profile does not route highway=track at all, so seeking byways
  // is the byway case it cannot serve.
  assert.equal(
    requiresMotorcycleCosting({ avoidUnsurfacedByways: false }),
    true,
  );
});

test("shared GPX states the preferences the route was planned with", () => {
  const stops = [
    { name: "Start", longitude: -2.5, latitude: 51.4 },
    { name: "Finish", longitude: -2.4, latitude: 51.45 },
  ];
  const routeCoordinates = [
    [-2.5, 51.4],
    [-2.45, 51.42],
    [-2.4, 51.45],
  ];
  const gpx = buildGpx({
    rideName: "Sunday ride",
    stops,
    routeCoordinates,
    createdAt: new Date("2026-07-27T09:00:00Z"),
    preferences: {
      routeStyle: "twisty",
      avoidMotorways: true,
      avoidUnsurfacedByways: true,
    },
  });

  assert.match(gpx, /<tec:route-preferences /);
  assert.match(gpx, /style="twisty"/);
  assert.match(gpx, /avoid-motorways="true"/);
  assert.match(gpx, /byway-surface="avoid-unsurfaced"/);
  assert.match(gpx, /avoid-ferries="false"/);
  // A route with nothing recorded stays silent rather than claiming a default.
  assert.doesNotMatch(
    buildGpx({
      rideName: "Sunday ride",
      stops,
      routeCoordinates,
      createdAt: new Date("2026-07-27T09:00:00Z"),
    }),
    /tec:route-preferences/,
  );
  assert.equal(
    routePreferencesGpxExtension({ avoidUnsurfacedByways: false }).includes(
      'byway-surface="allow-unsurfaced"',
    ),
    true,
  );
});

test("route history supports bounded undo and redo without sharing state", () => {
  const history = new StateHistory(2);
  history.push({ stops: ["A"] });
  history.push({ stops: ["A", "B"] });
  history.push({ stops: ["A", "B", "C"] });

  const firstUndo = history.undo({ stops: ["current"] });
  assert.deepEqual(firstUndo, { stops: ["A", "B", "C"] });
  firstUndo.stops.push("changed");
  assert.deepEqual(history.undo({ stops: ["A", "B", "C"] }), {
    stops: ["A", "B"],
  });
  assert.equal(history.canUndo, false);
  assert.deepEqual(history.redo({ stops: ["A", "B"] }), {
    stops: ["A", "B", "C"],
  });
  assert.equal(history.canRedo, true);
});

test("buildGpx requires a named, routed ride", () => {
  assert.throws(
    () =>
      buildGpx({
        rideName: " ",
        stops: [{}, {}],
        routeCoordinates: [[0, 0], [1, 1]],
        createdAt: new Date(),
      }),
    /Name the ride/,
  );
  assert.throws(
    () =>
      buildGpx({
        rideName: "Ride",
        stops: [{ name: "A", longitude: 0, latitude: 0 }],
        routeCoordinates: [[0, 0], [1, 1]],
        createdAt: new Date(),
      }),
    /at least two stops/,
  );
});

test("helpers produce safe names and concise route summaries", () => {
  assert.equal(escapeXml(`A & B's <ride>`), "A &amp; B&apos;s &lt;ride&gt;");
  assert.equal(gpxFileName("  Côte & Coast  "), "cote-coast.gpx");
  assert.equal(gpxFileName("!!!"), "tail-end-charlie-route.gpx");
  assert.equal(formatDistance(16093.44), "10 mi");
  assert.equal(formatDistance(8046.72), "5.0 mi");
  assert.equal(formatDuration(5400), "1 hr 30 min");
  assert.equal(formatDuration(1200), "20 min");
  assert.equal(formatRouteBendScore(28.4), "28°/km · Twisty");
  assert.equal(formatRouteBendScore(undefined), "—");
});
