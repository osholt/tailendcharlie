import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const assetLinks = JSON.parse(
  await readFile(
    new URL("./.well-known/assetlinks.json", import.meta.url),
    "utf8",
  ),
);
const appleAssociation = JSON.parse(
  await readFile(
    new URL("./.well-known/apple-app-site-association", import.meta.url),
    "utf8",
  ),
);

test("Android app links trust Play and local debug signatures", () => {
  const target = assetLinks[0]?.target;

  assert.equal(target?.package_name, "app.tailendcharlie");
  assert.deepEqual(target?.sha256_cert_fingerprints, [
    "B2:D8:33:4B:CB:ED:1A:B6:55:6F:60:8B:5B:67:5A:9C:A7:EC:77:9C:7E:A1:7F:AB:47:4F:D8:AF:C6:64:60:A0",
    "65:0E:AF:4C:A4:8C:AC:89:5B:8F:5B:98:0F:8E:FF:76:18:F1:68:C1:CB:F1:A3:D2:A4:A6:1A:F0:8E:0A:0A:EB",
  ]);
});

test("iOS universal links target the production planner route", () => {
  const detail = appleAssociation.applinks?.details?.[0];

  assert.deepEqual(detail?.appIDs, ["UY4624PH6X.app.tailendcharlie"]);
  assert.deepEqual(detail?.components?.[0]?.["/"], "/planner.html");
  assert.deepEqual(detail?.components?.[0]?.["?"]?.code, "?*");
});
