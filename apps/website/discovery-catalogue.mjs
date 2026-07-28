export const DISCOVERY_CATEGORIES = Object.freeze({
  twisty_highlight: Object.freeze({
    label: "Twisty highlights",
    colour: "#f97316",
    geometryType: "LineString",
  }),
  mountain_pass: Object.freeze({
    label: "Mountain passes",
    colour: "#0f9d8a",
    geometryType: "Point",
  }),
  good_biking_road: Object.freeze({
    label: "Good biking roads",
    colour: "#2583e9",
    geometryType: "LineString",
  }),
});

export const DISCOVERY_CATALOGUE_URL = "/data/discovery-catalogue.geojson";

/// Wording used wherever a fact could exist but OpenStreetMap does not carry it.
/// Never "none": the field describes the map, not the road.
export const NOT_RECORDED = "not recorded in OpenStreetMap";

/// Why "not recorded" must not be read as "not there".
///
/// One candidate in 2,245 matches an OpenStreetMap average-speed relation, while
/// the A57 Snake Pass has published camera proposals OpenStreetMap does not
/// hold. Getting this wrong tells a rider a road is clear when it is not.
export const ENFORCEMENT_RECORD_CAVEAT =
  "OpenStreetMap does not hold every camera, so this is not evidence that the road is unenforced.";

/// What a discovery road says about itself, in words a rider can trust.
///
/// The JavaScript half of `DiscoveryRoadFacts` in
/// `apps/mobile/lib/services/discovery_road_facts.dart`. Both are pinned to the
/// same strings by tests so the website and the app cannot phrase the same fact
/// two different ways (#160).
///
/// There is deliberately no "police checks likely" field. It is not in
/// OpenStreetMap, must not be synthesised from road class, and the only credible
/// source is accumulated rider reports (#112, #135).
export function discoveryRoadFacts(properties = {}) {
  const limit = properties.speedLimit;
  const limitValue = trimmedOrNull(limit?.value);
  const provenance = limit ? limit.provenance : undefined;
  const speedLimitIsKnown = Boolean(
    limitValue && provenance !== "unknown" && provenance !== undefined,
  );
  const check = properties.averageSpeedCheck;
  const cameras = Number.isInteger(properties.fixedSpeedCameras)
    ? properties.fixedSpeedCameras
    : null;
  const isVerified = properties.researchStatus === "researched";

  const enforcement = check?.present
    ? trimmedOrNull(check.description) ||
      `Average speed check: recorded in OpenStreetMap${
        trimmedOrNull(check.enforcedLimit)
          ? ` at ${trimmedOrNull(check.enforcedLimit)}`
          : ""
      }.`
    : check
      ? `Average speed check: ${NOT_RECORDED} for this road.`
      : "Average speed check: not checked for this road.";
  const hasRecordedEnforcement =
    enforcement.includes("recorded in OpenStreetMap") &&
    !enforcement.includes(NOT_RECORDED);
  const enforcementCaveat = trimmedOrNull(properties.enforcementNote);

  return {
    speedLimit: speedLimitIsKnown
      ? limitWithRange(limit, limitValue)
      : "Speed limit not known",
    speedLimitIsKnown,
    speedLimitProvenance:
      provenance === "tagged"
        ? "Recorded in OpenStreetMap for this road."
        : provenance === "inferred-from-maxspeed-type"
          ? "Implied by a national speed limit tag in OpenStreetMap, not a posted value for this road."
          : trimmedOrNull(limit?.note) ||
            `A speed limit for this road is ${NOT_RECORDED}.`,
    enforcement,
    hasRecordedEnforcement,
    fixedCameras:
      cameras === null
        ? "Fixed speed cameras: not checked for this road."
        : cameras === 0
          ? `Fixed speed cameras: ${NOT_RECORDED} near this road.`
          : `Fixed speed cameras: ${cameras} recorded in OpenStreetMap near this road.`,
    enforcementCaveat,
    busyPeriods:
      trimmedOrNull(properties.busyPeriods) ||
      "Busy periods have not been researched.",
    description: trimmedOrNull(properties.riderNote),
    researchLabel: isVerified ? "Researched" : "Not yet reviewed",
    researchDetail: isVerified
      ? "Checked against the cited sources below."
      : "Generated from OpenStreetMap and not yet checked by a person. Treat every field here with less confidence than a reviewed entry.",
    isVerified,
    evidenceSources: Array.isArray(properties.evidenceSources)
      ? properties.evidenceSources.map(trimmedOrNull).filter(Boolean)
      : [],
    get enforcementLines() {
      return [
        this.enforcement,
        this.fixedCameras,
        ...(this.enforcementCaveat ? [this.enforcementCaveat] : []),
        ...(this.hasRecordedEnforcement ? [] : [ENFORCEMENT_RECORD_CAVEAT]),
      ];
    },
  };
}

function limitWithRange(limit, value) {
  if (!limit?.mixed) return value;
  const range = (Array.isArray(limit.range) ? limit.range : [])
    .map(trimmedOrNull)
    .filter(Boolean);
  return range.length === 2
    ? `${value} · varies from ${range[0]} to ${range[1]}`
    : `${value} · varies along this road`;
}

function trimmedOrNull(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length ? trimmed : null;
}

export function filterDiscoveryFeatures(collection, bounds, categories) {
  const enabled = new Set(categories);
  if (!collection || collection.type !== "FeatureCollection") {
    return emptyFeatureCollection();
  }
  return {
    type: "FeatureCollection",
    features: collection.features.filter(
      (feature) =>
        enabled.has(feature?.properties?.category) &&
        featureIntersectsBounds(feature, bounds),
    ),
  };
}

export function discoveryFeatureAnchor(feature) {
  const coordinates = feature?.geometry?.coordinates;
  if (feature?.geometry?.type === "Point") return coordinates;
  if (feature?.geometry?.type !== "LineString" || !coordinates?.length) {
    return null;
  }
  return coordinates[Math.floor(coordinates.length / 2)];
}

export function discoveryRouteStop(feature) {
  const coordinate = discoveryFeatureAnchor(feature);
  if (!coordinate) return null;
  return {
    longitude: coordinate[0],
    latitude: coordinate[1],
    name:
      String(feature?.properties?.name || "").trim() ||
      DISCOVERY_CATEGORIES[feature?.properties?.category]?.label ||
      "Discovery highlight",
  };
}

export function nearbyDiscoveryFeatures(collection, coordinate, maximumKm = 5) {
  if (!Array.isArray(coordinate) || !collection?.features) return [];
  return collection.features
    .map((feature) => ({
      feature,
      distanceKm: haversineKm(coordinate, discoveryFeatureAnchor(feature)),
    }))
    .filter((entry) => entry.distanceKm <= maximumKm)
    .sort((a, b) => a.distanceKm - b.distanceKm);
}

export function emptyFeatureCollection() {
  return { type: "FeatureCollection", features: [] };
}

function featureIntersectsBounds(feature, bounds) {
  if (!bounds) return true;
  const coordinates =
    feature?.geometry?.type === "Point"
      ? [feature.geometry.coordinates]
      : feature?.geometry?.coordinates;
  if (!Array.isArray(coordinates)) return false;
  return coordinates.some(
    (coordinate) =>
      Array.isArray(coordinate) &&
      coordinate[0] >= bounds.west &&
      coordinate[0] <= bounds.east &&
      coordinate[1] >= bounds.south &&
      coordinate[1] <= bounds.north,
  );
}

function haversineKm(from, to) {
  if (!Array.isArray(to)) return Number.POSITIVE_INFINITY;
  const radians = (value) => (value * Math.PI) / 180;
  const latitudeDelta = radians(to[1] - from[1]);
  const longitudeDelta = radians(to[0] - from[0]);
  const startLatitude = radians(from[1]);
  const endLatitude = radians(to[1]);
  const haversine =
    Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(startLatitude) *
      Math.cos(endLatitude) *
      Math.sin(longitudeDelta / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine));
}
