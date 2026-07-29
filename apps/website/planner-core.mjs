const XML_ENTITIES = Object.freeze({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&apos;",
});

export function escapeXml(value) {
  return String(value).replace(/[&<>"']/g, (character) => XML_ENTITIES[character]);
}

export function gpxFileName(rideName) {
  const slug = String(rideName)
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `${slug || "tail-end-charlie-route"}.gpx`;
}

export function formatDistance(metres) {
  if (!Number.isFinite(metres) || metres < 0) return "—";
  const miles = metres / 1609.344;
  return `${miles < 10 ? miles.toFixed(1) : Math.round(miles)} mi`;
}

export function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const totalMinutes = Math.round(seconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours === 0) return `${minutes} min`;
  return minutes === 0 ? `${hours} hr` : `${hours} hr ${minutes} min`;
}

export function formatRouteBendScore(score) {
  if (!Number.isFinite(score) || score < 0) return "—";
  const rounded = Math.round(score);
  const label =
    score >= 45
      ? "Very twisty"
      : score >= 25
        ? "Twisty"
        : score >= 12
          ? "Flowing"
          : "Gentle";
  return `${rounded}°/km · ${label}`;
}

export function chooseRoadRoute(routes, preference = "quickest") {
  if (!Array.isArray(routes) || routes.length === 0) return null;
  if (preference === "quickest" || routes.length === 1) return routes[0];

  const quickestDuration = Number(routes[0]?.duration);
  const maximumDetour = routeDetourLimit(preference);
  const eligible = routes.filter((route) => {
    const duration = Number(route?.duration);
    return (
      Number.isFinite(duration) &&
      (!Number.isFinite(quickestDuration) ||
        duration <= quickestDuration * maximumDetour)
    );
  });
  if (eligible.length === 0) return routes[0];

  return eligible.reduce((best, candidate) =>
    routeBendScore(candidate) > routeBendScore(best) ? candidate : best,
  );
}

export function routeDetourLimit(preference) {
  return {
    balanced: 1.25,
    twisty: 1.5,
    "very-twisty": 1.75,
  }[preference] || 1;
}

export function routeBendScore(route) {
  const coordinates = route?.geometry?.coordinates;
  const distanceMetres = Number(route?.distance);
  if (!Array.isArray(coordinates) || coordinates.length < 3 || distanceMetres <= 0) {
    return 0;
  }

  const sampled = [coordinates[0]];
  let distanceSinceSample = 0;
  for (let index = 1; index < coordinates.length; index += 1) {
    distanceSinceSample += coordinateDistance(coordinates[index - 1], coordinates[index]);
    if (distanceSinceSample >= 150 || index === coordinates.length - 1) {
      sampled.push(coordinates[index]);
      distanceSinceSample = 0;
    }
  }

  let totalHeadingChange = 0;
  for (let index = 2; index < sampled.length; index += 1) {
    const before = bearing(sampled[index - 2], sampled[index - 1]);
    const after = bearing(sampled[index - 1], sampled[index]);
    const change = Math.abs((((after - before) % 360) + 540) % 360 - 180);
    // Reward road curvature, not route manoeuvres. Tiny changes are usually
    // geometry noise; sharper changes are more likely to be a U-turn,
    // roundabout exit or urban-grid junction than a useful flowing bend.
    if (change >= 8 && change <= 70) totalHeadingChange += change;
  }
  return totalHeadingChange / Math.max(distanceMetres / 1000, 1);
}

export function routeSelfCrossingArrows(
  coordinates,
  { offsetMetres = 30, maxArrows = 200, cellDegrees = 0.001 } = {},
) {
  if (!Array.isArray(coordinates) || coordinates.length < 4) return [];
  const detectionCoordinates = sampleRouteCoordinates(coordinates, 12_000);
  const segments = [];
  const grid = new Map();
  const arrows = [];

  for (let index = 1; index < detectionCoordinates.length; index += 1) {
    const start = detectionCoordinates[index - 1];
    const end = detectionCoordinates[index];
    if (!validCoordinatePair(start) || !validCoordinatePair(end)) continue;
    const segment = { index: index - 1, start, end };
    const cells = segmentGridCells(segment, cellDegrees);
    const candidates = new Set(
      cells.flatMap((cell) => grid.get(cell) || []),
    );

    for (const candidateIndex of candidates) {
      const candidate = segments[candidateIndex];
      if (!candidate || Math.abs(candidate.index - segment.index) <= 1) continue;
      const crossing = segmentIntersection(candidate, segment);
      if (!crossing) continue;
      arrows.push(
        arrowBeforeCrossing(candidate, crossing.firstFraction, offsetMetres),
        arrowBeforeCrossing(segment, crossing.secondFraction, offsetMetres),
      );
      if (arrows.length >= maxArrows) return arrows.slice(0, maxArrows);
    }

    const storedIndex = segments.push(segment) - 1;
    for (const cell of cells) {
      const bucket = grid.get(cell) || [];
      bucket.push(storedIndex);
      grid.set(cell, bucket);
    }
  }
  return arrows;
}

/// Turns an OSRM route response into the same manoeuvre shape the mobile
/// marker planner consumes.
export function routeManeuvers(route) {
  return (Array.isArray(route?.legs) ? route.legs : []).flatMap((leg) =>
    (Array.isArray(leg?.steps) ? leg.steps : []).flatMap((step) => {
      const maneuver = step?.maneuver;
      const location = maneuver?.location;
      if (
        !Array.isArray(location) ||
        location.length < 2 ||
        !validCoordinatePair(location) ||
        typeof maneuver?.type !== "string"
      ) {
        return [];
      }
      return [
        {
          position: [Number(location[0]), Number(location[1])],
          type: maneuver.type,
          modifier:
            typeof maneuver.modifier === "string" ? maneuver.modifier : null,
          name: typeof step?.name === "string" ? step.name : null,
          ref: typeof step?.ref === "string" ? step.ref : null,
          exitNumber: Number.isInteger(maneuver.exit) ? maneuver.exit : null,
          drivingSide:
            typeof step?.driving_side === "string" ? step.driving_side : null,
          bearingBefore: finiteNumber(maneuver.bearing_before),
          bearingAfter: finiteNumber(maneuver.bearing_after),
          lanes:
            (Array.isArray(step?.intersections) ? step.intersections : []).find(
              (intersection) =>
                Array.isArray(intersection?.lanes) &&
                intersection.lanes.length > 0,
            )?.lanes || [],
        },
      ];
    }),
  );
}

/// Builds the reviewable yellow-dot plan shared by the web planner and app.
///
/// A dot is advisory: live-lane and multi-lane positions are deliberately
/// classified as safety reviews, never as instructions to stop.
export function buildRouteMarkerPlan({
  routeCoordinates = [],
  maneuvers = [],
  stops = [],
  review = {},
} = {}) {
  const rejectedReview = Array.isArray(review?.rejected) ? review.rejected : [];
  const addedReview = Array.isArray(review?.added) ? review.added : [];
  const points = [];
  const rejectedPoints = [];

  const isRejected = (point) =>
    rejectedReview.some(
      (rejected) =>
        rejected?.id === point.id ||
        (validReviewPoint(rejected) &&
          coordinateDistance(reviewCoordinate(rejected), point.position) <= 30),
    );
  const collect = (point) =>
    (isRejected(point) ? rejectedPoints : points).push(point);

  maneuvers.forEach((maneuver, index) => {
    if (
      !validCoordinatePair(maneuver?.position) ||
      distanceToPolyline(maneuver.position, routeCoordinates) > 30
    ) {
      return;
    }
    const type = String(maneuver.type || "").trim().toLowerCase();
    const modifier = String(maneuver.modifier || "").trim().toLowerCase();
    const id = `maneuver-${index}`;
    const circular = type === "roundabout" || type === "rotary";
    const turn = maneuverTurnDegrees(maneuver, routeCoordinates);

    if (["merge", "on ramp", "off ramp"].includes(type)) {
      collect({
        id,
        position: maneuver.position,
        kind: "safety-review",
        source: "detected",
        label: safetyLabel(type),
        detail:
          "Do not stop on a live carriageway or slip road. Choose a legal regrouping or marker position elsewhere.",
      });
      return;
    }
    if (!circular && (modifier === "uturn" || (turn != null && turn >= 150))) {
      return;
    }
    if (circular) {
      const laneCount = Array.isArray(maneuver.lanes)
        ? maneuver.lanes.length
        : 0;
      const safetyReview = laneCount >= 3;
      collect({
        id,
        position: maneuver.position,
        kind: safetyReview ? "safety-review" : "likely-marker",
        source: "detected",
        label:
          maneuver.exitNumber == null
            ? "Roundabout exit marker"
            : `Roundabout exit ${maneuver.exitNumber} marker`,
        detail: safetyReview
          ? "Large multi-lane roundabout: inspect a safe, legal position after the required exit."
          : "Default rule: mark the required exit only.",
      });
      return;
    }
    const decisionType = ["turn", "fork", "end of road"].includes(type);
    const straight = !modifier || modifier === "straight";
    if (
      !decisionType ||
      straight ||
      (type !== "fork" && turn != null && turn < 20)
    ) {
      return;
    }
    collect({
      id,
      position: maneuver.position,
      kind: "likely-marker",
      source: "detected",
      label: decisionLabel(type, modifier),
    });
  });

  stops.forEach((stop, index) => {
    const searchable = `${stop?.name || ""} ${stop?.description || ""} ${stop?.symbol || ""}`.toLowerCase();
    if (!/(muster|regroup|re-group)/.test(searchable)) return;
    const position = [Number(stop.longitude), Number(stop.latitude)];
    if (!validCoordinatePair(position)) return;
    collect({
      id: `muster-${index}`,
      position,
      kind: "muster-point",
      source: "detected",
      label: String(stop.name || "").trim() || "Muster point",
      detail: "Planned regrouping point; not a ride stop or marker role.",
    });
  });

  for (const added of addedReview) {
    if (!validReviewPoint(added)) continue;
    points.push({
      id: String(added.id),
      position: reviewCoordinate(added),
      kind: "likely-marker",
      source: "manual",
      label: String(added.label || "").trim() || "Added marker position",
      detail: "Added during review because the detector missed it.",
    });
  }

  const claimed = [...points, ...rejectedPoints].map((point) => point.position);
  const candidates = [];
  const offerCandidate = (candidate) => {
    if (
      claimed.some(
        (position) => coordinateDistance(position, candidate.position) <= 30,
      ) ||
      candidates.some(
        (existing) =>
          coordinateDistance(existing.position, candidate.position) <= 30,
      )
    ) {
      return;
    }
    claimed.push(candidate.position);
    candidates.push(candidate);
  };
  maneuvers.forEach((maneuver, index) => {
    const type = String(maneuver?.type || "").trim().toLowerCase();
    const modifier = String(maneuver?.modifier || "").trim().toLowerCase();
    if (
      ["depart", "arrive"].includes(type) ||
      !validCoordinatePair(maneuver?.position) ||
      distanceToPolyline(maneuver.position, routeCoordinates) > 30
    ) {
      return;
    }
    const baseLabel = candidateLabel(type, modifier);
    offerCandidate({
      id: `maneuver-${index}`,
      position: maneuver.position,
      label: String(maneuver.name || "").trim()
        ? `${baseLabel} · ${maneuver.name.trim()}`
        : baseLabel,
    });
  });
  for (
    let index = 1;
    index < routeCoordinates.length - 1 && candidates.length < 500;
    index += 1
  ) {
    const turn = routeTurnDegrees(routeCoordinates, index);
    if (turn < 20 || turn >= 150) continue;
    offerCandidate({
      id: `geometry-${index}`,
      position: routeCoordinates[index],
      label: `${Math.round(turn)}° bend in the route`,
    });
  }

  return { points, rejectedPoints, candidates };
}

function safetyLabel(type) {
  if (type === "off ramp") return "Motorway or dual-carriageway exit review";
  if (type === "on ramp") return "Motorway or dual-carriageway entry review";
  return "Live-lane merge review";
}

function decisionLabel(type, modifier) {
  if (type === "fork") return modifier ? `Keep ${modifier} marker` : "Fork marker";
  if (type === "end of road") {
    return modifier
      ? `End of road, turn ${modifier} marker`
      : "End-of-road marker";
  }
  return modifier ? `Turn ${modifier} marker` : "Junction marker";
}

function candidateLabel(type, modifier) {
  const where =
    {
      roundabout: "Roundabout",
      rotary: "Roundabout",
      merge: "Merge",
      "on ramp": "Slip road on",
      "off ramp": "Slip road off",
      "end of road": "End of road",
      fork: "Fork",
      "new name": "Road name change",
      continue: "Continue",
      turn: "Turn",
    }[type] ||
    (type ? `${type[0].toUpperCase()}${type.slice(1)}` : "Junction");
  return modifier ? `${where}, ${modifier}` : where;
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function reviewCoordinate(point) {
  return [Number(point.longitude), Number(point.latitude)];
}

function validReviewPoint(point) {
  return (
    typeof point?.id === "string" &&
    point.id.length > 0 &&
    validCoordinatePair(reviewCoordinate(point))
  );
}

function maneuverTurnDegrees(maneuver, routeCoordinates) {
  if (
    Number.isFinite(maneuver?.bearingBefore) &&
    Number.isFinite(maneuver?.bearingAfter)
  ) {
    return smallestAngle(maneuver.bearingBefore, maneuver.bearingAfter);
  }
  if (routeCoordinates.length < 3) return null;
  let nearestIndex = -1;
  let nearestDistance = Infinity;
  routeCoordinates.forEach((coordinate, index) => {
    const distance = coordinateDistance(coordinate, maneuver.position);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestIndex = index;
    }
  });
  return nearestIndex <= 0 || nearestIndex >= routeCoordinates.length - 1
    ? null
    : routeTurnDegrees(routeCoordinates, nearestIndex);
}

function routeTurnDegrees(routeCoordinates, index) {
  const vertex = routeCoordinates[index];
  let inboundIndex = index - 1;
  while (
    inboundIndex > 0 &&
    coordinateDistance(routeCoordinates[inboundIndex], vertex) < 30
  ) {
    inboundIndex -= 1;
  }
  let outboundIndex = index + 1;
  while (
    outboundIndex < routeCoordinates.length - 1 &&
    coordinateDistance(routeCoordinates[outboundIndex], vertex) < 30
  ) {
    outboundIndex += 1;
  }
  return smallestAngle(
    bearing(routeCoordinates[inboundIndex], vertex),
    bearing(vertex, routeCoordinates[outboundIndex]),
  );
}

function smallestAngle(first, second) {
  return Math.abs((((second - first) % 360) + 540) % 360 - 180);
}

function distanceToPolyline(point, polyline) {
  if (!Array.isArray(polyline) || polyline.length === 0) return Infinity;
  if (polyline.length === 1) return coordinateDistance(point, polyline[0]);
  let nearest = Infinity;
  for (let index = 1; index < polyline.length; index += 1) {
    nearest = Math.min(
      nearest,
      distanceToSegment(point, polyline[index - 1], polyline[index]),
    );
  }
  return nearest;
}

function distanceToSegment(point, start, end) {
  const referenceLatitude = (point[1] * Math.PI) / 180;
  const metresPerDegreeLatitude = 111195;
  const metresPerDegreeLongitude =
    metresPerDegreeLatitude * Math.cos(referenceLatitude);
  const startX = normaliseLongitude(start[0] - point[0]) * metresPerDegreeLongitude;
  const startY = (start[1] - point[1]) * metresPerDegreeLatitude;
  const endX = normaliseLongitude(end[0] - point[0]) * metresPerDegreeLongitude;
  const endY = (end[1] - point[1]) * metresPerDegreeLatitude;
  const deltaX = endX - startX;
  const deltaY = endY - startY;
  const lengthSquared = deltaX * deltaX + deltaY * deltaY;
  if (lengthSquared === 0) return Math.hypot(startX, startY);
  const projection = Math.max(
    0,
    Math.min(1, -(startX * deltaX + startY * deltaY) / lengthSquared),
  );
  return Math.hypot(
    startX + projection * deltaX,
    startY + projection * deltaY,
  );
}

function normaliseLongitude(value) {
  return ((value + 540) % 360) - 180;
}

function sampleRouteCoordinates(coordinates, maximumPoints) {
  if (coordinates.length <= maximumPoints) return coordinates;
  const sampled = [];
  const lastIndex = coordinates.length - 1;
  for (let index = 0; index < maximumPoints; index += 1) {
    sampled.push(coordinates[Math.round((index * lastIndex) / (maximumPoints - 1))]);
  }
  return sampled;
}

export function decodePolyline(encoded, precision = 6) {
  if (typeof encoded !== "string" || encoded.length === 0) return [];
  const coordinates = [];
  const factor = 10 ** precision;
  let index = 0;
  let latitude = 0;
  let longitude = 0;

  while (index < encoded.length) {
    const latitudeResult = decodePolylineValue(encoded, index);
    index = latitudeResult.index;
    latitude += latitudeResult.value;
    const longitudeResult = decodePolylineValue(encoded, index);
    index = longitudeResult.index;
    longitude += longitudeResult.value;
    coordinates.push([longitude / factor, latitude / factor]);
  }
  return coordinates;
}

export function motorcycleCostingOptions({
  routeStyle = "quickest",
  avoidMajorRoads = false,
  avoidMotorways = false,
  avoidTolls = false,
  avoidFerries = false,
  avoidUnsurfacedByways = true,
} = {}) {
  const curveHighwayPreference = {
    balanced: 0.6,
    twisty: 0.35,
    "very-twisty": 0.15,
  }[routeStyle];
  return {
    use_highways: avoidMajorRoads ? 0.08 : curveHighwayPreference ?? 1,
    use_tolls: avoidTolls ? 0 : 0.5,
    use_ferry: avoidFerries ? 0 : 0.5,
    // A byway open to all traffic is a legal designation, not a surface, so the
    // preference is expressed against the surface and track tagging
    // OpenStreetMap actually carries rather than guessed from road class.
    // `use_trails` covers ways mapped as tracks; `exclude_unpaved` covers
    // `surface=*`. See docs/route-twistiness.md for the default and its
    // reasoning; apps/mobile/lib/domain/route_preferences.dart is the same
    // contract in Dart.
    use_trails: avoidUnsurfacedByways ? 0 : 0.5,
    exclude_highways: Boolean(avoidMotorways),
    exclude_tolls: Boolean(avoidTolls),
    exclude_ferries: Boolean(avoidFerries),
    exclude_unpaved: Boolean(avoidUnsurfacedByways),
  };
}

/// Whether a set of preferences needs the Valhalla motorcycle service rather
/// than the OSRM driving profile.
///
/// The four avoidances are hard exclusions OSRM cannot express. Allowing
/// unsurfaced byways is on the list for the opposite reason: OSRM's standard car
/// profile does not route `highway=track` at all, so *seeking* byways is the case
/// it cannot serve, while avoiding them is the case it already serves.
export function requiresMotorcycleCosting({
  avoidMotorways = false,
  avoidMajorRoads = false,
  avoidTolls = false,
  avoidFerries = false,
  avoidUnsurfacedByways = true,
} = {}) {
  return Boolean(
    avoidMotorways ||
      avoidMajorRoads ||
      avoidTolls ||
      avoidFerries ||
      !avoidUnsurfacedByways,
  );
}

export class StateHistory {
  constructor(limit = 50) {
    this.limit = limit;
    this.past = [];
    this.future = [];
  }

  get canUndo() {
    return this.past.length > 0;
  }

  get canRedo() {
    return this.future.length > 0;
  }

  push(state) {
    const snapshot = cloneState(state);
    if (statesMatch(this.past.at(-1), snapshot)) return;
    this.past.push(snapshot);
    if (this.past.length > this.limit) this.past.shift();
    this.future = [];
  }

  undo(currentState) {
    if (!this.canUndo) return null;
    this.future.push(cloneState(currentState));
    return cloneState(this.past.pop());
  }

  redo(currentState) {
    if (!this.canRedo) return null;
    this.past.push(cloneState(currentState));
    return cloneState(this.future.pop());
  }
}

/// The metadata extension that carries route preferences into the mobile app.
///
/// Preferences belong to the route, not the browser, so the shared file states
/// what the route was planned for. `GpxParser` reads exactly these attribute
/// names back into `RoutePreferences`.
export function routePreferencesGpxExtension(preferences) {
  if (!preferences) return "";
  return `    <extensions>${routePreferencesGpxElement(preferences)}</extensions>`;
}

function routePreferencesGpxElement(preferences) {
  const avoidUnsurfacedByways = preferences.avoidUnsurfacedByways !== false;
  const attributes = [
    ["style", String(preferences.routeStyle || "quickest")],
    ["avoid-motorways", String(Boolean(preferences.avoidMotorways))],
    ["avoid-major-roads", String(Boolean(preferences.avoidMajorRoads))],
    ["avoid-tolls", String(Boolean(preferences.avoidTolls))],
    ["avoid-ferries", String(Boolean(preferences.avoidFerries))],
    [
      "byway-surface",
      avoidUnsurfacedByways ? "avoid-unsurfaced" : "allow-unsurfaced",
    ],
  ]
    .map(([name, value]) => `${name}="${escapeXml(value)}"`)
    .join(" ");
  return `<tec:route-preferences ${attributes} />`;
}

export function markerReviewGpxElement(review) {
  const entries = [
    ["rejected", Array.isArray(review?.rejected) ? review.rejected : []],
    ["added", Array.isArray(review?.added) ? review.added : []],
  ].flatMap(([kind, points]) =>
    points.flatMap((point) => {
      if (!validReviewPoint(point)) return [];
      const label = String(point.label || "").trim();
      const attributes = [
        `id="${escapeXml(point.id)}"`,
        `lat="${formatCoordinate(Number(point.latitude))}"`,
        `lon="${formatCoordinate(Number(point.longitude))}"`,
        ...(label ? [`label="${escapeXml(label)}"`] : []),
      ].join(" ");
      return [`<tec:${kind} ${attributes} />`];
    }),
  );
  return entries.length
    ? `<tec:marker-review>${entries.join("")}</tec:marker-review>`
    : "";
}

export function buildGpx({
  rideName,
  stops,
  routeCoordinates,
  createdAt,
  preferences = null,
  markerReview = null,
}) {
  const safeName = String(rideName).trim();
  if (!safeName) throw new Error("Name the ride before downloading it.");
  if (!Array.isArray(stops) || stops.length < 2) {
    throw new Error("Add at least two stops before downloading the GPX file.");
  }
  if (!Array.isArray(routeCoordinates) || routeCoordinates.length < 2) {
    throw new Error("Generate a road route before downloading the GPX file.");
  }

  const timestamp = (createdAt instanceof Date ? createdAt : new Date(createdAt))
    .toISOString();
  const waypoints = stops
    .map((stop, index) => {
      validateCoordinate(stop.longitude, stop.latitude);
      const name = String(stop.name).trim() || `Stop ${index + 1}`;
      return [
        `  <wpt lat="${formatCoordinate(stop.latitude)}" lon="${formatCoordinate(stop.longitude)}">`,
        `    <name>${escapeXml(name)}</name>`,
        "    <sym>Flag</sym>",
        "  </wpt>",
      ].join("\n");
    })
    .join("\n");
  const trackPoints = routeCoordinates
    .map(([longitude, latitude]) => {
      validateCoordinate(longitude, latitude);
      return `      <trkpt lat="${formatCoordinate(latitude)}" lon="${formatCoordinate(longitude)}" />`;
    })
    .join("\n");

  const metadataExtensionElements = [
    preferences ? routePreferencesGpxElement(preferences) : "",
    markerReviewGpxElement(markerReview),
  ].filter(Boolean);
  const metadataExtensions = metadataExtensionElements.length
    ? `    <extensions>${metadataExtensionElements.join("")}</extensions>`
    : "";
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<gpx version="1.1" creator="Tail End Charlie" xmlns="http://www.topografix.com/GPX/1/1" xmlns:tec="https://tailendcharlie.app/gpx/1">',
    "  <metadata>",
    `    <name>${escapeXml(safeName)}</name>`,
    "    <desc>Road-following group ride planned at tailendcharlie.app.</desc>",
    `    <time>${timestamp}</time>`,
    ...(metadataExtensions ? [metadataExtensions] : []),
    "  </metadata>",
    waypoints,
    "  <trk>",
    `    <name>${escapeXml(safeName)}</name>`,
    "    <extensions><tec:road-route>true</tec:road-route></extensions>",
    "    <trkseg>",
    trackPoints,
    "    </trkseg>",
    "  </trk>",
    "</gpx>",
    "",
  ].join("\n");
}

function validateCoordinate(longitude, latitude) {
  if (
    !Number.isFinite(longitude) ||
    !Number.isFinite(latitude) ||
    longitude < -180 ||
    longitude > 180 ||
    latitude < -90 ||
    latitude > 90
  ) {
    throw new Error("The route contains an invalid coordinate.");
  }
}

function validCoordinatePair(coordinate) {
  return (
    Array.isArray(coordinate) &&
    Number.isFinite(coordinate[0]) &&
    Number.isFinite(coordinate[1]) &&
    coordinate[0] >= -180 &&
    coordinate[0] <= 180 &&
    coordinate[1] >= -90 &&
    coordinate[1] <= 90
  );
}

function formatCoordinate(value) {
  return Number(value).toFixed(7);
}

function coordinateDistance(first, second) {
  if (!Array.isArray(first) || !Array.isArray(second)) return 0;
  const radians = Math.PI / 180;
  const latitude1 = Number(first[1]) * radians;
  const latitude2 = Number(second[1]) * radians;
  const latitudeDelta = latitude2 - latitude1;
  const longitudeDelta = (Number(second[0]) - Number(first[0])) * radians;
  const haversine =
    Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(latitude1) * Math.cos(latitude2) * Math.sin(longitudeDelta / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine));
}

function segmentGridCells(segment, cellDegrees) {
  const minimumLongitude = Math.floor(
    Math.min(segment.start[0], segment.end[0]) / cellDegrees,
  );
  const maximumLongitude = Math.floor(
    Math.max(segment.start[0], segment.end[0]) / cellDegrees,
  );
  const minimumLatitude = Math.floor(
    Math.min(segment.start[1], segment.end[1]) / cellDegrees,
  );
  const maximumLatitude = Math.floor(
    Math.max(segment.start[1], segment.end[1]) / cellDegrees,
  );
  const cells = [];
  for (let longitude = minimumLongitude; longitude <= maximumLongitude; longitude += 1) {
    for (let latitude = minimumLatitude; latitude <= maximumLatitude; latitude += 1) {
      cells.push(`${longitude}:${latitude}`);
      if (cells.length >= 100) return cells;
    }
  }
  return cells;
}

function segmentIntersection(first, second) {
  const [px, py] = first.start;
  const [qx, qy] = second.start;
  const rx = first.end[0] - px;
  const ry = first.end[1] - py;
  const sx = second.end[0] - qx;
  const sy = second.end[1] - qy;
  const denominator = rx * sy - ry * sx;
  if (Math.abs(denominator) < 1e-12) return null;
  const qpx = qx - px;
  const qpy = qy - py;
  const firstFraction = (qpx * sy - qpy * sx) / denominator;
  const secondFraction = (qpx * ry - qpy * rx) / denominator;
  const endpointMargin = 0.015;
  if (
    firstFraction <= endpointMargin ||
    firstFraction >= 1 - endpointMargin ||
    secondFraction <= endpointMargin ||
    secondFraction >= 1 - endpointMargin
  ) {
    return null;
  }
  return { firstFraction, secondFraction };
}

function arrowBeforeCrossing(segment, fraction, offsetMetres) {
  const segmentMetres = coordinateDistance(segment.start, segment.end);
  const fractionOffset = segmentMetres > 0
    ? Math.min(0.35, offsetMetres / segmentMetres)
    : 0.1;
  const position = Math.max(0.04, fraction - fractionOffset);
  return {
    coordinate: [
      segment.start[0] + (segment.end[0] - segment.start[0]) * position,
      segment.start[1] + (segment.end[1] - segment.start[1]) * position,
    ],
    bearing: bearing(segment.start, segment.end),
  };
}

function bearing(first, second) {
  const radians = Math.PI / 180;
  const latitude1 = Number(first[1]) * radians;
  const latitude2 = Number(second[1]) * radians;
  const longitudeDelta = (Number(second[0]) - Number(first[0])) * radians;
  const y = Math.sin(longitudeDelta) * Math.cos(latitude2);
  const x =
    Math.cos(latitude1) * Math.sin(latitude2) -
    Math.sin(latitude1) * Math.cos(latitude2) * Math.cos(longitudeDelta);
  return (Math.atan2(y, x) / radians + 360) % 360;
}

function decodePolylineValue(encoded, startIndex) {
  let result = 0;
  let shift = 0;
  let index = startIndex;
  let byte;
  do {
    if (index >= encoded.length) {
      throw new Error("The routing service returned an invalid route shape.");
    }
    byte = encoded.charCodeAt(index) - 63;
    index += 1;
    result |= (byte & 0x1f) << shift;
    shift += 5;
  } while (byte >= 0x20);
  return {
    index,
    value: result & 1 ? ~(result >> 1) : result >> 1,
  };
}

function cloneState(state) {
  return JSON.parse(JSON.stringify(state));
}

function statesMatch(first, second) {
  return first != null && JSON.stringify(first) === JSON.stringify(second);
}
