// Where the web planner sends routing and place-search requests (#917).
//
// The relay advertises the self-hosted services in its compatibility
// document's `serviceUrls`. The planner reads that once per page load and
// otherwise uses the public services it always has. The app resolves the
// same document the same way, so both surfaces move together. See
// docs/routing-service.md.

export const PUBLIC_ROUTING_SERVICES = Object.freeze({
  valhallaBaseUrl: "https://valhalla1.openstreetmap.de",
  osrmBaseUrl: "https://router.project-osrm.org",
  geocoder: Object.freeze({
    api: "nominatim",
    baseUrl: "https://nominatim.openstreetmap.org",
  }),
});

const COMPATIBILITY_TIMEOUT_MS = 3_000;
const SEARCH_LIMIT = "5";

// A base every browser may be pointed at: https with a host, and no
// credentials, query or fragment. A trailing slash is dropped so derived paths
// come out the same either way. Anything else is refused.
export function safeServiceBaseUrl(raw) {
  if (typeof raw !== "string") return null;
  let url;
  try {
    url = new URL(raw.trim());
  } catch {
    return null;
  }
  if (
    url.protocol !== "https:" ||
    !url.hostname ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    return null;
  }
  const path = url.pathname.replace(/\/+$/, "");
  return `${url.origin}${path}`;
}

// Each service is resolved on its own. Photon is preferred when both
// geocoders are offered, because it is the self-hosted one.
export function resolveRoutingServices(compatibilityDocument) {
  const advertised =
    compatibilityDocument &&
    typeof compatibilityDocument.serviceUrls === "object" &&
    compatibilityDocument.serviceUrls !== null
      ? compatibilityDocument.serviceUrls
      : {};
  const valhalla = safeServiceBaseUrl(advertised.valhalla);
  const osrm = safeServiceBaseUrl(advertised.osrm);
  const photon = safeServiceBaseUrl(advertised.photon);
  const nominatim = safeServiceBaseUrl(advertised.nominatim);
  const geocoder = photon
    ? { api: "photon", baseUrl: photon }
    : nominatim
      ? { api: "nominatim", baseUrl: nominatim }
      : PUBLIC_ROUTING_SERVICES.geocoder;
  const valhallaBaseUrl = valhalla ?? PUBLIC_ROUTING_SERVICES.valhallaBaseUrl;
  return {
    valhallaRouteUrl: `${valhallaBaseUrl}/route`,
    osrmBaseUrl: osrm ?? PUBLIC_ROUTING_SERVICES.osrmBaseUrl,
    geocoder,
  };
}

// Reads the relay's compatibility document. Any failure, including a slow
// relay, leaves the planner on the public services rather than stalling it.
export async function loadRoutingServices({
  relayApiUrl,
  fetchImpl = globalThis.fetch,
  timeoutMs = COMPATIBILITY_TIMEOUT_MS,
} = {}) {
  if (!relayApiUrl) return resolveRoutingServices(null);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(`${relayApiUrl}/api/v1/compatibility`, {
      headers: { Accept: "application/json" },
      signal: controller.signal,
    });
    if (!response.ok) return resolveRoutingServices(null);
    return resolveRoutingServices(await response.json());
  } catch {
    return resolveRoutingServices(null);
  } finally {
    clearTimeout(timer);
  }
}

// The request for a place search, in the resolved geocoder's own dialect.
export function placeSearchUrl(geocoder, query, { limit = SEARCH_LIMIT, language } = {}) {
  if (geocoder.api === "photon") {
    const url = new URL(`${geocoder.baseUrl}/api`);
    url.searchParams.set("q", query);
    url.searchParams.set("limit", String(limit));
    return url;
  }
  const url = new URL(`${geocoder.baseUrl}/search`);
  url.searchParams.set("q", query);
  url.searchParams.set("format", "jsonv2");
  url.searchParams.set("limit", String(limit));
  url.searchParams.set("addressdetails", "0");
  url.searchParams.set("email", "privacy@tailendcharlie.app");
  if (language) url.searchParams.set("accept-language", language);
  return url;
}

// Search results as the planner shows them: a name, an address line and a
// position. Unusable entries are dropped rather than shown at 0,0.
export function placeSearchResults(geocoder, data) {
  if (geocoder.api === "photon") {
    const features = Array.isArray(data?.features) ? data.features : [];
    return features
      .map((feature) => {
        const [longitude, latitude] = Array.isArray(feature?.geometry?.coordinates)
          ? feature.geometry.coordinates
          : [];
        const properties = feature?.properties ?? {};
        const address = photonAddress(properties);
        return {
          latitude: Number(latitude),
          longitude: Number(longitude),
          name: String(properties.name || address.split(",")[0] || "Search result"),
          address,
        };
      })
      .filter((result) => validPosition(result));
  }
  return (Array.isArray(data) ? data : [])
    .map((result) => ({
      latitude: Number(result?.lat),
      longitude: Number(result?.lon),
      name: String(result?.name || result?.display_name?.split(",")[0] || "Search result"),
      address: String(result?.display_name || ""),
    }))
    .filter((result) => validPosition(result));
}

// The same one-line label the app builds for Photon results.
export function photonAddress(properties) {
  const text = (key) =>
    typeof properties[key] === "string" && properties[key].trim()
      ? properties[key].trim()
      : null;
  const street = text("street");
  const number = text("housenumber");
  const parts = [
    text("name"),
    street ? (number ? `${number} ${street}` : street) : null,
    text("district"),
    text("city") ?? text("locality"),
    text("county"),
    text("postcode"),
    text("country"),
  ].filter(Boolean);
  const seen = new Set();
  return parts
    .filter((part) => {
      const key = part.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .join(", ");
}

function validPosition({ latitude, longitude }) {
  return (
    Number.isFinite(latitude) &&
    Number.isFinite(longitude) &&
    Math.abs(latitude) <= 90 &&
    Math.abs(longitude) <= 180
  );
}
