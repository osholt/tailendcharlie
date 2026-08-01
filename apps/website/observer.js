import {
  describeGroupFreshness,
  describeFreshness,
  observerCoordinates,
  observerServiceOrigin,
  parseObserverFragment,
  participantFreshnessLabel,
  participantRoleLabel,
  remainingLabel,
  rideStatusLabel,
  describeAssistance,
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
  riderListSection: document.querySelector("#rider-list-section"),
  riderList: document.querySelector("#rider-list"),
  mapEmpty: document.querySelector("#map-empty"),
  recenterMap: document.querySelector("#recenter-map"),
};

let snapshot = null;
let map = null;
let mapReady = false;
let markers = [];
let hasFramedMap = false;
let refreshTimer = null;

elements.recenterMap.addEventListener("click", () => frameMap(true));

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
  const freshness =
    snapshot.scope === "group"
      ? describeGroupFreshness(snapshot)
      : describeFreshness(snapshot);
  elements.freshness.textContent = freshness.label;
  elements.positionAge.textContent = freshness.age;
  // Visibility and wording are decided together, so the bar cannot appear with
  // nothing in it (#278). Deciding them separately is what produced a red alert
  // containing no words on a tester's phone.
  const assistance = describeAssistance(snapshot);
  elements.assistance.hidden = assistance === null;
  if (assistance) {
    elements.assistanceLabel.textContent = assistance.label;
    elements.assistanceTime.textContent = assistance.time;
  }
  renderRiders();
  renderTimes();
  renderPosition();
}

function renderRiders() {
  const group = snapshot?.scope === "group";
  elements.riderListSection.hidden = !group;
  elements.riderList.replaceChildren();
  if (!group) return;
  for (const rider of snapshot.participants || []) {
    const item = document.createElement("li");
    item.className = "observer-rider";
    const dot = document.createElement("span");
    dot.className = "observer-rider-dot";
    dot.style.setProperty("--rider-color", rider.color);
    dot.setAttribute("aria-hidden", "true");
    const name = document.createElement("strong");
    name.textContent = rider.displayName;
    const status = document.createElement("span");
    status.textContent = `${participantRoleLabel(rider.role)} · ${participantFreshnessLabel(rider.freshness)}`;
    item.append(dot, name, status);
    elements.riderList.append(item);
  }
}

function renderTimes() {
  if (!snapshot) return;
  elements.expiry.textContent = remainingLabel(snapshot.expiresAt);
}

function renderPosition() {
  const coordinates = observerCoordinates(snapshot);
  elements.mapEmpty.hidden = coordinates.length > 0;
  elements.recenterMap.hidden =
    coordinates.length === 0 || !window.maplibregl;
  if (coordinates.length === 0) return;
  elements.mapEmpty.textContent =
    snapshot.scope === "group"
      ? `${(snapshot.participants || []).filter((rider) => rider.position).length} rider positions available.`
      : `Last known: ${snapshot.position.latitude.toFixed(5)}, ${snapshot.position.longitude.toFixed(5)}`;
  if (!window.maplibregl || !MAP_STYLE_URL) {
    elements.mapEmpty.hidden = false;
    return;
  }
  if (!map) {
    map = new window.maplibregl.Map({
      container: "observer-map",
      style: MAP_STYLE_URL,
      center: coordinates[0],
      zoom: 13,
      attributionControl: true,
    });
    map.on("error", () => {
      elements.mapEmpty.hidden = false;
    });
    map.addControl(new window.maplibregl.NavigationControl(), "top-right");
    map.on("load", () => {
      mapReady = true;
      renderMapData();
      frameMap();
    });
  }
  renderMapData();
  if (mapReady && !hasFramedMap) frameMap();
}

function renderMapData() {
  if (!map || !mapReady || !snapshot) return;
  for (const marker of markers) marker.remove();
  markers = [];
  if (snapshot.scope === "group") {
    for (const rider of snapshot.participants || []) {
      if (!rider.position) continue;
      const markerElement = document.createElement("div");
      markerElement.className = "observer-group-marker";
      markerElement.style.setProperty("--rider-color", rider.color);
      markerElement.setAttribute(
        "aria-label",
        `${rider.displayName}, ${participantFreshnessLabel(rider.freshness)}`,
      );
      markerElement.title = rider.displayName;
      markers.push(
        new window.maplibregl.Marker({ element: markerElement })
          .setLngLat([rider.position.longitude, rider.position.latitude])
          .addTo(map),
      );
    }
  } else if (snapshot.position) {
    const markerElement = document.createElement("div");
    markerElement.className = "observer-position-marker";
    markerElement.setAttribute("aria-label", "Last-known rider position");
    markers.push(
      new window.maplibregl.Marker({ element: markerElement })
        .setLngLat([snapshot.position.longitude, snapshot.position.latitude])
        .addTo(map),
    );
  }
  const routeCoordinates = (snapshot.route?.points || []).map((point) => [
    point.longitude,
    point.latitude,
  ]);
  const route = {
    type: "FeatureCollection",
    features:
      routeCoordinates.length < 2
        ? []
        : [
            {
              type: "Feature",
              properties: {},
              geometry: {
                type: "LineString",
                coordinates: routeCoordinates,
              },
            },
          ],
  };
  if (map.getSource("observer-route")) {
    map.getSource("observer-route").setData(route);
  } else {
    map.addSource("observer-route", { type: "geojson", data: route });
    map.addLayer({
      id: "observer-route",
      type: "line",
      source: "observer-route",
      paint: {
        "line-color": "#5ac8fa",
        "line-width": 5,
        "line-opacity": 0.85,
      },
    });
  }
}

function frameMap(force = false) {
  if (!map || !mapReady || (!force && hasFramedMap)) return;
  const coordinates = observerCoordinates(snapshot);
  if (coordinates.length === 0) return;
  hasFramedMap = true;
  if (coordinates.length === 1) {
    map.easeTo({ center: coordinates[0], zoom: 13, duration: 700 });
    return;
  }
  const bounds = coordinates.reduce(
    (value, coordinate) => value.extend(coordinate),
    new window.maplibregl.LngLatBounds(coordinates[0], coordinates[0]),
  );
  map.fitBounds(bounds, { padding: 70, maxZoom: 15, duration: 700 });
}

function showError(message) {
  elements.subjectName.textContent = "Safety link unavailable";
  elements.accessLabel.textContent = "";
  elements.content.hidden = true;
  elements.error.textContent = message;
  elements.error.hidden = false;
  elements.mapEmpty.textContent = "No location is available.";
}
