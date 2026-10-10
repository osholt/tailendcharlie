import assert from "node:assert/strict";
import test from "node:test";

import {
  PUBLIC_ROUTING_SERVICES,
  loadRoutingServices,
  photonAddress,
  placeSearchResults,
  placeSearchUrl,
  resolveRoutingServices,
  safeServiceBaseUrl,
} from "./planner-services.mjs";

const selfHosted = {
  serviceUrls: {
    valhalla: "https://routing.example.test/valhalla/",
    photon: "https://routing.example.test/photon",
  },
};

test("with nothing advertised the planner keeps the public services", () => {
  for (const document of [null, {}, { serviceUrls: null }, { serviceUrls: "x" }]) {
    assert.deepEqual(resolveRoutingServices(document), {
      valhallaRouteUrl: "https://valhalla1.openstreetmap.de/route",
      osrmBaseUrl: "https://router.project-osrm.org",
      geocoder: PUBLIC_ROUTING_SERVICES.geocoder,
    });
  }
});

test("advertised services replace the public ones, each on its own", () => {
  assert.deepEqual(resolveRoutingServices(selfHosted), {
    valhallaRouteUrl: "https://routing.example.test/valhalla/route",
    osrmBaseUrl: "https://router.project-osrm.org",
    geocoder: { api: "photon", baseUrl: "https://routing.example.test/photon" },
  });
});

test("Photon is preferred, and Nominatim is used when it is all there is", () => {
  const both = resolveRoutingServices({
    serviceUrls: {
      nominatim: "https://geo.example.test/nominatim",
      photon: "https://geo.example.test/photon",
    },
  });
  assert.equal(both.geocoder.api, "photon");
  const nominatim = resolveRoutingServices({
    serviceUrls: { nominatim: "https://geo.example.test/nominatim" },
  });
  assert.deepEqual(nominatim.geocoder, {
    api: "nominatim",
    baseUrl: "https://geo.example.test/nominatim",
  });
});

test("only plain https bases are followed, each judged alone", () => {
  assert.equal(safeServiceBaseUrl("https://a.example.test/x/"), "https://a.example.test/x");
  assert.equal(safeServiceBaseUrl(" https://a.example.test "), "https://a.example.test");
  for (const refused of [
    "http://a.example.test",
    "https://user:secret@a.example.test",
    "https://user@a.example.test",
    "https://a.example.test/x?key=1",
    "https://a.example.test/x#frag",
    "not a url",
    7,
    null,
  ]) {
    assert.equal(safeServiceBaseUrl(refused), null, String(refused));
  }
  const mixed = resolveRoutingServices({
    serviceUrls: {
      valhalla: "http://routing.example.test/valhalla",
      osrm: "https://routing.example.test/osrm",
    },
  });
  assert.equal(mixed.valhallaRouteUrl, "https://valhalla1.openstreetmap.de/route");
  assert.equal(mixed.osrmBaseUrl, "https://routing.example.test/osrm");
});

test("the relay's compatibility document is read once, and failure falls back", async () => {
  const requested = [];
  const answered = await loadRoutingServices({
    relayApiUrl: "https://relay.example.test",
    fetchImpl: async (url, options) => {
      requested.push({ url, accept: options.headers.Accept });
      return { ok: true, json: async () => selfHosted };
    },
  });
  assert.deepEqual(requested, [
    { url: "https://relay.example.test/api/v1/compatibility", accept: "application/json" },
  ]);
  assert.equal(answered.geocoder.api, "photon");

  const unavailable = await loadRoutingServices({
    relayApiUrl: "https://relay.example.test",
    fetchImpl: async () => ({ ok: false, json: async () => selfHosted }),
  });
  assert.equal(unavailable.valhallaRouteUrl, "https://valhalla1.openstreetmap.de/route");

  const thrown = await loadRoutingServices({
    relayApiUrl: "https://relay.example.test",
    fetchImpl: async () => {
      throw new TypeError("offline");
    },
  });
  assert.equal(thrown.geocoder.api, "nominatim");

  const slow = await loadRoutingServices({
    relayApiUrl: "https://relay.example.test",
    timeoutMs: 10,
    fetchImpl: (url, { signal }) =>
      new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(new DOMException("late", "AbortError")));
      }),
  });
  assert.equal(slow.osrmBaseUrl, "https://router.project-osrm.org");

  const noRelay = await loadRoutingServices({
    relayApiUrl: undefined,
    fetchImpl: async () => assert.fail("no request expected"),
  });
  assert.equal(noRelay.geocoder.api, "nominatim");
});

test("place search speaks each geocoder's dialect", () => {
  const photon = placeSearchUrl(
    { api: "photon", baseUrl: "https://routing.example.test/photon" },
    "Bristol",
    { language: "en-GB" },
  );
  assert.equal(photon.origin + photon.pathname, "https://routing.example.test/photon/api");
  assert.deepEqual(Object.fromEntries(photon.searchParams), { q: "Bristol", limit: "5" });

  const nominatim = placeSearchUrl(PUBLIC_ROUTING_SERVICES.geocoder, "Bristol", {
    limit: 1,
    language: "en-GB",
  });
  assert.equal(
    nominatim.origin + nominatim.pathname,
    "https://nominatim.openstreetmap.org/search",
  );
  assert.deepEqual(Object.fromEntries(nominatim.searchParams), {
    q: "Bristol",
    format: "jsonv2",
    limit: "1",
    addressdetails: "0",
    email: "privacy@tailendcharlie.app",
    "accept-language": "en-GB",
  });
});

test("Photon results become named, placed search results", () => {
  const results = placeSearchResults(
    { api: "photon", baseUrl: "https://routing.example.test/photon" },
    {
      features: [
        {
          geometry: { type: "Point", coordinates: [-2.5879, 51.4545] },
          properties: { name: "Bristol", county: "City of Bristol", country: "United Kingdom" },
        },
        {
          geometry: { type: "Point", coordinates: [-2.6, 51.45] },
          properties: {
            housenumber: "12",
            street: "Park Street",
            city: "Bristol",
            postcode: "BS1 5HX",
            country: "United Kingdom",
          },
        },
        { geometry: { type: "Point", coordinates: "bad" }, properties: { name: "Unusable" } },
        { properties: { name: "No geometry" } },
      ],
    },
  );
  assert.deepEqual(results, [
    {
      latitude: 51.4545,
      longitude: -2.5879,
      name: "Bristol",
      address: "Bristol, City of Bristol, United Kingdom",
    },
    {
      latitude: 51.45,
      longitude: -2.6,
      name: "12 Park Street",
      address: "12 Park Street, Bristol, BS1 5HX, United Kingdom",
    },
  ]);
  assert.deepEqual(placeSearchResults({ api: "photon" }, null), []);
});

test("Nominatim results keep their existing shape", () => {
  const results = placeSearchResults(PUBLIC_ROUTING_SERVICES.geocoder, [
    { lat: "53.121", lon: "-1.562", display_name: "Matlock Bath, Derbyshire, United Kingdom" },
    { lat: "x", lon: "-1", display_name: "Broken" },
  ]);
  assert.deepEqual(results, [
    {
      latitude: 53.121,
      longitude: -1.562,
      name: "Matlock Bath",
      address: "Matlock Bath, Derbyshire, United Kingdom",
    },
  ]);
  assert.deepEqual(placeSearchResults(PUBLIC_ROUTING_SERVICES.geocoder, { error: "x" }), []);
});

test("the Photon label matches the app's: no part repeated", () => {
  assert.equal(
    photonAddress({ name: "Bristol", city: "Bristol", country: "United Kingdom" }),
    "Bristol, United Kingdom",
  );
});
