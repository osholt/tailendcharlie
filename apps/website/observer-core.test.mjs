import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  describeFreshness,
  observerServiceOrigin,
  parseObserverFragment,
  remainingLabel,
  rideStatusLabel,
} from "./observer-core.mjs";

test("observer credentials are accepted only in the high-entropy fragment shape", () => {
  const valid =
    "#123e4567-e89b-42d3-a456-426614174000.ro1_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq";
  assert.deepEqual(parseObserverFragment(valid), {
    grantId: "123e4567-e89b-42d3-a456-426614174000",
    token: "ro1_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq",
  });
  assert.equal(parseObserverFragment("#123456"), null);
  assert.equal(
    parseObserverFragment(
      "#123e4567-e89b-42d3-a456-426614174000.rr1_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq",
    ),
    null,
  );
});

test("preproduction observer links never cross into the production relay", () => {
  assert.equal(
    observerServiceOrigin(
      "https://preprod-relay.example.com/observer.html#secret",
      "https://relay.tailendcharlie.app",
    ),
    "https://preprod-relay.example.com",
  );
  assert.equal(
    observerServiceOrigin(
      "https://tailendcharlie.app/observer.html#secret",
      "https://relay.tailendcharlie.app",
    ),
    "https://relay.tailendcharlie.app",
  );
});

test("freshness always describes a last-known update", () => {
  const now = new Date("2026-07-24T12:00:30Z");
  assert.deepEqual(
    describeFreshness(
      {
        freshness: "fresh",
        position: { recordedAt: "2026-07-24T12:00:00Z" },
      },
      now,
    ),
    { label: "Recently updated", age: "30s ago" },
  );
  assert.deepEqual(describeFreshness({ freshness: "offline" }, now), {
    label: "No recent updates",
    age: "No location received",
  });
});

test("ride and expiry labels are bounded and explicit", () => {
  assert.equal(rideStatusLabel("paused"), "Ride paused");
  assert.equal(
    remainingLabel(
      "2026-07-24T13:00:00Z",
      new Date("2026-07-24T12:00:00Z"),
    ),
    "Expires in 1 hour",
  );
  assert.equal(
    remainingLabel(
      "2026-07-24T11:00:00Z",
      new Date("2026-07-24T12:00:00Z"),
    ),
    "Access expired",
  );
});

test("observer location never goes to the public third-party tile service", async () => {
  const [html, javascript, headers] = await Promise.all([
    readFile(new URL("./observer.html", import.meta.url), "utf8"),
    readFile(new URL("./observer.js", import.meta.url), "utf8"),
    readFile(new URL("./_headers", import.meta.url), "utf8"),
  ]);
  const implementation = `${html}\n${javascript}\n${headers.split("/observer.html")[1]}`;
  assert.doesNotMatch(implementation, /tiles\.openfreemap\.org/);
  assert.doesNotMatch(implementation, /unpkg\.com/);
  assert.match(implementation, /API_URL}\/maps\/styles\/ride-relay\.json/);
  assert.match(
    html,
    /\/assets\/maplibre-gl-5\.24\.0\/maplibre-gl\.(?:js|css)/,
  );
});

test("observer MapLibre assets are the reviewed vendored release", async () => {
  const [javascript, css, license] = await Promise.all([
    readFile(
      new URL(
        "./assets/maplibre-gl-5.24.0/maplibre-gl.js",
        import.meta.url,
      ),
    ),
    readFile(
      new URL(
        "./assets/maplibre-gl-5.24.0/maplibre-gl.css",
        import.meta.url,
      ),
    ),
    readFile(
      new URL("./assets/maplibre-gl-5.24.0/LICENSE.txt", import.meta.url),
      "utf8",
    ),
  ]);
  const sha384 = (value) =>
    createHash("sha384").update(value).digest("base64");
  assert.equal(
    sha384(javascript),
    "5+cfbwT0iiub6VsQAdn6yz16nr6sDiQoHx6tm4O8OVYXHYOxcffFmCJBL0dgdvGp",
  );
  assert.equal(
    sha384(css),
    "uTttxo/aOKbdE5RlD/SPzSDoDmNvGlUYPjONi2MN/b7c9HPSvW07OIuyP7uL6jxK",
  );
  assert.match(license, /Copyright \(c\) 2023, MapLibre contributors/);
});
