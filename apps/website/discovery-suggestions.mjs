export const DISCOVERY_SUGGESTION_QUEUE_KEY = "tec-discovery-suggestions-v1";
const MAX_QUEUE_SIZE = 25;
const MAX_QUEUE_AGE = 180 * 24 * 60 * 60 * 1000;
const CATEGORIES = new Set([
  "twisty_highlight",
  "mountain_pass",
  "good_biking_road",
  "biker_stop",
]);
const ACTIONS = new Set(["add", "correct", "remove"]);

export function suggestionSelectionGeoJson({ geometry, segmentStart } = {}) {
  const features = [];
  if (geometry?.type === "LineString" && validGeometry(geometry)) {
    features.push({
      type: "Feature",
      properties: { role: "road" },
      geometry,
    });
    const endpoints = [
      ["start", geometry.coordinates[0]],
      ["end", geometry.coordinates.at(-1)],
    ];
    for (const [role, coordinates] of endpoints) {
      features.push({
        type: "Feature",
        properties: { role },
        geometry: { type: "Point", coordinates },
      });
    }
  } else if (geometry?.type === "Point" && validGeometry(geometry)) {
    features.push({
      type: "Feature",
      properties: { role: "point" },
      geometry,
    });
  } else if (validCoordinate(segmentStart)) {
    features.push({
      type: "Feature",
      properties: { role: "start" },
      geometry: { type: "Point", coordinates: segmentStart },
    });
  }
  return { type: "FeatureCollection", features };
}

export function createSuggestionDraft(values, now = Date.now(), createId = defaultId) {
  const geometry = normalizeGeometry(
    values.geometry || {
      type: "Point",
      coordinates: [Number(values.longitude), Number(values.latitude)],
    },
  );
  if (
    !CATEGORIES.has(values.category) ||
    !ACTIONS.has(values.action || "add") ||
    !validGeometry(geometry)
  ) {
    throw new TypeError("Invalid discovery suggestion");
  }
  return {
    clientSubmissionId: createId(),
    category: values.category,
    action: values.action || "add",
    targetFeatureId: clean(values.targetFeatureId, 128) || null,
    name: clean(values.name, 120),
    reason: clean(values.reason, 500),
    evidenceUrl: clean(values.evidenceUrl, 500) || null,
    geometry,
    createdAt: new Date(now).toISOString(),
    status: "queued",
  };
}

export function encodeSuggestionQueue(queue) {
  return JSON.stringify({ version: 1, suggestions: queue.slice(-MAX_QUEUE_SIZE) });
}

export function decodeSuggestionQueue(serialized, now = Date.now()) {
  try {
    const parsed = JSON.parse(serialized || "");
    if (parsed?.version !== 1 || !Array.isArray(parsed.suggestions)) return [];
    return parsed.suggestions
      .filter((draft) => validateDraft(draft, now))
      .slice(-MAX_QUEUE_SIZE);
  } catch {
    return [];
  }
}

export function submissionPayload(draft) {
  const { status: _, ...payload } = draft;
  return payload;
}

function validateDraft(draft, now) {
  const createdAt = Date.parse(draft?.createdAt);
  return (
    typeof draft?.clientSubmissionId === "string" &&
    draft.clientSubmissionId.length <= 128 &&
    CATEGORIES.has(draft.category) &&
    ACTIONS.has(draft.action) &&
    typeof draft.name === "string" &&
    draft.name.length <= 120 &&
    typeof draft.reason === "string" &&
    draft.reason.length <= 500 &&
    validGeometry(draft.geometry) &&
    Number.isFinite(createdAt) &&
    createdAt <= now + 60_000 &&
    now - createdAt <= MAX_QUEUE_AGE &&
    ["queued", "submitted"].includes(draft.status)
  );
}

function validCoordinate(coordinate) {
  return (
    Array.isArray(coordinate) &&
    coordinate.length === 2 &&
    Number.isFinite(coordinate[0]) &&
    coordinate[0] >= -180 &&
    coordinate[0] <= 180 &&
    Number.isFinite(coordinate[1]) &&
    coordinate[1] >= -90 &&
    coordinate[1] <= 90
  );
}

function validGeometry(geometry) {
  if (geometry?.type === "Point") {
    return validCoordinate(geometry.coordinates);
  }
  return (
    geometry?.type === "LineString" &&
    Array.isArray(geometry.coordinates) &&
    geometry.coordinates.length >= 2 &&
    geometry.coordinates.length <= 200 &&
    geometry.coordinates.every(validCoordinate)
  );
}

function normalizeGeometry(geometry) {
  if (geometry?.type !== "LineString" || geometry.coordinates?.length <= 200) {
    return geometry;
  }
  const coordinates = [];
  for (let index = 0; index < 200; index += 1) {
    const sourceIndex = Math.round(
      (index * (geometry.coordinates.length - 1)) / 199,
    );
    coordinates.push(geometry.coordinates[sourceIndex]);
  }
  return { type: "LineString", coordinates };
}

function clean(value, maximumLength) {
  return String(value || "").trim().slice(0, maximumLength);
}

function defaultId() {
  return globalThis.crypto?.randomUUID?.() ||
    `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
