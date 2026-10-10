import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const terms = await readFile(new URL("./terms.html", import.meta.url), "utf8");
const text = terms
  .replace(/<[^>]+>/g, " ")
  .replace(/&middot;/g, "·")
  .replace(/\s+/g, " ");

test("eligibility is 17 or over, matching the privacy policy and the store listings", () => {
  assert.match(text, /You must be 17 or over, and old enough to hold a valid licence/);
  assert.match(text, /not directed at or intended for use by anyone under 17/);
  assert.doesNotMatch(text, /under 16/);
});

test("the terms say beta and name the support address", () => {
  assert.match(text, /Beta notice: Tail End Charlie is in an open beta/);
  assert.match(text, /Beta support, bug reports and feedback: testing@tailendcharlie\.app/);
  assert.match(terms, /mailto:privacy@tailendcharlie\.app/);
  assert.match(terms, /href="mailto:testing@tailendcharlie\.app"/);
});

test("the terms keep saying it is not an emergency service", () => {
  assert.match(text, /It is not an emergency service/);
  assert.match(text, /not an emergency service or a certified emergency-coordination tool/);
});

test("the emergency-stop alert is said to reach only the group, and navigation to be advisory", () => {
  assert.match(
    text,
    /The emergency-stop alert reaches only the riders in your ride group; it does not contact the emergency services or anyone else/,
  );
  assert.match(text, /Navigation is advisory\. Do not handle your phone while riding/);
});

test("the effective date is no earlier than the 17+ change", () => {
  const match = text.match(/Effective (\d{1,2}) (\w+) (\d{4}) ·/);
  assert.ok(match, "the page states an effective date");
  const effective = new Date(`${match[1]} ${match[2]} ${match[3]} 00:00:00 UTC`);
  assert.ok(effective >= new Date("2026-10-10T00:00:00Z"), match[0]);
});
