export const PLANNER_DRAFT_KEY = "tec-planner-draft-v1";
export const PLANNER_DRAFT_MAX_AGE = 180 * 24 * 60 * 60 * 1000;

export function encodePlannerDraft(state, savedAt = Date.now()) {
  return JSON.stringify({ version: 1, savedAt, ...state });
}

export function decodePlannerDraft(
  serialized,
  { now = Date.now(), maxAge = PLANNER_DRAFT_MAX_AGE, maxStops = 50 } = {},
) {
  try {
    const draft = JSON.parse(serialized);
    if (
      draft?.version !== 1 ||
      !Number.isFinite(draft.savedAt) ||
      draft.savedAt > now + 60_000 ||
      now - draft.savedAt > maxAge ||
      typeof draft.rideName !== "string" ||
      draft.rideName.length > 100 ||
      !Array.isArray(draft.stops) ||
      draft.stops.length > maxStops
    ) {
      return null;
    }

    const stopIds = new Set();
    const stops = draft.stops.map((stop) => {
      if (
        !Number.isInteger(stop?.id) ||
        stopIds.has(stop.id) ||
        !validCoordinate(stop.longitude, stop.latitude)
      ) {
        throw new Error("Invalid saved stop");
      }
      stopIds.add(stop.id);
      return {
        id: stop.id,
        name: String(stop.name || "").slice(0, 100),
        longitude: Number(stop.longitude),
        latitude: Number(stop.latitude),
      };
    });

    const shapingPoints = Array.isArray(draft.shapingPoints)
      ? draft.shapingPoints.map((point) => {
          if (
            !Number.isInteger(point?.id) ||
            !stopIds.has(point.segmentStartId) ||
            !validCoordinate(point.longitude, point.latitude)
          ) {
            throw new Error("Invalid saved route adjustment");
          }
          return {
            id: point.id,
            segmentStartId: point.segmentStartId,
            longitude: Number(point.longitude),
            latitude: Number(point.latitude),
          };
        })
      : [];

    const routeCoordinates = Array.isArray(draft.routeCoordinates)
      ? draft.routeCoordinates.map((coordinate) => {
          if (
            !Array.isArray(coordinate) ||
            !validCoordinate(coordinate[0], coordinate[1])
          ) {
            throw new Error("Invalid saved route coordinate");
          }
          return [Number(coordinate[0]), Number(coordinate[1])];
        })
      : [];
    if (routeCoordinates.length > 200_000) return null;
    if (stops.length < 2) routeCoordinates.length = 0;
    const hasSavedRoute = routeCoordinates.length > 1;

    return {
      savedAt: draft.savedAt,
      rideName: draft.rideName,
      stops,
      shapingPoints,
      routeCoordinates,
      routeDistance: hasSavedRoute ? validSummaryValue(draft.routeDistance) : null,
      routeDuration: hasSavedRoute ? validSummaryValue(draft.routeDuration) : null,
      routeBendScore: hasSavedRoute ? validSummaryValue(draft.routeBendScore) : null,
      routeStyle: ["balanced", "twisty", "very-twisty"].includes(draft.routeStyle)
        ? draft.routeStyle
        : "quickest",
      avoidMotorways: Boolean(draft.avoidMotorways),
      avoidMajorRoads: Boolean(draft.avoidMajorRoads),
      avoidTolls: Boolean(draft.avoidTolls),
      avoidFerries: Boolean(draft.avoidFerries),
      bikerLayerVisible: draft.bikerLayerVisible !== false,
    };
  } catch {
    return null;
  }
}

function validCoordinate(longitude, latitude) {
  return (
    Number.isFinite(Number(longitude)) &&
    Number.isFinite(Number(latitude)) &&
    Number(longitude) >= -180 &&
    Number(longitude) <= 180 &&
    Number(latitude) >= -90 &&
    Number(latitude) <= 90
  );
}

function validSummaryValue(value) {
  return Number.isFinite(value) && value >= 0 ? Number(value) : null;
}
