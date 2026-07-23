import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  buildGpx,
  chooseRoadRoute,
  decodePolyline,
  escapeXml,
  formatDistance,
  formatDuration,
  formatRouteBendScore,
  gpxFileName,
  motorcycleCostingOptions,
  routeBendScore,
  routeDetourLimit,
  routeSelfCrossingArrows,
  StateHistory,
} from "./planner-core.mjs";

const reviewedSouthWalesCatalogue = JSON.parse(
  readFileSync(
    new URL("./data/discovery-catalogue.geojson", import.meta.url),
    "utf8",
  ),
);

function reviewedRoute(featureId) {
  const feature = reviewedSouthWalesCatalogue.features.find(
    (candidate) => candidate.properties.id === featureId,
  );
  const coordinates = feature.geometry.coordinates;
  return {
    distance: geometryDistance(coordinates),
    geometry: { coordinates },
  };
}

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

test("buildGpx creates app-compatible GPX metadata, waypoints and track", () => {
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
  assert.match(gpx, /<trkpt lat="53\.2345679" lon="-1\.9876543" \/>/);
  assert.match(gpx, /<time>2026-07-22T10:30:00\.000Z<\/time>/);
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
  const blackMountain = reviewedRoute("poc-a4069-black-mountain");
  const gospelPass = reviewedRoute("poc-gospel-pass-road");
  const blackMountainScore = routeBendScore(blackMountain);
  const gospelPassScore = routeBendScore(gospelPass);

  assert.equal(routeBendScore(blackMountain), blackMountainScore);
  assert.ok(blackMountainScore >= 14 && blackMountainScore <= 16);
  assert.ok(gospelPassScore >= 15 && gospelPassScore <= 20);

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
      exclude_highways: true,
      exclude_tolls: false,
      exclude_ferries: false,
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
      exclude_highways: false,
      exclude_tolls: true,
      exclude_ferries: true,
    },
  );
  assert.equal(
    motorcycleCostingOptions({ routeStyle: "very-twisty" }).use_highways,
    0.15,
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
