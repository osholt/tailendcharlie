import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  discoveryFeatureAnchor,
  discoveryRoadFacts,
  discoveryRouteStop,
  ENFORCEMENT_RECORD_CAVEAT,
  filterDiscoveryFeatures,
  nearbyDiscoveryFeatures,
  NOT_RECORDED,
} from "./discovery-catalogue.mjs";

const collection = {
  type: "FeatureCollection",
  features: [
    {
      type: "Feature",
      properties: { id: "pass", category: "mountain_pass" },
      geometry: { type: "Point", coordinates: [-3.11, 52.01] },
    },
    {
      type: "Feature",
      properties: { id: "road", category: "good_biking_road" },
      geometry: {
        type: "LineString",
        coordinates: [
          [-3.2, 52],
          [-3.1, 52.1],
          [-3, 52.2],
        ],
      },
    },
  ],
};

test("filters independently enabled discovery categories to the viewport", () => {
  assert.deepEqual(
    filterDiscoveryFeatures(
      collection,
      { west: -3.15, south: 51.9, east: -3.05, north: 52.05 },
      ["mountain_pass"],
    ).features.map((feature) => feature.properties.id),
    ["pass"],
  );
  assert.equal(filterDiscoveryFeatures(collection, null, []).features.length, 0);
});

test("uses the midpoint of a road as its route-via-here anchor", () => {
  assert.deepEqual(discoveryFeatureAnchor(collection.features[1]), [-3.1, 52.1]);
  const existingStops = [{ name: "Start", longitude: -3.3, latitude: 51.9 }];
  existingStops.push(discoveryRouteStop(collection.features[1]));
  assert.deepEqual(existingStops, [
    { name: "Start", longitude: -3.3, latitude: 51.9 },
    { name: "Good biking roads", longitude: -3.1, latitude: 52.1 },
  ]);
});

test("finds nearby published entries before a suggestion is queued", () => {
  const nearby = nearbyDiscoveryFeatures(collection, [-3.11, 52.01], 2);
  assert.deepEqual(nearby.map((entry) => entry.feature.properties.id), ["pass"]);
});

test("web and mobile ship the same reviewed proof-of-concept geometry", () => {
  const web = JSON.parse(
    readFileSync(new URL("./data/discovery-catalogue.geojson", import.meta.url)),
  );
  const mobile = JSON.parse(
    readFileSync(
      new URL("../mobile/assets/discovery_catalogue.geojson", import.meta.url),
    ),
  );
  const geometryById = (catalogue) =>
    Object.fromEntries(
      catalogue.features.map((feature) => [
        feature.properties.id,
        feature.geometry,
      ]),
    );
  assert.deepEqual(geometryById(mobile), geometryById(web));
});

// #160, mirrored one-for-one by
// apps/mobile/test/services/discovery_road_facts_test.dart so the website and
// the app cannot phrase the same fact two different ways.
test("a tagged speed limit reads as a limit and states its provenance", () => {
  const facts = discoveryRoadFacts({
    speedLimit: { value: "60 mph", provenance: "tagged" },
  });

  assert.equal(facts.speedLimit, "60 mph");
  assert.equal(facts.speedLimitIsKnown, true);
  assert.equal(
    facts.speedLimitProvenance,
    "Recorded in OpenStreetMap for this road.",
  );
});

test("a mixed tagged limit states its range rather than one number", () => {
  assert.equal(
    discoveryRoadFacts({
      speedLimit: {
        value: "50 mph",
        provenance: "tagged",
        mixed: true,
        range: ["40 mph", "60 mph"],
      },
    }).speedLimit,
    "50 mph · varies from 40 mph to 60 mph",
  );
});

test("an inferred limit is not presented as a posted value", () => {
  const facts = discoveryRoadFacts({
    speedLimit: { value: "60 mph", provenance: "inferred-from-maxspeed-type" },
  });

  assert.equal(facts.speedLimitIsKnown, true);
  assert.equal(
    facts.speedLimitProvenance,
    "Implied by a national speed limit tag in OpenStreetMap, not a posted value for this road.",
  );
});

test("an unknown limit reads as not known, never as unrestricted", () => {
  const facts = discoveryRoadFacts({
    speedLimit: {
      value: null,
      provenance: "unknown",
      note: "OpenStreetMap does not record a limit for this road.",
    },
  });

  assert.equal(facts.speedLimit, "Speed limit not known");
  assert.equal(facts.speedLimitIsKnown, false);
  assert.equal(
    facts.speedLimitProvenance,
    "OpenStreetMap does not record a limit for this road.",
  );
  assert.doesNotMatch(facts.speedLimit, /mph/);
  assert.doesNotMatch(facts.speedLimit, /[Nn]ational/);
});

test("an absent speedLimit field degrades to not known", () => {
  const facts = discoveryRoadFacts({});

  assert.equal(facts.speedLimit, "Speed limit not known");
  assert.equal(facts.speedLimitIsKnown, false);
  assert.equal(
    facts.speedLimitProvenance,
    `A speed limit for this road is ${NOT_RECORDED}.`,
  );
});

test("a mapped limit and an unknown limit are distinguishable", () => {
  const tagged = discoveryRoadFacts({
    speedLimit: { value: "60 mph", provenance: "tagged" },
  });
  const unknown = discoveryRoadFacts({ speedLimit: { provenance: "unknown" } });

  assert.notEqual(tagged.speedLimit, unknown.speedLimit);
  assert.notEqual(tagged.speedLimitIsKnown, unknown.speedLimitIsKnown);
});

test('enforcement copy says "not recorded in OpenStreetMap", never "none"', () => {
  const facts = discoveryRoadFacts({
    averageSpeedCheck: { present: false },
    fixedSpeedCameras: 0,
  });

  assert.equal(
    facts.enforcement,
    `Average speed check: ${NOT_RECORDED} for this road.`,
  );
  assert.equal(
    facts.fixedCameras,
    `Fixed speed cameras: ${NOT_RECORDED} near this road.`,
  );
  assert.equal(facts.hasRecordedEnforcement, false);
  for (const line of facts.enforcementLines) {
    assert.doesNotMatch(line.toLowerCase(), /none/);
    assert.doesNotMatch(line.toLowerCase(), /no cameras/);
  }
  // Never the final word: the caveat says an absent record is not an absent
  // camera.
  assert.equal(facts.enforcementLines.at(-1), ENFORCEMENT_RECORD_CAVEAT);
});

test("an absent enforcement field is weaker than a checked one", () => {
  const facts = discoveryRoadFacts({});

  assert.equal(
    facts.enforcement,
    "Average speed check: not checked for this road.",
  );
  assert.equal(
    facts.fixedCameras,
    "Fixed speed cameras: not checked for this road.",
  );
  assert.equal(facts.enforcementLines.at(-1), ENFORCEMENT_RECORD_CAVEAT);
});

test("a present average-speed relation is stated plainly and not caveated", () => {
  const facts = discoveryRoadFacts({
    averageSpeedCheck: {
      present: true,
      relation: "relation/18112962",
      enforcedLimit: "50 mph",
    },
  });

  assert.equal(
    facts.enforcement,
    "Average speed check: recorded in OpenStreetMap at 50 mph.",
  );
  assert.equal(facts.hasRecordedEnforcement, true);
  assert.ok(!facts.enforcementLines.includes(ENFORCEMENT_RECORD_CAVEAT));
});

test("camera counts are reported, and zero is not a count", () => {
  assert.equal(
    discoveryRoadFacts({ fixedSpeedCameras: 1 }).fixedCameras,
    "Fixed speed cameras: 1 recorded in OpenStreetMap near this road.",
  );
  assert.equal(
    discoveryRoadFacts({ fixedSpeedCameras: 3 }).fixedCameras,
    "Fixed speed cameras: 3 recorded in OpenStreetMap near this road.",
  );
  assert.match(
    discoveryRoadFacts({ fixedSpeedCameras: 0 }).fixedCameras,
    new RegExp(NOT_RECORDED),
  );
});

test("a researched enforcement caveat sits beside the OSM record", () => {
  // The Snake Pass case: OSM records no relation, but cameras have been
  // publicly proposed.
  const facts = discoveryRoadFacts({
    averageSpeedCheck: { present: false },
    fixedSpeedCameras: 0,
    enforcementNote:
      "The Peak District authority has considered average speed cameras here.",
  });

  assert.equal(facts.enforcementLines.length, 4);
  assert.equal(facts.enforcementLines[2], facts.enforcementCaveat);
});

test("no field invents a police-checks likelihood", () => {
  const facts = discoveryRoadFacts({
    averageSpeedCheck: { present: false },
    fixedSpeedCameras: 0,
  });

  for (const line of [
    ...facts.enforcementLines,
    facts.busyPeriods,
    facts.speedLimitProvenance,
    facts.researchDetail,
  ]) {
    assert.doesNotMatch(line.toLowerCase(), /likely/);
    assert.doesNotMatch(line.toLowerCase(), /police check/);
  }
});

test("busy periods and the rider description degrade honestly", () => {
  assert.equal(
    discoveryRoadFacts({ busyPeriods: "Jams on summer weekends." }).busyPeriods,
    "Jams on summer weekends.",
  );
  const absent = discoveryRoadFacts({});
  assert.equal(absent.busyPeriods, "Busy periods have not been researched.");
  assert.doesNotMatch(absent.busyPeriods.toLowerCase(), /quiet/);
  assert.equal(absent.description, null);
  assert.equal(discoveryRoadFacts({ riderNote: "  " }).description, null);
});

test("a pending candidate is distinguishable from a researched one", () => {
  const pending = discoveryRoadFacts({ researchStatus: "pending" });
  const researched = discoveryRoadFacts({
    researchStatus: "researched",
    sourceVerification: "fetched",
    evidenceSources: ["https://en.wikipedia.org/wiki/Horseshoe_Pass"],
  });

  assert.equal(pending.isVerified, false);
  assert.equal(pending.researchLabel, "Not yet reviewed");
  assert.match(pending.researchDetail, /not yet checked by a person/);
  assert.equal(researched.isVerified, true);
  assert.equal(researched.researchLabel, "Researched");
  assert.notEqual(pending.researchDetail, researched.researchDetail);
  assert.equal(researched.evidenceSources.length, 1);
  // An unstated status is no better than pending.
  assert.equal(discoveryRoadFacts({}).researchLabel, "Not yet reviewed");
});

test("source verification distinguishes fetched, listing-only, and missing evidence", () => {
  const fetched = discoveryRoadFacts({ sourceVerification: "fetched" });
  assert.equal(fetched.sourceIsFetched, true);
  assert.equal(fetched.sourceVerificationLabel, "Source checked");
  assert.match(fetched.sourceVerificationDetail, /page was retrieved/);

  const listing = discoveryRoadFacts({
    researchStatus: "researched",
    sourceVerification: "listing-only",
  });
  assert.equal(listing.sourceIsFetched, false);
  assert.equal(listing.sourceVerificationLabel, "Listing evidence only");
  assert.match(listing.sourceVerificationDetail, /does not verify.*riding quality/);
  assert.match(listing.researchDetail, /only as a listing/);

  for (const value of [undefined, "unexpected"]) {
    const cautious = discoveryRoadFacts({ sourceVerification: value });
    assert.equal(cautious.sourceIsFetched, false);
    assert.equal(cautious.sourceVerificationLabel, "Source check not recorded");
    assert.match(cautious.sourceVerificationDetail, /claim cautiously/);
  }
});
