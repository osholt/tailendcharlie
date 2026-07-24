const PLAN_CODE = /^[A-Z0-9]{4,16}$/;

export function normalizePlanCode(value) {
  const code = String(value || "").trim().toUpperCase();
  if (!PLAN_CODE.test(code)) throw new Error("Enter a valid plan code.");
  return code;
}

export async function createRoutePlan({
  apiBase,
  name,
  gpx,
  fetchImpl = globalThis.fetch,
}) {
  const response = await fetchImpl(`${normalizedApiBase(apiBase)}/api/v1/plans`, {
    method: "POST",
    credentials: "omit",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ name: String(name).trim() || null, gpx }),
  });
  return readPlanResponse(response, "create");
}

export async function fetchRoutePlan({
  apiBase,
  code,
  fetchImpl = globalThis.fetch,
}) {
  const normalizedCode = normalizePlanCode(code);
  const response = await fetchImpl(
    `${normalizedApiBase(apiBase)}/api/v1/plans/${encodeURIComponent(normalizedCode)}`,
    {
      credentials: "omit",
      headers: { Accept: "application/json" },
    },
  );
  return readPlanResponse(response, "fetch");
}

export function buildPlannerPlanUrl(code, pageUrl) {
  const url = new URL("/planner.html", pageUrl);
  url.search = "";
  url.hash = "";
  url.searchParams.set("code", normalizePlanCode(code));
  return url.toString();
}

export function buildPlanEmailHref({
  name,
  code,
  planUrl,
  expiresAt,
  routeSummary = "",
}) {
  const normalizedCode = normalizePlanCode(code);
  const expires = new Date(expiresAt);
  const routeName = String(name || "").trim() || "planned ride";
  const summary = String(routeSummary || "").trim();
  const expiryText = Number.isNaN(expires.getTime())
    ? ""
    : `\nThis link and code expire on ${new Intl.DateTimeFormat("en-GB", {
        dateStyle: "long",
      }).format(expires)}.`;
  const subject = `Tail End Charlie route: ${routeName}`;
  const body = [
    `Ride: ${routeName}`,
    ...(summary ? ["", "Route summary", summary] : []),
    "",
    `Open and edit the route: ${planUrl}`,
    "",
    `To load it in the Tail End Charlie app, open the ride map, choose Change route → Load a planned route, and enter code ${normalizedCode}.`,
    expiryText,
  ].join("\n");
  return `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

function normalizedApiBase(value) {
  const url = new URL(String(value || ""));
  if (!["https:", "http:"].includes(url.protocol) || !url.host) {
    throw new Error("The route sharing service is not configured.");
  }
  return url.toString().replace(/\/$/, "");
}

async function readPlanResponse(response, operation) {
  if (!response?.ok) {
    if (operation === "fetch" && response?.status === 404) {
      throw new Error("That route code was not found. It may have expired.");
    }
    throw new Error(
      operation === "create"
        ? "The route code could not be created. Try again."
        : "The shared route could not be loaded. Try again.",
    );
  }
  const contentType = response.headers?.get?.("content-type")?.toLowerCase() || "";
  if (!contentType.includes("application/json")) {
    throw new Error("The route sharing service returned an invalid response.");
  }
  const payload = await response.json();
  const code = normalizePlanCode(payload?.code);
  if (operation === "create") {
    const expires = new Date(payload?.expiresAt);
    if (Number.isNaN(expires.getTime())) {
      throw new Error("The route sharing service returned an invalid response.");
    }
    return { code, expiresAt: expires.toISOString() };
  }
  if (typeof payload?.gpx !== "string" || payload.gpx.length === 0) {
    throw new Error("The route sharing service returned an invalid response.");
  }
  return {
    code,
    name: typeof payload.name === "string" ? payload.name : null,
    gpx: payload.gpx,
    expiresAt: String(payload.expiresAt || ""),
  };
}
