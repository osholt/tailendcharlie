import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const plannerCss = await readFile(
  new URL("./planner.css", import.meta.url),
  "utf8",
);
const plannerHtml = await readFile(
  new URL("./planner.html", import.meta.url),
  "utf8",
);
const plannerJs = await readFile(
  new URL("./planner.js", import.meta.url),
  "utf8",
);
const plannerCore = await readFile(
  new URL("./planner-core.mjs", import.meta.url),
  "utf8",
);
const globalHeatmap = await readFile(
  new URL("./global-heatmap.mjs", import.meta.url),
  "utf8",
);
const headers = await readFile(new URL("./_headers", import.meta.url), "utf8");

test("the enabled app-code action is visually distinct from disabled actions", () => {
  const enabledRule = plannerCss.match(
    /\.planner-actions \.button-secondary:not\(:disabled\)\s*\{(?<body>[^}]+)\}/,
  );
  const disabledRule = plannerCss.match(
    /\.planner-actions \.button:disabled\s*\{(?<body>[^}]+)\}/,
  );

  assert.ok(enabledRule, "missing enabled secondary-action style");
  assert.ok(disabledRule, "missing disabled action style");
  assert.match(enabledRule.groups.body, /border:/);
  assert.match(enabledRule.groups.body, /background:/);
  assert.notEqual(enabledRule.groups.body.trim(), disabledRule.groups.body.trim());
});

test("planner asset versions match their content so deployed fixes replace cached copies", () => {
  const version = (content) =>
    createHash("sha256").update(content).digest("hex").slice(0, 8);
  assert.match(
    plannerHtml,
    new RegExp(`href="/planner\\.css\\?v=${version(plannerCss)}"`),
  );
  assert.match(
    plannerHtml,
    new RegExp(`src="/planner\\.js\\?v=${version(plannerJs)}"`),
  );
  assert.match(
    plannerJs,
    new RegExp(
      `from "\\./planner-core\\.mjs\\?v=${version(plannerCore)}"`,
    ),
  );
  assert.match(
    plannerJs,
    new RegExp(
      `from "\\./global-heatmap\\.mjs\\?v=${version(globalHeatmap)}"`,
    ),
  );
});

test("email route is a visible route action rather than a hidden result", () => {
  assert.match(
    plannerHtml,
    /<button class="button button-secondary" id="email-plan" disabled>/,
  );
  assert.match(plannerHtml, /Email route/);
});

test("circular and day ride generation is available in the editable planner", () => {
  assert.match(plannerHtml, /id="circular-direction"/);
  assert.match(plannerHtml, /id="circular-distance"/);
  assert.match(plannerHtml, /id="circular-fuel-frequency"/);
  assert.match(plannerHtml, /id="circular-comfort-frequency"/);
  assert.match(plannerHtml, /id="circular-meal-time"/);
  assert.match(plannerHtml, /id="circular-heatmap-preference"/);
  assert.match(plannerHtml, /id="generate-circular-another"/);
  assert.match(plannerJs, /circularRideShapingCoordinates/);
  assert.match(plannerJs, /Suggested \$\{needs\}/);
  assert.match(plannerJs, /routeStops\(true\)/);
});

test("global rides stay below the editable route and do not capture gestures", () => {
  const heatmapLayer = plannerJs.indexOf('id: "global-rides-heatmap"');
  const routeLayer = plannerJs.indexOf('id: "road-route-casing"');
  assert.ok(heatmapLayer >= 0 && heatmapLayer < routeLayer);
  assert.doesNotMatch(
    plannerJs,
    /map\.on\([^\n]+"global-rides-heatmap"/,
  );
  assert.match(plannerJs, /canvas\.addEventListener\("pointerdown"/);
  assert.match(headers, /connect-src[^\n]+https:\/\/relay\.tailendcharlie\.app/);
});

test("global viewing is opt-in and never exposes a private mobile endpoint", () => {
  assert.match(plannerHtml, /id="layer-global-rides" type="checkbox"/);
  assert.match(plannerHtml, /Viewing never contributes your rides/);
  assert.doesNotMatch(
    `${plannerJs}\n${globalHeatmap}`,
    /completed.?rides|ride.?archive|contributors\/current/i,
  );
});

test("marker review is keyboard-accessible and explains its advisory status", () => {
  assert.match(plannerHtml, /id="marker-review"/);
  assert.match(plannerHtml, /id="marker-candidate"/);
  assert.match(plannerHtml, /Yellow dots are suggested turn-marker positions/);
  assert.match(plannerJs, /dataset\.markerAction/);
  assert.match(plannerJs, /"safety-review"/);
});

test("discovery source confidence is surfaced in the road details", () => {
  assert.match(plannerJs, /"Source confidence"/);
  assert.match(plannerJs, /facts\.sourceVerificationLabel/);
  assert.match(plannerJs, /facts\.sourceVerificationDetail/);
});
