const GRANT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TOKEN = /^ro1_[A-Za-z0-9_-]{43}$/;

export function observerServiceOrigin(pageUrl, configuredOrigin) {
  const page = new URL(pageUrl);
  if (
    page.hostname === "tailendcharlie.app" ||
    page.hostname === "www.tailendcharlie.app"
  ) {
    const configured = new URL(configuredOrigin);
    if (configured.protocol !== "https:") {
      throw new TypeError("Observer service must use HTTPS");
    }
    return configured.origin;
  }
  return page.origin;
}

export function parseObserverFragment(fragment) {
  const value = String(fragment || "").replace(/^#/, "");
  const separator = value.indexOf(".");
  if (separator < 1) return null;
  const grantId = value.slice(0, separator);
  const token = value.slice(separator + 1);
  if (!GRANT_ID.test(grantId) || !TOKEN.test(token)) return null;
  return { grantId, token };
}

export function describeFreshness(snapshot, now = new Date()) {
  const recordedAt = snapshot?.position?.recordedAt
    ? new Date(snapshot.position.recordedAt)
    : null;
  const ageSeconds =
    recordedAt && !Number.isNaN(recordedAt.valueOf())
      ? Math.max(0, Math.floor((now - recordedAt) / 1000))
      : null;
  const age =
    ageSeconds === null
      ? "No location received"
      : ageSeconds < 60
        ? `${ageSeconds}s ago`
        : ageSeconds < 3600
          ? `${Math.floor(ageSeconds / 60)}m ago`
          : `${Math.floor(ageSeconds / 3600)}h ago`;
  const label = {
    unavailable: "Awaiting a location",
    fresh: "Recently updated",
    delayed: "Updates delayed",
    offline: "No recent updates",
  }[snapshot?.freshness] || "Update state unavailable";
  return { label, age };
}

export function rideStatusLabel(status) {
  return (
    {
      waiting: "Waiting to start",
      active: "Ride in progress",
      paused: "Ride paused",
      ended: "Ride ended",
    }[status] || "Ride status unavailable"
  );
}

export function remainingLabel(expiresAt, now = new Date()) {
  const expiry = new Date(expiresAt);
  const seconds = Math.floor((expiry - now) / 1000);
  if (!Number.isFinite(seconds) || seconds <= 0) return "Access expired";
  if (seconds < 3600) return `Expires in ${Math.ceil(seconds / 60)} minutes`;
  const hours = Math.ceil(seconds / 3600);
  return `Expires in ${hours} ${hours === 1 ? "hour" : "hours"}`;
}
