export const GLOBAL_HEATMAP_VISIBLE_KEY = "tec-global-heatmap-visible-v1";

// The global layer's colours (#913). The phone's copy is `globalHeatmapRamp` in
// apps/mobile/lib/features/map/heatmap_ramp.dart and a test holds the two to
// each other. Pink through deeper pink to crimson, more opaque as a road gets
// busier: never the blue, teal or orange of the discovery highlights.
export const GLOBAL_HEATMAP_INTENSITY = 0.8;
export const GLOBAL_HEATMAP_LAYER_OPACITY = 1;
export const GLOBAL_HEATMAP_RAMP = Object.freeze([
  Object.freeze({ density: 0.2, color: "#ec4899", alpha: 0.5 }),
  Object.freeze({ density: 0.55, color: "#db2777", alpha: 0.6 }),
  Object.freeze({ density: 1, color: "#be123c", alpha: 0.75 }),
]);

function rgba(hex, alpha) {
  const channel = (offset) => Number.parseInt(hex.slice(offset, offset + 2), 16);
  return `rgba(${channel(1)},${channel(3)},${channel(5)},${alpha})`;
}

/** The MapLibre `heatmap-color` expression: transparent in the first stop's own
 * colour, so rising to it never passes through grey. */
export function globalHeatmapColorExpression(ramp = GLOBAL_HEATMAP_RAMP) {
  return [
    "interpolate",
    ["linear"],
    ["heatmap-density"],
    0,
    rgba(ramp[0].color, 0),
    ...ramp.flatMap(({ density, color, alpha }) => [density, rgba(color, alpha)]),
  ];
}

export function boundedHeatmapViewport({ west, south, east, north, zoom }) {
  const values = [west, south, east, north, zoom].map(Number);
  if (values.some((value) => !Number.isFinite(value))) return null;
  const [safeWest, safeSouth, safeEast, safeNorth, safeZoom] = values;
  if (
    safeWest < -11.5 ||
    safeEast > 3 ||
    safeSouth < 49 ||
    safeNorth > 61.5 ||
    safeWest >= safeEast ||
    safeSouth >= safeNorth ||
    safeEast - safeWest > 8 ||
    safeNorth - safeSouth > 8 ||
    (safeEast - safeWest) * (safeNorth - safeSouth) > 25
  ) {
    return null;
  }
  return {
    west: safeWest,
    south: safeSouth,
    east: safeEast,
    north: safeNorth,
    zoom: Math.max(6, Math.min(18, Math.round(safeZoom))),
  };
}

export function globalHeatmapUrl(apiBase, viewport) {
  const bounded = boundedHeatmapViewport(viewport);
  if (!bounded || !apiBase) return null;
  const url = new URL(`${String(apiBase).replace(/\/$/, "")}/api/v1/heatmap/cells`);
  for (const [key, value] of Object.entries(bounded)) {
    url.searchParams.set(key, String(value));
  }
  return url;
}

export class GlobalHeatmapLoader {
  constructor({ apiBase, fetchImpl = fetch, delay = 450, onSnapshot, onStatus }) {
    this.apiBase = apiBase;
    this.fetchImpl = fetchImpl;
    this.delay = delay;
    this.onSnapshot = onSnapshot;
    this.onStatus = onStatus;
    this.enabled = false;
    this.timer = null;
    this.request = null;
    this.sequence = 0;
    this.lastSnapshot = null;
  }

  setEnabled(enabled) {
    this.enabled = Boolean(enabled);
    if (!this.enabled) {
      clearTimeout(this.timer);
      this.request?.abort();
      this.onStatus?.("Global rides are off.");
    }
  }

  schedule(viewport, { immediate = false } = {}) {
    clearTimeout(this.timer);
    if (!this.enabled) return;
    const url = globalHeatmapUrl(this.apiBase, viewport);
    if (!url) {
      this.onStatus?.("Zoom into Great Britain to load global rides.");
      return;
    }
    this.timer = setTimeout(() => void this.load(url), immediate ? 0 : this.delay);
  }

  async load(url) {
    this.request?.abort();
    this.request = new AbortController();
    const sequence = ++this.sequence;
    this.onStatus?.("Loading global ride coverage…");
    try {
      const response = await this.fetchImpl(url, {
        headers: { Accept: "application/geo+json, application/json" },
        signal: this.request.signal,
      });
      if (!response.ok) throw new Error(`Global heatmap failed (${response.status}).`);
      const snapshot = await response.json();
      if (
        sequence !== this.sequence ||
        snapshot?.type !== "FeatureCollection" ||
        !Array.isArray(snapshot.features)
      ) {
        return;
      }
      this.lastSnapshot = snapshot;
      this.onSnapshot?.(snapshot);
      this.onStatus?.(
        snapshot.features.length
          ? `Global rides · public snapshot ${snapshot.snapshotDate || "available"}.`
          : "No public coverage here yet; sparse roads stay hidden.",
      );
    } catch (error) {
      if (error?.name === "AbortError" || sequence !== this.sequence) return;
      this.onStatus?.(
        this.lastSnapshot
          ? "Offline — showing the last loaded public coverage."
          : "Global ride coverage is unavailable.",
      );
    }
  }
}
