import assert from "node:assert/strict";
import test from "node:test";

import {
  decodePlannerDraft,
  encodePlannerDraft,
  PLANNER_DRAFT_MAX_AGE,
} from "./planner-storage.mjs";

const now = Date.UTC(2026, 6, 22, 12);
const validDraft = {
  rideName: "Sunday loop",
  stops: [
    { id: 1, name: "Start", longitude: -2.5, latitude: 51.5 },
    { id: 2, name: "Cafe", longitude: -2.2, latitude: 51.7 },
  ],
  shapingPoints: [
    { id: 1, segmentStartId: 1, longitude: -2.35, latitude: 51.6 },
  ],
  routeCoordinates: [
    [-2.5, 51.5],
    [-2.2, 51.7],
  ],
  routeDistance: 24_000,
  routeDuration: 1_800,
  routeBendScore: 28.4,
  routeStyle: "twisty",
  avoidMotorways: true,
  avoidMajorRoads: false,
  avoidTolls: true,
  avoidFerries: false,
  bikerLayerVisible: false,
};

test("planner drafts round-trip all locally saved route work", () => {
  assert.deepEqual(
    decodePlannerDraft(encodePlannerDraft(validDraft, now), { now }),
    { savedAt: now, ...validDraft },
  );
});

test("planner drafts reject expired or malformed browser data", () => {
  assert.equal(
    decodePlannerDraft(
      encodePlannerDraft(validDraft, now - PLANNER_DRAFT_MAX_AGE - 1),
      { now },
    ),
    null,
  );
  assert.equal(
    decodePlannerDraft(
      encodePlannerDraft(
        {
          ...validDraft,
          stops: [{ id: 1, name: "Bad", longitude: 500, latitude: 0 }],
        },
        now,
      ),
      { now },
    ),
    null,
  );
  assert.equal(decodePlannerDraft("not json", { now }), null);
});
