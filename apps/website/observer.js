import {
  describeFreshness,
  observerServiceOrigin,
  parseObserverFragment,
  remainingLabel,
  rideStatusLabel,
} from "./observer-core.mjs";

const CONFIGURED_API_URL = document
  .querySelector('meta[name="tec-observer-api"]')
  ?.content?.replace(/\/$/, "");
const API_URL = observerServiceOrigin(
  window.location.href,
  CONFIGURED_API_URL,
);
const MAP_STYLE_URL = `${API_URL}/maps/styles/ride-relay.json`;
const credential = parseObserverFragment(window.location.hash);
const elements = {
  subjectName: document.querySelector("#subject-name"),
  accessLabel: document.querySelector("#access-label"),
  content: document.querySelector("#observer-content"),
  error: document.querySelector("#observer-error"),
  rideStatus: document.querySelector("#ride-status"),
  freshness: document.querySelector("#freshness-status"),
  positionAge: document.querySelector("#position-age"),
  expiry: document.querySelector("#access-expiry"),
  assistance: document.querySelector("#assistance-alert"),
  assistanceLabel: document.querySelector("#assistance-label"),
  assistanceTime: document.querySelector("#assistance-time"),
  mapEmpty: document.querySelector("#map-empty"),
};

let snapshot = null;
let map = null;
let marker = null;
let refreshTimer = null;

if (!credential || !API_URL) {
  showError(
    "This safety link is incomplete. Ask the rider to create and share a new link.",
  );
} else {
  refresh();
  refreshTimer = window.setInterval(refresh, 15_000);
  window.setInterval(renderTimes, 1_000);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) refresh();
  });
}

async function refresh() {
  try {
    const response = await fetch(
      `${API_URL}/api/v1/observer-grants/${encodeURIComponent(credential.grantId)}`,
      {
        headers: {
          accept: "application/json",
          authorization: `Bearer ${credential.token}`,
        },
        cache: "no-store",
        credentials: "omit",
        referrerPolicy: "no-referrer",
      },
    );
    if (response.status === 404) {
      clearInterval(refreshTimer);
      showError(
        "This safety link has expired, was revoked, or is no longer available.",
      );
      return;
    }
    if (!response.ok) {
      throw new Error(`Observer service returned ${response.status}`);
    }
    snapshot = await response.json();
    render();
  } catch {
    if (snapshot) {
      elements.freshness.textContent = "Refresh unavailable";
    } else {
      showError(
        "The latest shared position could not be loaded. Check your connection and try again.",
      );
    }
  }
}

function render() {
  elements.error.hidden = true;
  elements.content.hidden = false;
  elements.subjectName.textContent =
    snapshot.subjectName || "Shared rider progress";
  elements.accessLabel.textContent = snapshot.label;
  elements.rideStatus.textContent = rideStatusLabel(snapshot.rideStatus);
  const freshness = describeFreshness(snapshot);
  elements.freshness.textContent = freshness.label;
  elements.positionAge.textContent = freshness.age;
  elements.assistance.hidden = !snapshot.assistance;
  if (snapshot.assistance) {
    elements.assistanceLabel.textContent = snapshot.assistance.label;
    elements.assistanceTime.textContent = `Reported ${new Date(
      snapshot.assistance.reportedAt,
    ).toLocaleString()}`;
  }
  renderTimes();
  renderPosition();
}

function renderTimes() {
  if (!snapshot) return;
  elements.expiry.textContent = remainingLabel(snapshot.expiresAt);
}

function renderPosition() {
  const position = snapshot?.position;
  elements.mapEmpty.hidden = Boolean(position);
  if (!position) return;
  elements.mapEmpty.textContent =
    `Last known: ${position.latitude.toFixed(5)}, ${position.longitude.toFixed(5)}`;
  if (!window.maplibregl || !MAP_STYLE_URL) {
    elements.mapEmpty.hidden = false;
    return;
  }
  if (!map) {
    map = new window.maplibregl.Map({
      container: "observer-map",
      style: MAP_STYLE_URL,
      center: [position.longitude, position.latitude],
      zoom: 13,
      attributionControl: true,
    });
    map.on("error", () => {
      elements.mapEmpty.hidden = false;
    });
    map.addControl(new window.maplibregl.NavigationControl(), "top-right");
  }
  if (!marker) {
    const markerElement = document.createElement("div");
    markerElement.className = "observer-position-marker";
    markerElement.setAttribute("aria-label", "Last-known rider position");
    marker = new window.maplibregl.Marker({ element: markerElement })
      .setLngLat([position.longitude, position.latitude])
      .addTo(map);
  } else {
    marker.setLngLat([position.longitude, position.latitude]);
  }
  map.easeTo({
    center: [position.longitude, position.latitude],
    duration: 700,
  });
}

function showError(message) {
  elements.subjectName.textContent = "Safety link unavailable";
  elements.accessLabel.textContent = "";
  elements.content.hidden = true;
  elements.error.textContent = message;
  elements.error.hidden = false;
  elements.mapEmpty.textContent = "No location is available.";
}
