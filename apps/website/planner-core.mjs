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

export function chooseRoadRoute(routes, preference = "quickest") {
  if (!Array.isArray(routes) || routes.length === 0) return null;
  if (preference !== "twisty" || routes.length === 1) return routes[0];

  const quickestDuration = Number(routes[0]?.duration);
  const eligible = routes.filter((route) => {
    const duration = Number(route?.duration);
    return (
      Number.isFinite(duration) &&
      (!Number.isFinite(quickestDuration) || duration <= quickestDuration * 1.5)
    );
  });
  if (eligible.length === 0) return routes[0];

  return eligible.reduce((best, candidate) =>
    routeBendScore(candidate) > routeBendScore(best) ? candidate : best,
  );
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
  return {
    use_highways: avoidMajorRoads ? 0.08 : routeStyle === "twisty" ? 0.35 : 1,
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
