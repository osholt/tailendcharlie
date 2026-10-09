import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  boundedHeatmapViewport,
  GLOBAL_HEATMAP_INTENSITY,
  GLOBAL_HEATMAP_LAYER_OPACITY,
  GLOBAL_HEATMAP_RAMP,
  globalHeatmapColorExpression,
  globalHeatmapUrl,
  GlobalHeatmapLoader,
} from "./global-heatmap.mjs";

const viewport = { west: -3, south: 51, east: -2, north: 52, zoom: 12.4 };

test("public requests are bounded and contain no private archive endpoint", () => {
  const url = globalHeatmapUrl("https://relay.example", viewport);
  assert.equal(url.pathname, "/api/v1/heatmap/cells");
  assert.equal(url.searchParams.get("zoom"), "12");
  assert.equal(boundedHeatmapViewport({ ...viewport, west: -20 }), null);
  assert.equal(
    boundedHeatmapViewport({ ...viewport, west: -11.6, east: -5 }),
    null,
  );
  assert.doesNotMatch(url.href, /ride|archive|contributor|credential/i);
});

test("superseded viewport requests are aborted and only the latest replaces data", async () => {
  const resolvers = [];
  const snapshots = [];
  const loader = new GlobalHeatmapLoader({
    apiBase: "https://relay.example",
    delay: 0,
    fetchImpl: (_url, options) =>
      new Promise((resolve, reject) => {
        options.signal.addEventListener("abort", () => {
          const error = new Error("aborted");
          error.name = "AbortError";
          reject(error);
        });
        resolvers.push(resolve);
      }),
    onSnapshot: (snapshot) => snapshots.push(snapshot.snapshotVersion),
  });
  loader.setEnabled(true);
  const first = loader.load(globalHeatmapUrl(loader.apiBase, viewport));
  const second = loader.load(
    globalHeatmapUrl(loader.apiBase, { ...viewport, west: -2.9 }),
  );
  resolvers[1]({
    ok: true,
    json: async () => ({ type: "FeatureCollection", snapshotVersion: "new", features: [] }),
  });
  await Promise.all([first, second]);
  assert.deepEqual(snapshots, ["new"]);
});

test("offline failures retain the last valid snapshot", async () => {
  const statuses = [];
  let calls = 0;
  const loader = new GlobalHeatmapLoader({
    apiBase: "https://relay.example",
    delay: 0,
    fetchImpl: async () => {
      calls += 1;
      if (calls === 1) {
        return {
          ok: true,
          json: async () => ({ type: "FeatureCollection", snapshotVersion: "one", features: [] }),
        };
      }
      throw new Error("offline");
    },
    onStatus: (status) => statuses.push(status),
  });
  loader.setEnabled(true);
  const url = globalHeatmapUrl(loader.apiBase, viewport);
  await loader.load(url);
  await loader.load(url);
  assert.equal(loader.lastSnapshot.snapshotVersion, "one");
  assert.match(statuses.at(-1), /Offline/);
});

// --- #913: the global layer's colours -------------------------------------

// The discovery highlights the heat layer must never be mistaken for, as the
// planner draws them (apps/website/discovery-catalogue.mjs): twisty orange,
// mountain-pass teal, good-biking-road blue.
const DISCOVERY = { twisty: "#f97316", pass: "#0f9d8a", good: "#2583e9" };
// The phone's personal layer, for "related to it but not the same".
const PERSONAL_LOW = "#7c3aed";
// OpenFreeMap Liberty, the planner's only basemap: ground, then the road fills
// the web layer is also drawn over (it has no road layer to sit under).
const LIBERTY = {
  background: "#f8f4f0",
  park: "#d8e8c8",
  water: "#9ebdff",
  road: "#ffffff",
  trunk: "#ffeeaa",
  motorway: "#ffcc88",
};

const rgb = (hex) => [1, 3, 5].map((i) => Number.parseInt(hex.slice(i, i + 2), 16));
const luminance = ([r, g, b]) => {
  const lin = (c) => {
    const v = c / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
};
const contrast = (a, b) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};
const over = (fg, bg, alpha) => fg.map((c, i) => bg[i] * (1 - alpha) + c * alpha);
function hue([r, g, b]) {
  const [R, G, B] = [r, g, b].map((c) => c / 255);
  const max = Math.max(R, G, B);
  const delta = max - Math.min(R, G, B);
  if (delta === 0) return 0;
  const h =
    max === R ? ((G - B) / delta) % 6 : max === G ? (B - R) / delta + 2 : (R - G) / delta + 4;
  return (h * 60 + 360) % 360;
}
const hueGap = (a, b) => {
  const gap = Math.abs(hue(rgb(a)) - hue(rgb(b)));
  return Math.min(gap, 360 - gap);
};

test("the global ramp is the documented pink-to-crimson heat, rising in opacity", () => {
  assert.deepEqual(
    GLOBAL_HEATMAP_RAMP.map(({ density, color, alpha }) => [density, color, alpha]),
    [
      [0.2, "#ec4899", 0.5],
      [0.55, "#db2777", 0.6],
      [1, "#be123c", 0.75],
    ],
  );
  assert.equal(GLOBAL_HEATMAP_INTENSITY, 0.8);
  assert.equal(GLOBAL_HEATMAP_LAYER_OPACITY, 1);
  // The lowest published weight (0.25) lands on the cold stop at the centre of
  // a cell, so a sparse road is drawn in the ramp's first colour, not below it.
  assert.equal(0.25 * GLOBAL_HEATMAP_INTENSITY, GLOBAL_HEATMAP_RAMP[0].density);
  for (let i = 1; i < GLOBAL_HEATMAP_RAMP.length; i += 1) {
    assert.ok(GLOBAL_HEATMAP_RAMP[i].density > GLOBAL_HEATMAP_RAMP[i - 1].density);
    assert.ok(GLOBAL_HEATMAP_RAMP[i].alpha >= GLOBAL_HEATMAP_RAMP[i - 1].alpha);
  }
});

test("the MapLibre colour expression starts transparent in the cold colour", () => {
  assert.deepEqual(globalHeatmapColorExpression(), [
    "interpolate",
    ["linear"],
    ["heatmap-density"],
    0,
    "rgba(236,72,153,0)",
    0.2,
    "rgba(236,72,153,0.5)",
    0.55,
    "rgba(219,39,119,0.6)",
    1,
    "rgba(190,18,60,0.75)",
  ]);
});

test("no stop can be mistaken for a discovery highlight or the personal violet", () => {
  for (const { color } of GLOBAL_HEATMAP_RAMP) {
    for (const [name, highlight] of Object.entries(DISCOVERY)) {
      assert.ok(
        hueGap(color, highlight) >= 35,
        `${color} is within 35 degrees of the ${name} highlight`,
      );
    }
    assert.ok(hueGap(color, PERSONAL_LOW) >= 35, `${color} reads as the personal layer`);
  }
});

test("every stop stays visible over the basemap grounds and road fills", () => {
  for (const { color, alpha } of GLOBAL_HEATMAP_RAMP) {
    for (const [surface, hex] of Object.entries(LIBERTY)) {
      const ground = rgb(hex);
      const ratio = contrast(over(rgb(color), ground, alpha * GLOBAL_HEATMAP_LAYER_OPACITY), ground);
      assert.ok(ratio >= 1.4, `${color} over ${surface} measures ${ratio.toFixed(2)}:1`);
    }
  }
});

test("the planner draws the shared ramp and its legend shows the same colours", async () => {
  const [plannerJs, plannerCss] = await Promise.all([
    readFile(new URL("./planner.js", import.meta.url), "utf8"),
    readFile(new URL("./planner.css", import.meta.url), "utf8"),
  ]);
  assert.match(plannerJs, /"heatmap-color": globalHeatmapColorExpression\(\)/);
  assert.match(plannerJs, /"heatmap-intensity": GLOBAL_HEATMAP_INTENSITY/);
  assert.match(plannerJs, /"heatmap-opacity": GLOBAL_HEATMAP_LAYER_OPACITY/);
  assert.doesNotMatch(plannerJs, /0ea5e9|f59e0b|ef4444/i, "the old blue-to-red literals are gone");
  const legend = plannerCss.match(/\.legend-global-rides\s*\{[^}]*linear-gradient\(([^)]*)\)/);
  assert.ok(legend, "the legend swatch has a gradient");
  assert.deepEqual(
    legend[1].match(/#[0-9a-f]{6}/gi).map((c) => c.toLowerCase()),
    GLOBAL_HEATMAP_RAMP.map(({ color }) => color),
  );
});
