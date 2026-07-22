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
    if (change >= 8) totalHeadingChange += Math.min(change, 120);
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
    exclude_highways: Boolean(avoidMotorways),
    exclude_tolls: Boolean(avoidTolls),
    exclude_ferries: Boolean(avoidFerries),
  };
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

export function buildGpx({ rideName, stops, routeCoordinates, createdAt }) {
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

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<gpx version="1.1" creator="Tail End Charlie" xmlns="http://www.topografix.com/GPX/1/1">',
    "  <metadata>",
    `    <name>${escapeXml(safeName)}</name>`,
    "    <desc>Road-following group ride planned at tailendcharlie.app.</desc>",
    `    <time>${timestamp}</time>`,
    "  </metadata>",
    waypoints,
    "  <trk>",
    `    <name>${escapeXml(safeName)}</name>`,
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
