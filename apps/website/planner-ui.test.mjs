import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const plannerCss = await readFile(
  new URL("./planner.css", import.meta.url),
  "utf8",
);
const plannerHtml = await readFile(
  new URL("./planner.html", import.meta.url),
  "utf8",
);

test("the enabled app-code action is visually distinct from disabled actions", () => {
  const enabledRule = plannerCss.match(
    /\.planner-actions \.button-secondary:not\(:disabled\)\s*\{(?<body>[^}]+)\}/,
  );
  const disabledRule = plannerCss.match(
    /\.planner-actions \.button:disabled\s*\{(?<body>[^}]+)\}/,
  );

  assert.ok(enabledRule, "missing enabled secondary-action style");
  assert.ok(disabledRule, "missing disabled action style");
  assert.match(enabledRule.groups.body, /border:/);
  assert.match(enabledRule.groups.body, /background:/);
  assert.notEqual(enabledRule.groups.body.trim(), disabledRule.groups.body.trim());
});

test("planner assets are versioned so deployed fixes replace cached copies", () => {
  assert.match(plannerHtml, /href="\/planner\.css\?v=\d{8}-\d+"/);
  assert.match(plannerHtml, /src="\/planner\.js\?v=\d{8}-\d+"/);
});

test("email route is a visible route action rather than a hidden result", () => {
  assert.match(
    plannerHtml,
    /<button class="button button-secondary" id="email-plan" disabled>/,
  );
  assert.match(plannerHtml, /Email route/);
});
