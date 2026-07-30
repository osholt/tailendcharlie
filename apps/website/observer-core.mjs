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

export function describeGroupFreshness(snapshot) {
  const riders = Array.isArray(snapshot?.participants)
    ? snapshot.participants
    : [];
  const counts = {
    fresh: 0,
    delayed: 0,
    offline: 0,
    unavailable: 0,
  };
  for (const rider of riders) {
    const value = Object.hasOwn(counts, rider?.freshness)
      ? rider.freshness
      : "unavailable";
    counts[value] += 1;
  }
  const available = riders.length - counts.unavailable;
  const label =
    riders.length === 0
      ? "Awaiting the rider list"
      : counts.offline > 0
        ? `${counts.offline} rider${counts.offline === 1 ? "" : "s"} offline`
        : counts.delayed > 0
          ? `${counts.delayed} update${counts.delayed === 1 ? "" : "s"} delayed`
          : available === 0
            ? "Awaiting rider positions"
            : "Group recently updated";
  return {
    label,
    age: `${available} of ${riders.length} position${riders.length === 1 ? "" : "s"} available`,
    counts,
  };
}

export function participantFreshnessLabel(freshness) {
  return (
    {
      fresh: "Recently updated",
      delayed: "Update delayed",
      offline: "No recent update",
      unavailable: "No position yet",
    }[freshness] || "Position state unavailable"
  );
}

export function participantRoleLabel(role) {
  return (
    {
      lead: "Leader",
      tailEndCharlie: "Tail End Charlie",
      marker: "Marker",
      rider: "Rider",
    }[role] || "Rider"
  );
}

export function observerCoordinates(snapshot) {
  const values = [];
  if (snapshot?.scope === "group") {
    for (const rider of snapshot.participants || []) {
      if (validCoordinate(rider?.position)) {
        values.push([rider.position.longitude, rider.position.latitude]);
      }
    }
    for (const point of snapshot.route?.points || []) {
      if (validCoordinate(point)) {
        values.push([point.longitude, point.latitude]);
      }
    }
  } else if (validCoordinate(snapshot?.position)) {
    values.push([snapshot.position.longitude, snapshot.position.latitude]);
  }
  return values;
}

function validCoordinate(point) {
  return (
    Number.isFinite(point?.latitude) &&
    point.latitude >= -90 &&
    point.latitude <= 90 &&
    Number.isFinite(point?.longitude) &&
    point.longitude >= -180 &&
    point.longitude <= 180
  );
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
