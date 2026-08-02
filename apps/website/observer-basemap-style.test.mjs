import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

/// Guards the observer basemap style and the server config that renders it (#281).
///
/// Both failures this covers are silent. A relative tile URL and a missing
/// `templates` directive each produce a blank map with no console error, no
/// failed request and no MapLibre error event - the map simply never draws. That
/// is indistinguishable to a safety contact from "the ride has no position yet",
/// which is why it went unnoticed long enough to be reported as a bug.

const STYLE_PATH = new URL(
  "../../deploy/maps/styles/ride-relay.json",
  import.meta.url,
);
const CADDYFILES = [
  new URL("../../deploy/Caddyfile", import.meta.url),
  new URL("../../deploy/Caddyfile.preproduction", import.meta.url),
];

const readStyleText = () => readFile(STYLE_PATH, "utf8");
const readStyle = async () => JSON.parse(await readStyleText());

/// Every URL the style asks MapLibre to fetch. Tiles and glyphs are loaded from a
/// worker, and a worker has no document base, so each of these has to be absolute
/// by the time it reaches the browser.
const fetchedUrls = (style) => [
  style.glyphs,
  ...Object.values(style.sources ?? {}).flatMap((source) => source.tiles ?? []),
];

test("the style is a valid version 8 MapLibre style", async () => {
  const style = await readStyle();
  assert.equal(style.version, 8);
  assert.ok(Array.isArray(style.layers) && style.layers.length > 0);
});

test("no URL MapLibre fetches is relative", async () => {
  const style = await readStyle();
  const urls = fetchedUrls(style);
  assert.ok(urls.length >= 2, "expected glyphs and at least one tile URL");
  for (const url of urls) {
    assert.ok(
      !url.startsWith("../") && !url.startsWith("./"),
      `${url} is relative. MapLibre fetches tiles and glyphs from a worker, ` +
        `which has no document base, so this throws "Failed to parse URL" and ` +
        `draws an empty map without reporting an error.`,
    );
    assert.ok(
      url.startsWith("{{") || /^https?:\/\//.test(url),
      `${url} must be absolute, or a template that renders one`,
    );
  }
});

test("templated URLs resolve to an absolute URL once rendered", async () => {
  const style = await readStyle();
  // Stand in for Caddy: substitute the placeholders the same way it does, then
  // require the result to parse as an absolute URL. A template that renders to
  // something relative would pass the check above and still break.
  const rendered = (url) =>
    url
      .replaceAll(/\{\{placeholder `http\.request\.scheme`\}\}/g, "https")
      .replaceAll(
        /\{\{placeholder `http\.request\.hostport`\}\}/g,
        "relay.example.com",
      );
  for (const url of fetchedUrls(style)) {
    const resolved = rendered(url);
    assert.ok(
      !resolved.includes("{{"),
      `${url} still has an unrendered placeholder - Caddy would emit it raw`,
    );
    // The tile and glyph tokens are not valid URL syntax, so strip them first.
    const probe = resolved
      .replace("{z}/{x}/{y}", "0/0/0")
      .replace("{fontstack}/{range}", "f/0-255");
    assert.doesNotThrow(
      () => new URL(probe),
      `${probe} is not an absolute URL`,
    );
  }
});

test("every layer draws from a declared source", async () => {
  const style = await readStyle();
  const declared = new Set(Object.keys(style.sources ?? {}));
  for (const layer of style.layers) {
    if (layer.type === "background") continue;
    assert.ok(
      declared.has(layer.source),
      `layer ${layer.id} reads from undeclared source ${layer.source}`,
    );
  }
});

test("the basemap credits OpenStreetMap, as its licence requires", async () => {
  const style = await readStyle();
  for (const source of Object.values(style.sources ?? {})) {
    assert.match(source.attribution ?? "", /OpenStreetMap/);
  }
});

test("the style parses as a Go template", async () => {
  // The whole file is rendered by Caddy's templates directive. Any stray {{ ... }}
  // - including one written inside a metadata note - is parsed as an action and
  // fails the render, which serves a 500 and blanks the map.
  const text = await readStyleText();
  const actions = text.match(/\{\{[^}]*\}\}/g) ?? [];
  for (const action of actions) {
    assert.match(
      action,
      /^\{\{placeholder `http\.request\.(scheme|hostport)`\}\}$/,
      `${action} is not a placeholder call this style is allowed to use`,
    );
  }
});

test("both Caddyfiles render the style rather than serving it raw", async () => {
  for (const caddyfile of CADDYFILES) {
    const text = await readFile(caddyfile, "utf8");
    const blocks = text.split("handle_path /maps/styles/*").slice(1);
    assert.ok(blocks.length > 0, `${caddyfile.pathname} serves no style route`);
    for (const block of blocks) {
      const body = block.slice(0, block.indexOf("\n\t}"));
      assert.match(
        body,
        /templates\s*\{/,
        `a /maps/styles route in ${caddyfile.pathname} has no templates ` +
          `directive, so the style would be served with its placeholders intact`,
      );
      assert.match(
        body,
        /mime application\/json/,
        `templates only processes text/html and plain text by default, so a ` +
          `.json style in ${caddyfile.pathname} passes through unrendered`,
      );
      // observer-core.mjs sends the marketing-site copy of the observer to the
      // relay for its API origin, so that deployment reads this style
      // cross-origin. The proxied tiles and glyphs answer with a wildcard
      // already; the style is served by file_server and gets none by default.
      assert.match(
        body,
        /header Access-Control-Allow-Origin/,
        `the style route in ${caddyfile.pathname} sends no CORS header, so an ` +
          `observer served from another origin cannot load it`,
      );
    }
  }
});

test("both Caddyfiles keep a build segment in the upstream tile path", async () => {
  for (const caddyfile of CADDYFILES) {
    const text = await readFile(caddyfile, "utf8");
    const rewrites = text.match(/rewrite \* \/planet[^\n]*/g) ?? [];
    assert.ok(rewrites.length > 0, `${caddyfile.pathname} proxies no basemap`);
    for (const rewrite of rewrites) {
      // Upstream ignores the value but requires the segment: without it the
      // request is one component short and answers 200 with an empty body.
      assert.match(
        rewrite,
        /\/planet\/[^{]*\{\$RIDE_RELAY_BASEMAP_VERSION[^}]*\}\{path\}/,
        `${rewrite.trim()} must insert a build segment before {path}, or ` +
          `upstream returns an empty 200 and the map is blank`,
      );
    }
  }
});
