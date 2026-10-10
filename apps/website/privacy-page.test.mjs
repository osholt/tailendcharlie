import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const privacy = await readFile(new URL("./privacy.html", import.meta.url), "utf8");
const text = privacy
  .replace(/<[^>]+>/g, " ")
  .replace(/&middot;/g, "·")
  .replace(/&ldquo;|&rdquo;/g, '"')
  .replace(/\s+/g, " ");

test("the effective date is no earlier than the day build 102's sharing pause reached main", () => {
  // #859 (sharing stops after a group disperses) merged to main in the build
  // 102 combined PR on 5 October 2026, and the page's sentence about it went
  // out without a new date. A later change to what the page says may move it on.
  const match = text.match(/Effective (\d{1,2}) (\w+) (\d{4}) ·/);
  assert.ok(match, "the page states an effective date");
  const effective = new Date(`${match[1]} ${match[2]} ${match[3]} 00:00:00 UTC`);
  assert.ok(effective >= new Date("2026-10-05T00:00:00Z"), match[0]);
});

test("the sharing pause is described as the app does it", () => {
  assert.match(text, /about half an hour, the app asks whether you are still riding/);
  assert.match(text, /15 minutes after you were asked or last moved, whichever is later/);
  assert.match(text, /until you choose to resume/);
  assert.match(text, /alert, such as an emergency-stop alert, switches sharing back on/);
  assert.match(text, /A dot on the ride menu always shows whether you are sharing/);
});

test("the Bluetooth evidence counters are described as counts, never names", () => {
  assert.match(text, /Record ride diagnostics/);
  assert.match(text, /off by default/);
  assert.match(
    text,
    /counts how updates from other riders reached your phone, by phone signal or by Bluetooth/,
  );
  assert.match(text, /no other rider's position and no rider's name/);
  assert.match(text, /Nothing is sent anywhere until you choose a recipient/);
});

test("alerts are described as logged with time, place and who raised them", () => {
  assert.match(text, /record of alerts raised during a ride/);
  assert.match(text, /with the time, the place and who raised each one/);
  assert.match(text, /GPX, CSV or summary you choose to send/);
});

test("an un-ended ride is kept from the last synchronisation, not from creation", () => {
  assert.match(
    text,
    /A ride record overall \(if never explicitly ended\) 72 hours after any phone in the ride last synchronised/,
  );
  assert.doesNotMatch(text, /72 hours from creation/);
});

test("the age rule is 17 and says so on the page", () => {
  assert.match(text, /Tail End Charlie is for riders aged 17 or over/);
  assert.match(text, /not directed at, or intended for use by, anyone under 17/);
  assert.doesNotMatch(text, /under 16/);
});

test("the page says it is a beta and gives beta support its own address", () => {
  assert.match(text, /Beta notice: Tail End Charlie is in an open beta/);
  assert.match(text, /Beta support, bug reports and feedback: testing@tailendcharlie\.app/);
  // Data requests keep their own address, so support mail cannot swallow them.
  assert.match(text, /For data requests use the privacy address above/);
  assert.match(privacy, /mailto:privacy@tailendcharlie\.app/);
  assert.match(privacy, /href="mailto:testing@tailendcharlie\.app"/);
});

test("push notification tokens are described as the relay holds them", () => {
  assert.match(text, /Apple's push service \(iOS\) or Google's Firebase Cloud Messaging \(Android\)/);
  assert.match(text, /encrypted on the relay, tied to your random device identifier for one ride, and revoked when you leave or the ride ends/);
  assert.match(text, /no name, position or emergency-contact details/);
  assert.match(text, /You can refuse notifications and still use the app/);
});

test("the effective date moves with this change", () => {
  const match = text.match(/Effective (\d{1,2}) (\w+) (\d{4}) ·/);
  assert.ok(match);
  const effective = new Date(`${match[1]} ${match[2]} ${match[3]} 00:00:00 UTC`);
  assert.ok(effective >= new Date("2026-10-10T00:00:00Z"), match[0]);
});

test("global heatmap contribution is opt-in, asked at setup, and nothing is shared until chosen (#957)", () => {
  // The operator decided on 10 October 2026: "at setup ask about contributing
  // to the global heat map". The page must not call contribution a default.
  assert.match(text, /Contribution of completed rides is opt-in and off until you choose/);
  assert.match(text, /First setup asks, with no option pre-selected, and skipping it means Never/);
  assert.match(text, /asked once on the home map and shares nothing until you answer/);
  assert.doesNotMatch(text, /Contribution of completed rides is on by default/);
});
