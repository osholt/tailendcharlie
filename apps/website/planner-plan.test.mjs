import assert from "node:assert/strict";
import test from "node:test";

import {
  buildPlanEmailHref,
  buildPlannerPlanUrl,
  createRoutePlan,
  fetchRoutePlan,
  normalizePlanCode,
} from "./planner-plan.mjs";

function jsonResponse(payload, { status = 200 } = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

test("plan codes and share links are normalized", () => {
  assert.equal(normalizePlanCode(" 7f3k9qrt "), "7F3K9QRT");
  assert.equal(
    buildPlannerPlanUrl(
      "7f3k9qrt",
      "https://tailendcharlie.app/planner.html?old=1#route",
    ),
    "https://tailendcharlie.app/planner.html?code=7F3K9QRT",
  );
  assert.throws(() => normalizePlanCode("not valid"));
});

test("creating a plan sends the GPX and validates the response", async () => {
  let request;
  const created = await createRoutePlan({
    apiBase: "https://relay.tailendcharlie.app/",
    name: "Sunday loop",
    gpx: "<gpx />",
    fetchImpl: async (url, options) => {
      request = { url, options };
      return jsonResponse({
        code: "7F3K9QRT",
        expiresAt: "2026-08-22T12:00:00Z",
      });
    },
  });

  assert.equal(request.url, "https://relay.tailendcharlie.app/api/v1/plans");
  assert.deepEqual(JSON.parse(request.options.body), {
    name: "Sunday loop",
    gpx: "<gpx />",
  });
  assert.deepEqual(created, {
    code: "7F3K9QRT",
    expiresAt: "2026-08-22T12:00:00.000Z",
  });
});

test("fetching a plan returns its GPX and explains expired codes", async () => {
  const plan = await fetchRoutePlan({
    apiBase: "https://relay.tailendcharlie.app",
    code: "7f3k9qrt",
    fetchImpl: async () =>
      jsonResponse({
        code: "7F3K9QRT",
        name: "Sunday loop",
        gpx: "<gpx />",
        expiresAt: "2026-08-22T12:00:00Z",
      }),
  });
  assert.equal(plan.gpx, "<gpx />");

  await assert.rejects(
    fetchRoutePlan({
      apiBase: "https://relay.tailendcharlie.app",
      code: "7F3K9QRT",
      fetchImpl: async () => jsonResponse({ error: "missing" }, { status: 404 }),
    }),
    /not found/,
  );
});

test("email handoff includes the editable link and app instructions", () => {
  const href = buildPlanEmailHref({
    name: "Sunday loop",
    code: "7F3K9QRT",
    planUrl: "https://tailendcharlie.app/planner.html?code=7F3K9QRT",
    expiresAt: "2026-08-22T12:00:00Z",
    routeSummary:
      "Distance: 84 mi\nEstimated time: 2 hr 18 min\nBend score: 22°/km · Twisty",
  });
  const decoded = decodeURIComponent(href);
  assert.match(decoded, /Sunday loop/);
  assert.match(decoded, /planner\.html\?code=7F3K9QRT/);
  assert.match(decoded, /Load a planned route/);
  assert.match(decoded, /Distance: 84 mi/);
  assert.match(decoded, /Estimated time: 2 hr 18 min/);
  assert.match(decoded, /Bend score: 22°\/km · Twisty/);
});
