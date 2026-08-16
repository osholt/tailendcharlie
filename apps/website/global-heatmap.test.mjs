import assert from "node:assert/strict";
import test from "node:test";

import {
  boundedHeatmapViewport,
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
