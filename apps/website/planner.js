import {
  buildGpx,
  chooseRoadRoute,
  decodePolyline,
  formatDistance,
  formatDuration,
  formatRouteBendScore,
  gpxFileName,
  motorcycleCostingOptions,
  routeBendScore,
  routeSelfCrossingArrows,
  StateHistory,
} from "./planner-core.mjs";
import {
  BIKER_PLACES,
  bikerPlaceKey,
  bikerPlacesGeoJson,
  distanceBetweenPlaces,
  normalizePlaceQuery,
  searchBikerPlaces,
  sortBikerPlaces,
} from "./biker-places.mjs";
import {
  decodePlannerDraft,
  encodePlannerDraft,
  PLANNER_DRAFT_KEY,
} from "./planner-storage.mjs";

const MAP_STYLE_URL = "https://tiles.openfreemap.org/styles/liberty";
const ROUTING_URL = "https://router.project-osrm.org";
const MOTORCYCLE_ROUTING_URL = "https://valhalla1.openstreetmap.de/route";
const SEARCH_URL = "https://nominatim.openstreetmap.org/search";
const MAX_STOPS = 50;
const SEARCH_CACHE_KEY = "tec-planner-search-v1";
const SEARCH_CACHE_MAX_AGE = 7 * 24 * 60 * 60 * 1000;
const CATALOG_TABLE_BATCH_SIZE = 75;

const elements = {
  clearRoute: document.querySelector("#clear-route"),
  avoidFerries: document.querySelector("#avoid-ferries"),
  avoidMajorRoads: document.querySelector("#avoid-major-roads"),
  avoidMotorways: document.querySelector("#avoid-motorways"),
  avoidTolls: document.querySelector("#avoid-tolls"),
  bikerBrowser: document.querySelector("#biker-browser"),
  bikerCatalogResults: document.querySelector("#biker-catalog-results"),
  bikerCatalogStatus: document.querySelector("#biker-catalog-status"),
  bikerFilter: document.querySelector("#biker-place-filter"),
  bikerLayerVisible: document.querySelector("#biker-layer-visible"),
  bikerLayerVisibleMenu: document.querySelector("#biker-layer-visible-menu"),
  bikerSort: document.querySelector("#biker-place-sort"),
  browseBikerStops: document.querySelector("#browse-biker-stops"),
  clearSavedDraft: document.querySelector("#clear-saved-draft"),
  distance: document.querySelector("#route-distance"),
  download: document.querySelector("#download-gpx"),
  duration: document.querySelector("#route-duration"),
  draftSaveStatus: document.querySelector("#draft-save-status"),
  emptyStops: document.querySelector("#empty-stops"),
  expand: document.querySelector("#map-expand"),
  expandLabel: document.querySelector(".map-expand-label"),
  mapInstructions: document.querySelector("#map-instructions"),
  mapShell: document.querySelector("#map-shell"),
  placeQuery: document.querySelector("#place-query"),
  placeSearch: document.querySelector("#place-search"),
  rideName: document.querySelector("#ride-name"),
  routeStyle: document.querySelector("#route-style"),
  resetAdjustments: document.querySelector("#reset-adjustments"),
  redoRoute: document.querySelector("#redo-route"),
  searchResults: document.querySelector("#search-results"),
  status: document.querySelector("#route-status"),
  stopList: document.querySelector("#stop-list"),
  twistiness: document.querySelector("#route-twistiness"),
  undoRoute: document.querySelector("#undo-route"),
};

let stops = [];
let shapingPoints = [];
let routeCoordinates = [];
let routeLegGeometries = [];
let routedControls = [];
let routeDistance = null;
let routeDuration = null;
let routeBendScoreValue = null;
let crossingArrowRoute = null;
let routeRequest = null;
let routeRequestSequence = 0;
let searchRequest = null;
let lastSearchAt = 0;
let stopSequence = 0;
let shapeSequence = 0;
let listDrag = null;
let routeDrag = null;
let suppressNextMapClick = false;
let bikerPlacePopup = null;
let routeAdjustmentPopup = null;
let previewRouteRequest = null;
let previewRouteTimer = null;
let pendingPreviewControls = null;
let previewRouteSequence = 0;
let lastPreviewRouteAt = 0;
let catalogTravelTimeRequest = null;
let catalogTravelTimeSequence = 0;
let catalogTravelTimes = { startKey: "", durations: new Map() };
let draftSaveTimer = null;
let restoringDraft = false;
const routeHistory = new StateHistory(50);
const routePreferenceElements = [
  elements.routeStyle,
  elements.avoidMotorways,
  elements.avoidMajorRoads,
  elements.avoidTolls,
  elements.avoidFerries,
];

elements.browseBikerStops.textContent =
  `Browse ${BIKER_PLACES.length} biker cafés & start locations`;
pruneSearchCache();

const map = new maplibregl.Map({
  container: "map",
  style: MAP_STYLE_URL,
  center: [-2.5, 54.4],
  zoom: 5.1,
  attributionControl: false,
});

map.addControl(
  new maplibregl.NavigationControl({ showCompass: false }),
  "bottom-left",
);
map.addControl(
  new maplibregl.AttributionControl({ compact: true }),
  "bottom-left",
);

map.on("load", () => {
  map.addImage("route-direction-arrow", createRouteArrowImage("#ffffff"), {
    pixelRatio: 2,
  });
  map.addImage("route-crossing-arrow", createRouteArrowImage("#ffad81"), {
    pixelRatio: 2,
  });
  map.addSource("route-draft", emptyLineSource());
  map.addLayer({
    id: "route-draft-line",
    type: "line",
    source: "route-draft",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": "#ffad81",
      "line-width": 3,
      "line-dasharray": [1.5, 2],
      "line-opacity": 0.8,
    },
  });
  map.addSource("road-route", emptyLineSource());
  map.addLayer({
    id: "road-route-casing",
    type: "line",
    source: "road-route",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": "#ffffff",
      "line-width": 9,
      "line-opacity": 0.86,
    },
  });
  map.addLayer({
    id: "road-route-line",
    type: "line",
    source: "road-route",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": "#6d2ee8",
      "line-width": 6,
    },
  });
  map.addLayer({
    id: "road-route-arrows",
    type: "symbol",
    source: "road-route",
    layout: {
      "symbol-placement": "line",
      "symbol-spacing": 105,
      "icon-image": "route-direction-arrow",
      "icon-size": 0.38,
      "icon-rotation-alignment": "map",
      "icon-pitch-alignment": "map",
      "icon-keep-upright": false,
      "icon-allow-overlap": true,
    },
    paint: { "icon-opacity": 0.96 },
  });
  map.addSource("route-crossing-arrows", {
    type: "geojson",
    data: pointData([]),
  });
  map.addLayer({
    id: "road-route-crossing-arrows",
    type: "symbol",
    source: "route-crossing-arrows",
    layout: {
      "icon-image": "route-crossing-arrow",
      "icon-size": 0.5,
      "icon-rotate": ["-", ["get", "bearing"], 90],
      "icon-rotation-alignment": "map",
      "icon-pitch-alignment": "map",
      "icon-allow-overlap": true,
      "icon-ignore-placement": true,
    },
  });
  map.addLayer({
    id: "road-route-hit",
    type: "line",
    source: "road-route",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": "#6d2ee8",
      "line-width": 24,
      "line-opacity": 0.01,
    },
  });
  map.addSource("biker-places", {
    type: "geojson",
    data: bikerPlacesGeoJson(),
    cluster: true,
    clusterMaxZoom: 9,
    clusterRadius: 42,
  });
  map.addLayer({
    id: "biker-place-clusters",
    type: "circle",
    source: "biker-places",
    filter: ["has", "point_count"],
    paint: {
      "circle-color": "#ffad81",
      "circle-radius": ["step", ["get", "point_count"], 15, 6, 19, 12, 23],
      "circle-stroke-color": "#171823",
      "circle-stroke-width": 3,
    },
  });
  map.addLayer({
    id: "biker-place-cluster-count",
    type: "symbol",
    source: "biker-places",
    filter: ["has", "point_count"],
    layout: {
      "text-field": ["get", "point_count_abbreviated"],
      "text-size": 11,
    },
    paint: { "text-color": "#190c26" },
  });
  map.addLayer({
    id: "biker-place-dots",
    type: "circle",
    source: "biker-places",
    filter: ["!", ["has", "point_count"]],
    paint: {
      "circle-color": "#ffad81",
      "circle-radius": 7,
      "circle-stroke-color": "#171823",
      "circle-stroke-width": 3,
    },
  });
  for (const layerId of ["biker-place-clusters", "biker-place-dots"]) {
    map.on("mouseenter", layerId, () => {
      map.getCanvas().style.cursor = "pointer";
    });
    map.on("mouseleave", layerId, () => {
      map.getCanvas().style.cursor = "";
    });
  }
  updateBikerLayerVisibility();
  updateMapLines();
  installRouteDragging();
  restorePlannerDraft();
});

map.on("click", async (event) => {
  if (suppressNextMapClick) {
    suppressNextMapClick = false;
    return;
  }
  if (event.originalEvent.target?.closest?.(".maplibregl-marker, .maplibregl-ctrl")) {
    return;
  }
  const cluster = map.getLayer("biker-place-clusters")
    ? map.queryRenderedFeatures(event.point, { layers: ["biker-place-clusters"] })[0]
    : null;
  if (cluster) {
    const source = map.getSource("biker-places");
    const zoom = await source.getClusterExpansionZoom(cluster.properties.cluster_id);
    map.easeTo({ center: cluster.geometry.coordinates, zoom });
    return;
  }
  const bikerPlace = map.getLayer("biker-place-dots")
    ? map.queryRenderedFeatures(event.point, { layers: ["biker-place-dots"] })[0]
    : null;
  if (bikerPlace) {
    showBikerPlacePopup(bikerPlace);
    return;
  }
  if (routeCoordinates.length > 1 && closestRouteLeg(event.lngLat, 20) >= 0) {
    insertStopOnRoute(event.lngLat);
    return;
  }
  addStop({
    longitude: event.lngLat.lng,
    latitude: event.lngLat.lat,
    name: `Stop ${stops.length + 1}`,
  });
});

map.on("error", (event) => {
  if (event?.error) {
    setStatus("The map tiles could not be loaded. Check your connection and try again.", true);
  }
});

elements.placeSearch.addEventListener("submit", searchPlaces);
elements.bikerBrowser.addEventListener("toggle", toggleBikerBrowser);
elements.bikerFilter.addEventListener("input", renderBikerCatalog);
elements.bikerFilter.addEventListener("keydown", (event) => {
  if (event.key === "Enter") event.preventDefault();
});
elements.bikerSort.addEventListener("change", changeBikerSort);
elements.bikerLayerVisible.addEventListener("change", changeBikerLayerVisibility);
elements.bikerLayerVisibleMenu.addEventListener("change", changeBikerLayerVisibility);
elements.stopList.addEventListener("input", editStop);
elements.stopList.addEventListener("change", commitCoordinateEdit);
elements.stopList.addEventListener("click", handleStopAction);
elements.stopList.addEventListener("pointerdown", beginListDrag);
elements.clearRoute.addEventListener("click", clearRoute);
elements.resetAdjustments.addEventListener("click", resetRouteAdjustments);
elements.undoRoute.addEventListener("click", undoRouteChange);
elements.redoRoute.addEventListener("click", redoRouteChange);
elements.clearSavedDraft.addEventListener("click", clearSavedPlannerData);
elements.download.addEventListener("click", downloadGpx);
elements.expand.addEventListener("click", toggleExpandedMap);
elements.rideName.addEventListener("input", () => {
  updateDownloadState();
  scheduleDraftSave();
});
for (const preference of routePreferenceElements) {
  preference.addEventListener("focus", rememberPreferenceValue);
  preference.addEventListener("change", changeRoutePreference);
  rememberPreferenceValue({ target: preference });
}
document.addEventListener("fullscreenchange", syncExpandedMapState);
window.addEventListener("pagehide", savePlannerDraft);
document.addEventListener("keydown", (event) => {
  if (
    (event.metaKey || event.ctrlKey) &&
    !event.altKey &&
    !event.target.closest?.("input, textarea, select")
  ) {
    const key = event.key.toLowerCase();
    if (key === "z") {
      event.preventDefault();
      if (event.shiftKey) redoRouteChange();
      else undoRouteChange();
      return;
    }
    if (key === "y") {
      event.preventDefault();
      redoRouteChange();
      return;
    }
  }
  if (event.key === "Escape" && elements.mapShell.classList.contains("is-expanded")) {
    setExpandedMap(false);
  }
});

function addStop(
  { id: requestedId, longitude, latitude, name },
  insertIndex = stops.length,
  shouldRoute = true,
  shouldRecord = true,
) {
  if (stops.length >= MAX_STOPS) {
    setStatus(`A route can contain up to ${MAX_STOPS} stops.`, true);
    return;
  }
  if (!isCoordinate(longitude, latitude)) {
    setStatus("That place does not have a valid map position.", true);
    return;
  }

  if (shouldRecord) recordRouteChange();
  const id = Number.isInteger(requestedId) ? requestedId : ++stopSequence;
  stopSequence = Math.max(stopSequence, id);
  const markerElement = document.createElement("button");
  markerElement.className = "route-marker";
  markerElement.type = "button";
  markerElement.setAttribute("aria-label", `Edit ${name}`);
  markerElement.addEventListener("click", (event) => {
    event.stopPropagation();
    focusStop(id);
  });
  const marker = new maplibregl.Marker({
    element: markerElement,
    draggable: true,
    anchor: "center",
  })
    .setLngLat([longitude, latitude])
    .addTo(map);
  marker.on("dragstart", () => recordRouteChange());
  marker.on("dragend", () => {
    const stop = stops.find((item) => item.id === id);
    if (!stop) return;
    const position = marker.getLngLat();
    stop.longitude = position.lng;
    stop.latitude = position.lat;
    renderStops();
    routeStops(false);
  });

  stops.splice(insertIndex, 0, {
    id,
    longitude,
    latitude,
    name: cleanPlaceName(name),
    marker,
  });
  renderStops();
  if (shouldRoute) routeStops();
  if (shouldRoute && stops.length === 1) {
    map.flyTo({ center: [longitude, latitude], zoom: 11 });
  }
}

function renderStops() {
  elements.stopList.replaceChildren();
  elements.emptyStops.hidden = stops.length > 0;
  elements.clearRoute.disabled = stops.length === 0;
  elements.resetAdjustments.hidden = shapingPoints.length === 0;
  elements.mapInstructions.textContent = stops.length
    ? "Tap the route to insert a stop · drag it to reshape · drag purple handles again"
    : "Tap the map to add a route point";

  stops.forEach((stop, index) => {
    stop.marker.getElement().textContent = String(index + 1);
    stop.marker
      .getElement()
      .setAttribute("aria-label", `Edit ${stop.name || `stop ${index + 1}`}`);

    const item = document.createElement("li");
    item.className = "stop-card";
    item.dataset.stopId = String(stop.id);
    item.innerHTML = `
      <button class="stop-number stop-drag-handle" type="button" data-drag-handle aria-label="Drag stop ${index + 1} to reorder" title="Drag to reorder">${index + 1}</button>
      <div class="stop-fields">
        <div class="stop-name-field">
          <label for="stop-name-${stop.id}">Stop ${index + 1} name</label>
          <input id="stop-name-${stop.id}" data-field="name" maxlength="100" value="${escapeAttribute(stop.name)}" />
        </div>
        <div class="coordinate-row">
          <div class="coordinate-field">
            <label for="stop-lat-${stop.id}">Latitude</label>
            <input id="stop-lat-${stop.id}" data-field="latitude" inputmode="decimal" value="${stop.latitude.toFixed(6)}" aria-label="Stop ${index + 1} latitude" />
          </div>
          <div class="coordinate-field">
            <label for="stop-lon-${stop.id}">Longitude</label>
            <input id="stop-lon-${stop.id}" data-field="longitude" inputmode="decimal" value="${stop.longitude.toFixed(6)}" aria-label="Stop ${index + 1} longitude" />
          </div>
        </div>
        <div class="stop-actions">
          <button class="stop-action" type="button" data-action="up" ${index === 0 ? "disabled" : ""}>Move up</button>
          <button class="stop-action" type="button" data-action="down" ${index === stops.length - 1 ? "disabled" : ""}>Move down</button>
          <button class="stop-action" type="button" data-action="locate">Show</button>
          <button class="stop-action" type="button" data-action="remove">Remove</button>
        </div>
      </div>`;
    elements.stopList.append(item);
  });
  updateMapLines();
  updateDownloadState();
  updateHistoryButtons();
  updateBikerSortAvailability();
  if (elements.bikerBrowser.open) {
    renderBikerCatalog();
    if (stops.length > 0 && elements.bikerSort.value === "duration") {
      void loadCatalogTravelTimes(stops[0]);
    }
  }
  scheduleDraftSave();
}

function editStop(event) {
  const item = event.target.closest("[data-stop-id]");
  const field = event.target.dataset.field;
  if (!item || field !== "name") return;
  const stop = findStop(item);
  if (!stop) return;
  if (event.target.dataset.historyRecorded !== "true") {
    recordRouteChange();
    event.target.dataset.historyRecorded = "true";
  }
  stop.name = event.target.value;
  stop.marker
    .getElement()
    .setAttribute("aria-label", `Edit ${stop.name || "unnamed stop"}`);
  scheduleDraftSave();
}

function commitCoordinateEdit(event) {
  const item = event.target.closest("[data-stop-id]");
  const field = event.target.dataset.field;
  if (!item) return;
  if (field === "name") {
    delete event.target.dataset.historyRecorded;
    return;
  }
  if (!["latitude", "longitude"].includes(field)) return;
  const stop = findStop(item);
  if (!stop) return;
  const value = Number(event.target.value);
  const longitude = field === "longitude" ? value : stop.longitude;
  const latitude = field === "latitude" ? value : stop.latitude;
  if (!isCoordinate(longitude, latitude)) {
    event.target.value = stop[field].toFixed(6);
    setStatus("Latitude must be -90 to 90 and longitude -180 to 180.", true);
    return;
  }
  if (value === stop[field]) return;
  recordRouteChange();
  stop[field] = value;
  stop.marker.setLngLat([stop.longitude, stop.latitude]);
  routeStops(false);
}

function handleStopAction(event) {
  const button = event.target.closest("[data-action]");
  const item = event.target.closest("[data-stop-id]");
  if (!button || !item) return;
  const index = stops.findIndex((stop) => stop.id === Number(item.dataset.stopId));
  if (index === -1) return;

  switch (button.dataset.action) {
    case "up":
      if (index === 0) return;
      recordRouteChange();
      clearShapingPoints();
      [stops[index - 1], stops[index]] = [stops[index], stops[index - 1]];
      break;
    case "down":
      if (index === stops.length - 1) return;
      recordRouteChange();
      clearShapingPoints();
      [stops[index], stops[index + 1]] = [stops[index + 1], stops[index]];
      break;
    case "locate":
      map.flyTo({ center: [stops[index].longitude, stops[index].latitude], zoom: 14 });
      focusStop(stops[index].id);
      return;
    case "remove":
      recordRouteChange();
      clearShapingPoints();
      stops[index].marker.remove();
      stops.splice(index, 1);
      break;
    default:
      return;
  }
  renderStops();
  routeStops(false);
}

function beginListDrag(event) {
  const handle = event.target.closest("[data-drag-handle]");
  const card = event.target.closest("[data-stop-id]");
  if (!handle || !card || event.button > 0) return;
  event.preventDefault();
  listDrag = {
    pointerId: event.pointerId,
    stopId: Number(card.dataset.stopId),
    targetId: Number(card.dataset.stopId),
    after: false,
    handle,
  };
  handle.setPointerCapture?.(event.pointerId);
  card.classList.add("is-dragging");
  document.body.classList.add("is-reordering-stops");
  window.addEventListener("pointermove", updateListDrag);
  window.addEventListener("pointerup", finishListDrag, { once: true });
  window.addEventListener("pointercancel", cancelListDrag, { once: true });
}

function updateListDrag(event) {
  if (!listDrag || event.pointerId !== listDrag.pointerId) return;
  const target = document.elementFromPoint(event.clientX, event.clientY)?.closest("[data-stop-id]");
  document.querySelectorAll(".stop-card.is-drag-target").forEach((card) => {
    card.classList.remove("is-drag-target", "drop-after");
  });
  if (!target) return;
  const bounds = target.getBoundingClientRect();
  listDrag.targetId = Number(target.dataset.stopId);
  listDrag.after = event.clientY > bounds.top + bounds.height / 2;
  target.classList.add("is-drag-target");
  target.classList.toggle("drop-after", listDrag.after);
}

function finishListDrag(event) {
  if (!listDrag || event.pointerId !== listDrag.pointerId) return;
  const { stopId, targetId, after } = listDrag;
  cleanupListDrag();
  if (stopId === targetId) return;
  const fromIndex = stops.findIndex((stop) => stop.id === stopId);
  let targetIndex = stops.findIndex((stop) => stop.id === targetId);
  if (fromIndex === -1 || targetIndex === -1) return;
  recordRouteChange();
  const [moved] = stops.splice(fromIndex, 1);
  targetIndex = stops.findIndex((stop) => stop.id === targetId);
  stops.splice(targetIndex + (after ? 1 : 0), 0, moved);
  clearShapingPoints();
  renderStops();
  routeStops(false);
}

function cancelListDrag() {
  cleanupListDrag();
}

function cleanupListDrag() {
  listDrag?.handle.releasePointerCapture?.(listDrag.pointerId);
  listDrag = null;
  window.removeEventListener("pointermove", updateListDrag);
  window.removeEventListener("pointerup", finishListDrag);
  window.removeEventListener("pointercancel", cancelListDrag);
  document.body.classList.remove("is-reordering-stops");
  document.querySelectorAll(".stop-card.is-dragging, .stop-card.is-drag-target").forEach((card) => {
    card.classList.remove("is-dragging", "is-drag-target", "drop-after");
  });
}

function clearRoute() {
  if (stops.length === 0) return;
  if (!window.confirm("Remove every stop from this route?")) return;
  recordRouteChange();
  routeRequest?.abort();
  stops.forEach((stop) => stop.marker.remove());
  stops = [];
  clearShapingPoints();
  routeCoordinates = [];
  routeLegGeometries = [];
  routedControls = [];
  renderStops();
  setSummary();
  setStatus("Add at least two stops to generate a route.");
}

function resetRouteAdjustments() {
  if (shapingPoints.length === 0) return;
  recordRouteChange();
  clearShapingPoints();
  renderStops();
  routeStops(false);
}

function routeStateSnapshot() {
  return {
    stops: stops.map(({ id, longitude, latitude, name }) => ({
      id,
      longitude,
      latitude,
      name,
    })),
    shapingPoints: shapingPoints.map(
      ({ id, segmentStartId, longitude, latitude }) => ({
        id,
        segmentStartId,
        longitude,
        latitude,
      }),
    ),
    routeStyle: elements.routeStyle.value,
    avoidMotorways: elements.avoidMotorways.checked,
    avoidMajorRoads: elements.avoidMajorRoads.checked,
    avoidTolls: elements.avoidTolls.checked,
    avoidFerries: elements.avoidFerries.checked,
  };
}

function recordRouteChange(snapshot = routeStateSnapshot()) {
  routeHistory.push(snapshot);
  updateHistoryButtons();
}

function undoRouteChange() {
  const state = routeHistory.undo(routeStateSnapshot());
  if (!state) return;
  applyRouteState(state);
}

function redoRouteChange() {
  const state = routeHistory.redo(routeStateSnapshot());
  if (!state) return;
  applyRouteState(state);
}

function applyRouteState(state) {
  if (routeDrag) cleanupRouteDrag();
  if (listDrag) cleanupListDrag();
  routeRequest?.abort();
  cancelRoutePreview();
  stops.forEach((stop) => stop.marker.remove());
  stops = [];
  clearShapingPoints();
  elements.routeStyle.value = state.routeStyle || "quickest";
  elements.avoidMotorways.checked = Boolean(state.avoidMotorways);
  elements.avoidMajorRoads.checked = Boolean(state.avoidMajorRoads);
  elements.avoidTolls.checked = Boolean(state.avoidTolls);
  elements.avoidFerries.checked = Boolean(state.avoidFerries);
  for (const preference of routePreferenceElements) {
    rememberPreferenceValue({ target: preference });
  }
  for (const stop of state.stops || []) {
    addStop(stop, stops.length, false, false);
  }
  for (const shape of state.shapingPoints || []) {
    createShapingPoint(shape, shapingPoints.length);
  }
  renderStops();
  routeStops(false);
  updateHistoryButtons();
}

function updateHistoryButtons() {
  elements.undoRoute.disabled = !routeHistory.canUndo;
  elements.redoRoute.disabled = !routeHistory.canRedo;
}

function clearShapingPoints() {
  routeAdjustmentPopup?.remove();
  routeAdjustmentPopup = null;
  for (const shape of shapingPoints) shape.marker?.remove();
  shapingPoints = [];
}

function rememberPreferenceValue(event) {
  event.target.dataset.previousValue =
    event.target.type === "checkbox"
      ? String(event.target.checked)
      : event.target.value;
}

function changeRoutePreference(event) {
  const previousState = routeStateSnapshot();
  const stateKey = routePreferenceStateKey(event.target);
  previousState[stateKey] =
    event.target.type === "checkbox"
      ? event.target.dataset.previousValue === "true"
      : event.target.dataset.previousValue || "quickest";
  recordRouteChange(previousState);
  rememberPreferenceValue(event);
  scheduleDraftSave();
  routeStops(false);
}

function routePreferenceStateKey(preference) {
  return {
    "route-style": "routeStyle",
    "avoid-motorways": "avoidMotorways",
    "avoid-major-roads": "avoidMajorRoads",
    "avoid-tolls": "avoidTolls",
    "avoid-ferries": "avoidFerries",
  }[preference.id];
}

async function routeStops(shouldFit = true, preserveExistingRoute = false) {
  cancelRoutePreview();
  routeRequest?.abort();
  routeRequestSequence += 1;
  const requestSequence = routeRequestSequence;
  if (!preserveExistingRoute) {
    routeCoordinates = [];
    routeLegGeometries = [];
    routedControls = [];
    setSummary();
    updateMapLines();
    updateDownloadState();
  }

  if (stops.length < 2) {
    setStatus("Add at least two stops to generate a route.");
    return;
  }

  routeRequest = new AbortController();
  setStatus("Joining your stops by road…");
  const controls = routingControls();

  try {
    const route = await requestRoadRoute(controls, routeRequest.signal);
    if (requestSequence !== routeRequestSequence) return;
    routeCoordinates = route.geometry.coordinates;
    routedControls = controls;
    routeLegGeometries =
      route.legGeometries ||
      (Array.isArray(route.legs) ? route.legs.map(legGeometry) : []);
    setSummary(route.distance, route.duration, routeBendScore(route));
    updateMapLines();
    updateDownloadState();
    const preferenceNotes = [];
    const curvePreference = {
      balanced: "Flowing-road bias",
      twisty: "Twisty-road bias",
      "very-twisty": "Very-twisty-road bias",
    }[elements.routeStyle.value];
    if (curvePreference) preferenceNotes.push(curvePreference);
    if (elements.avoidMotorways.checked) preferenceNotes.push("motorways excluded");
    if (elements.avoidMajorRoads.checked) preferenceNotes.push("major roads avoided");
    if (elements.avoidTolls.checked) preferenceNotes.push("tolls excluded");
    if (elements.avoidFerries.checked) preferenceNotes.push("ferries excluded");
    const preferenceNote = preferenceNotes.length
      ? ` ${preferenceNotes.join(", ").replace(/^./, (letter) => letter.toUpperCase())} applied.`
      : "";
    setStatus(`Road route ready.${preferenceNote} You can keep editing or download the GPX file.`);
    if (shouldFit) fitRoute();
  } catch (error) {
    if (error.name === "AbortError") return;
    if (preserveExistingRoute && routeCoordinates.length > 1) {
      setStatus("Your saved route is restored. It could not be refreshed from the road router yet.");
    } else {
      setStatus(
        "The road route could not be generated. Move a stop nearer a road or turn off one of the avoidances and try again.",
        true,
      );
    }
  }
}

function requestRoadRoute(controls, signal) {
  if (
    elements.avoidMotorways.checked ||
    elements.avoidMajorRoads.checked ||
    elements.avoidTolls.checked ||
    elements.avoidFerries.checked
  ) {
    return fetchMotorcycleRoute(controls, signal);
  }
  const coordinates = controls
    .map((control) => `${control.longitude.toFixed(6)},${control.latitude.toFixed(6)}`)
    .join(";");
  const url = new URL(`/route/v1/driving/${coordinates}`, ROUTING_URL);
  url.searchParams.set("overview", "full");
  url.searchParams.set("geometries", "geojson");
  url.searchParams.set("steps", "true");
  if (elements.routeStyle.value !== "quickest") {
    url.searchParams.set("alternatives", "3");
  }
  return fetchOsrmRoute(url, signal);
}

async function fetchOsrmRoute(url, signal) {
  const response = await fetch(url, {
    headers: { Accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error(`Routing failed (${response.status}).`);
  const data = await response.json();
  const route = chooseRoadRoute(data?.routes, elements.routeStyle.value);
  if (data?.code !== "Ok" || !Array.isArray(route?.geometry?.coordinates)) {
    throw new Error(data?.message || "No road route was found for those stops.");
  }
  return route;
}

async function fetchMotorcycleRoute(controls, signal) {
  const costingOptions = motorcycleCostingOptions({
    routeStyle: elements.routeStyle.value,
    avoidMajorRoads: elements.avoidMajorRoads.checked,
    avoidMotorways: elements.avoidMotorways.checked,
    avoidTolls: elements.avoidTolls.checked,
    avoidFerries: elements.avoidFerries.checked,
  });
  const routingRequest = {
    locations: controls.map((control) => ({
      lat: control.latitude,
      lon: control.longitude,
      type: "break",
    })),
    costing: "motorcycle",
    costing_options: { motorcycle: costingOptions },
    units: "kilometers",
    directions_options: { units: "kilometers" },
  };
  const url = new URL(MOTORCYCLE_ROUTING_URL);
  url.searchParams.set("json", JSON.stringify(routingRequest));
  const response = await fetch(url, {
    headers: { Accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error(`Routing failed (${response.status}).`);
  const data = await response.json();
  const trip = data?.trip;
  const legGeometries = (trip?.legs || []).map((leg) => decodePolyline(leg.shape));
  const coordinates = legGeometries.flatMap((leg, index) =>
    index === 0 ? leg : leg.slice(1),
  );
  if (coordinates.length < 2) {
    throw new Error(data?.error || "No road route was found for those stops.");
  }
  return {
    geometry: { coordinates },
    legGeometries,
    distance: Number(trip?.summary?.length) * 1000,
    duration: Number(trip?.summary?.time),
  };
}

function updateMapLines(draftControls = routingControls()) {
  if (!map.getSource("route-draft") || !map.getSource("road-route")) return;
  const draft = draftControls.map((control) => [control.longitude, control.latitude]);
  map.getSource("route-draft")?.setData(lineData(draft));
  map.getSource("road-route")?.setData(lineData(routeCoordinates));
  if (routeCoordinates !== crossingArrowRoute) {
    crossingArrowRoute = routeCoordinates;
    const crossingArrows = routeSelfCrossingArrows(routeCoordinates).map(
      (arrow) => ({
        coordinate: arrow.coordinate,
        properties: { bearing: arrow.bearing },
      }),
    );
    map.getSource("route-crossing-arrows")?.setData(pointData(crossingArrows));
  }
}

function setSummary(distance, duration, bendScore) {
  routeDistance = Number.isFinite(distance) && distance >= 0 ? distance : null;
  routeDuration = Number.isFinite(duration) && duration >= 0 ? duration : null;
  routeBendScoreValue =
    Number.isFinite(bendScore) && bendScore >= 0 ? bendScore : null;
  elements.distance.textContent = formatDistance(distance);
  elements.duration.textContent = formatDuration(duration);
  elements.twistiness.textContent = formatRouteBendScore(bendScore);
  scheduleDraftSave();
}

function setStatus(message, isError = false) {
  elements.status.textContent = message;
  elements.status.classList.toggle("is-error", isError);
}

function updateDownloadState() {
  elements.download.disabled =
    !elements.rideName.value.trim() || stops.length < 2 || routeCoordinates.length < 2;
}

function downloadGpx() {
  try {
    const rideName = elements.rideName.value.trim();
    const gpx = buildGpx({ rideName, stops, routeCoordinates, createdAt: new Date() });
    const blob = new Blob([gpx], { type: "application/gpx+xml;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = gpxFileName(rideName);
    document.body.append(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    setStatus(`${link.download} downloaded and ready to import into the app.`);
  } catch (error) {
    setStatus(error.message || "The GPX file could not be created.", true);
  }
}

async function searchPlaces(event) {
  event.preventDefault();
  const query = elements.placeQuery.value.trim();
  if (query.length < 2) {
    renderSearchMessage("Enter at least two characters.");
    return;
  }

  const catalogResults = searchBikerPlaces(query);
  if (catalogResults.length > 0) {
    renderSearchResults(catalogResults);
    return;
  }

  const normalisedQuery = normalizePlaceQuery(query);

  const cached = getCachedSearch(normalisedQuery);
  if (cached) {
    renderSearchResults(cached);
    return;
  }
  if (Date.now() - lastSearchAt < 1000) {
    renderSearchMessage("Please wait a moment before searching again.");
    return;
  }

  searchRequest?.abort();
  searchRequest = new AbortController();
  lastSearchAt = Date.now();
  renderSearchMessage("Searching…");
  const url = new URL(SEARCH_URL);
  url.searchParams.set("q", query);
  url.searchParams.set("format", "jsonv2");
  url.searchParams.set("limit", "5");
  url.searchParams.set("addressdetails", "0");
  url.searchParams.set("email", "privacy@tailendcharlie.app");
  url.searchParams.set("accept-language", document.documentElement.lang || "en-GB");

  try {
    const response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: searchRequest.signal,
    });
    if (!response.ok) throw new Error("Search is unavailable.");
    const data = await response.json();
    const results = Array.isArray(data)
      ? data
          .map((result) => ({
            latitude: Number(result.lat),
            longitude: Number(result.lon),
            name: String(
              result.name || result.display_name?.split(",")[0] || "Search result",
            ),
            address: String(result.display_name || ""),
          }))
          .filter((result) => isCoordinate(result.longitude, result.latitude))
      : [];
    cacheSearch(normalisedQuery, results);
    renderSearchResults(results);
  } catch (error) {
    if (error.name === "AbortError") return;
    renderSearchMessage("Place search is unavailable. You can still tap the map.");
  }
}

function renderSearchResults(results) {
  elements.searchResults.replaceChildren();
  if (results.length === 0) {
    renderSearchMessage("No places found. Try a town, postcode or landmark.");
    return;
  }
  for (const result of results) {
    elements.searchResults.append(createPlaceResultButton(result));
  }
  const attribution = document.createElement("div");
  attribution.className = "search-attribution";
  attribution.innerHTML =
    'General search uses <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a>. Biker venues are authorised from the <a href="https://www.google.com/maps/d/viewer?mid=1N4Oey1CiDFqn2vJuqrgnT4oQhTvyxqU" target="_blank" rel="noreferrer">Bike + Brew 2026 map</a> and checked against its <a href="https://ukbikercafes.co.uk/bike-and-brew-list/" target="_blank" rel="noreferrer">current directory</a>.';
  elements.searchResults.append(attribution);
}

function createPlaceResultButton(result, metric = "") {
  const button = document.createElement("button");
  button.className = "search-result";
  button.type = "button";
  const title = document.createElement("strong");
  title.textContent = result.name;
  const address = document.createElement("span");
  address.textContent = result.address || "";
  button.append(title, address);
  if (result.catalog) {
    const badge = document.createElement("small");
    badge.textContent = bikerPlaceLabel(result);
    button.prepend(badge);
  }
  if (metric) {
    const metricElement = document.createElement("span");
    metricElement.className = "catalog-result-metric";
    metricElement.textContent = metric;
    button.append(metricElement);
  }
  button.addEventListener("click", async () => {
    button.disabled = true;
    try {
      await selectSearchResult(result);
    } finally {
      button.disabled = false;
    }
  });
  return button;
}

function toggleBikerBrowser() {
  if (!elements.bikerBrowser.open) return;
  updateBikerSortAvailability();
  renderBikerCatalog();
  if (stops.length === 0) fitBikerPlaces();
}

function updateBikerSortAvailability() {
  const hasStart = stops.length > 0;
  for (const option of elements.bikerSort.options) {
    if (["distance", "duration"].includes(option.value)) option.disabled = !hasStart;
  }
  if (!hasStart && elements.bikerSort.value !== "alphabetical") {
    elements.bikerSort.value = "alphabetical";
  }
}

function renderBikerCatalog() {
  const query = elements.bikerFilter.value.trim();
  const start = stops[0] || null;
  const mode = start ? elements.bikerSort.value : "alphabetical";
  const matches = searchBikerPlaces(query, BIKER_PLACES.length);
  const startKey = start
    ? `${start.longitude.toFixed(5)},${start.latitude.toFixed(5)}`
    : "";
  const durations = catalogTravelTimes.startKey === startKey
    ? catalogTravelTimes.durations
    : new Map();
  const sorted = sortBikerPlaces(
    matches,
    mode,
    start,
    durations,
  );
  elements.bikerCatalogResults.replaceChildren();

  for (const place of sorted) {
    let metric = "";
    if (mode === "distance") {
      metric = `${formatDistance(distanceBetweenPlaces(start, place))} from start`;
    } else if (mode === "duration") {
      const duration = durations.get(bikerPlaceKey(place));
      metric = Number.isFinite(duration)
        ? `${formatDuration(duration)} from start by road`
        : "Road time unavailable";
    }
    elements.bikerCatalogResults.append(
      createPlaceResultButton({ ...place, catalog: true }, metric),
    );
  }

  const placeWord = sorted.length === 1 ? "place" : "places";
  const startHelp = start
    ? mode === "duration"
      ? " Times use the quickest standard road route."
      : ""
    : " Add a start point to enable distance and ride-time sorting.";
  elements.bikerCatalogStatus.textContent = `${sorted.length} ${placeWord}.${startHelp}`;
}

async function changeBikerSort() {
  renderBikerCatalog();
  if (elements.bikerSort.value !== "duration" || stops.length === 0) return;
  await loadCatalogTravelTimes(stops[0]);
}

async function loadCatalogTravelTimes(start) {
  const startKey = `${start.longitude.toFixed(5)},${start.latitude.toFixed(5)}`;
  if (catalogTravelTimes.startKey === startKey) {
    renderBikerCatalog();
    return;
  }

  catalogTravelTimeRequest?.abort();
  catalogTravelTimeRequest = new AbortController();
  const signal = catalogTravelTimeRequest.signal;
  const sequence = ++catalogTravelTimeSequence;
  elements.bikerCatalogStatus.textContent = "Calculating road times from your start…";
  const batches = [];
  for (let index = 0; index < BIKER_PLACES.length; index += CATALOG_TABLE_BATCH_SIZE) {
    batches.push(BIKER_PLACES.slice(index, index + CATALOG_TABLE_BATCH_SIZE));
  }

  const results = await Promise.allSettled(
    batches.map(async (batch) => {
      const coordinates = [start, ...batch]
        .map((place) => `${place.longitude.toFixed(6)},${place.latitude.toFixed(6)}`)
        .join(";");
      const url = new URL(`/table/v1/driving/${coordinates}`, ROUTING_URL);
      url.searchParams.set("sources", "0");
      url.searchParams.set(
        "destinations",
        batch.map((_place, index) => String(index + 1)).join(";"),
      );
      url.searchParams.set("annotations", "duration");
      const response = await fetch(url, { headers: { Accept: "application/json" }, signal });
      if (!response.ok) throw new Error(`Travel-time lookup failed (${response.status}).`);
      const data = await response.json();
      if (data?.code !== "Ok" || !Array.isArray(data?.durations?.[0])) {
        throw new Error(data?.message || "Travel-time lookup returned no durations.");
      }
      return batch.map((place, index) => [bikerPlaceKey(place), data.durations[0][index]]);
    }),
  );

  if (signal.aborted || sequence !== catalogTravelTimeSequence) return;
  const durations = new Map();
  for (const result of results) {
    if (result.status !== "fulfilled") continue;
    for (const [key, duration] of result.value) {
      if (Number.isFinite(duration)) durations.set(key, duration);
    }
  }
  catalogTravelTimes = { startKey, durations };
  renderBikerCatalog();
  if (durations.size < BIKER_PLACES.length) {
    elements.bikerCatalogStatus.textContent += ` Road time was unavailable for ${BIKER_PLACES.length - durations.size}.`;
  }
}

async function selectSearchResult(result) {
  let selected = result;
  if (!isCoordinate(result.longitude, result.latitude)) {
    renderSearchMessage(`Locating ${result.name}…`);
    const waitMilliseconds = Math.max(0, 1000 - (Date.now() - lastSearchAt));
    if (waitMilliseconds > 0) {
      await new Promise((resolve) => window.setTimeout(resolve, waitMilliseconds));
    }
    lastSearchAt = Date.now();
    const url = new URL(SEARCH_URL);
    url.searchParams.set("q", result.address || result.name);
    url.searchParams.set("format", "jsonv2");
    url.searchParams.set("limit", "1");
    url.searchParams.set("email", "privacy@tailendcharlie.app");
    url.searchParams.set("accept-language", document.documentElement.lang || "en-GB");

    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error("Location lookup failed.");
      const [match] = await response.json();
      selected = {
        name: result.name,
        address: result.address,
        latitude: Number(match?.lat),
        longitude: Number(match?.lon),
      };
    } catch {
      renderSearchMessage(
        `We could not place ${result.name} on the map. Try its postcode or tap the map.`,
      );
      return;
    }
  }

  if (!isCoordinate(selected.longitude, selected.latitude)) {
    renderSearchMessage(
      `We could not place ${result.name} on the map. Try its postcode or tap the map.`,
    );
    return;
  }
  addStop(selected);
  elements.searchResults.replaceChildren();
  elements.placeQuery.value = "";
  map.flyTo({ center: [selected.longitude, selected.latitude], zoom: 13 });
}

function renderSearchMessage(message) {
  elements.searchResults.replaceChildren();
  const paragraph = document.createElement("p");
  paragraph.className = "search-message";
  paragraph.textContent = message;
  elements.searchResults.append(paragraph);
}

function showBikerPlacePopup(feature) {
  const place = BIKER_PLACES[Number(feature.properties.index)];
  if (!place) return;
  bikerPlacePopup?.remove();
  const content = document.createElement("div");
  content.className = "biker-place-popup-content";
  const label = document.createElement("span");
  label.textContent = bikerPlaceLabel(place);
  const title = document.createElement("strong");
  title.textContent = place.name;
  const address = document.createElement("p");
  address.textContent = place.address;
  const addButton = document.createElement("button");
  addButton.type = "button";
  addButton.textContent = "Add to route";
  addButton.addEventListener("click", (event) => {
    event.stopPropagation();
    addStop(place);
    bikerPlacePopup?.remove();
  });
  content.append(label, title, address);
  if (place.sourceUrl) {
    const sourceLink = document.createElement("a");
    sourceLink.href = place.sourceUrl;
    sourceLink.target = "_blank";
    sourceLink.rel = "noreferrer";
    sourceLink.textContent = "Check venue details";
    content.append(sourceLink);
  }
  content.append(addButton);
  bikerPlacePopup = new maplibregl.Popup({
    className: "biker-place-popup",
    offset: 12,
    maxWidth: "280px",
  })
    .setLngLat(feature.geometry.coordinates)
    .setDOMContent(content)
    .addTo(map);
}

function fitBikerPlaces() {
  if (!map.getSource("biker-places")) return;
  const bounds = BIKER_PLACES.reduce(
    (current, place) => current.extend([place.longitude, place.latitude]),
    new maplibregl.LngLatBounds(),
  );
  map.fitBounds(bounds, { padding: 60, maxZoom: 8, duration: 700 });
}

function changeBikerLayerVisibility(event) {
  const visible = event.target.checked;
  elements.bikerLayerVisible.checked = visible;
  elements.bikerLayerVisibleMenu.checked = visible;
  updateBikerLayerVisibility();
}

function updateBikerLayerVisibility() {
  const visibility = elements.bikerLayerVisible.checked ? "visible" : "none";
  elements.bikerLayerVisibleMenu.checked = elements.bikerLayerVisible.checked;
  for (const layerId of [
    "biker-place-clusters",
    "biker-place-cluster-count",
    "biker-place-dots",
  ]) {
    if (map.getLayer(layerId)) map.setLayoutProperty(layerId, "visibility", visibility);
  }
  if (visibility === "none") bikerPlacePopup?.remove();
  scheduleDraftSave();
}

function bikerPlaceLabel(place) {
  if (place.category === "start" || /car park/i.test(place.name)) return "Common start";
  if (place.source === "Bike + Brew Passport 2026") return "Bike + Brew 2026";
  return place.passportNumber
    ? `Bike + Brew #${place.passportNumber}`
    : "Biker café";
}

function scheduleDraftSave() {
  if (restoringDraft || routeDrag) return;
  window.clearTimeout(draftSaveTimer);
  draftSaveTimer = window.setTimeout(savePlannerDraft, 180);
}

function savePlannerDraft() {
  if (restoringDraft || routeDrag) return;
  try {
    localStorage.setItem(
      PLANNER_DRAFT_KEY,
      encodePlannerDraft({
        ...routeStateSnapshot(),
        rideName: elements.rideName.value,
        routeCoordinates,
        routeDistance,
        routeDuration,
        routeBendScore: routeBendScoreValue,
        bikerLayerVisible: elements.bikerLayerVisible.checked,
      }),
    );
  } catch {
    elements.draftSaveStatus.textContent = "Local saving is unavailable in this browser.";
  }
}

function restorePlannerDraft() {
  let draft;
  try {
    const savedDraft = localStorage.getItem(PLANNER_DRAFT_KEY);
    draft = decodePlannerDraft(savedDraft);
    if (savedDraft && !draft) localStorage.removeItem(PLANNER_DRAFT_KEY);
  } catch {
    return;
  }
  if (!draft) return;

  restoringDraft = true;
  elements.rideName.value = draft.rideName;
  elements.routeStyle.value = draft.routeStyle;
  elements.avoidMotorways.checked = draft.avoidMotorways;
  elements.avoidMajorRoads.checked = draft.avoidMajorRoads;
  elements.avoidTolls.checked = draft.avoidTolls;
  elements.avoidFerries.checked = draft.avoidFerries;
  elements.bikerLayerVisible.checked = draft.bikerLayerVisible;
  elements.bikerLayerVisibleMenu.checked = draft.bikerLayerVisible;
  for (const preference of routePreferenceElements) {
    rememberPreferenceValue({ target: preference });
  }
  for (const stop of draft.stops) addStop(stop, stops.length, false, false);
  for (const shape of draft.shapingPoints) {
    createShapingPoint(shape, shapingPoints.length);
  }
  routeCoordinates = draft.routeCoordinates;
  routedControls = routingControls();
  routeDistance = draft.routeDistance;
  routeDuration = draft.routeDuration;
  routeBendScoreValue =
    draft.routeBendScore ??
    (routeCoordinates.length > 1
      ? routeBendScore({
          geometry: { coordinates: routeCoordinates },
          distance: routeDistance,
        })
      : null);
  setSummary(routeDistance, routeDuration, routeBendScoreValue);
  updateBikerLayerVisibility();
  updateMapLines();
  updateDownloadState();
  updateBikerSortAvailability();
  restoringDraft = false;

  if (routeCoordinates.length > 1) {
    setStatus("Your saved route has been restored.");
    fitRoute();
    if (stops.length > 1) void routeStops(false, true);
  } else if (stops.length > 1) {
    void routeStops();
  } else if (stops.length === 1) {
    map.flyTo({ center: [stops[0].longitude, stops[0].latitude], zoom: 11 });
    setStatus("Your saved start point has been restored.");
  }
}

function clearSavedPlannerData() {
  if (!window.confirm("Clear this saved route, preferences and cached place searches?")) {
    return;
  }
  window.clearTimeout(draftSaveTimer);
  try {
    localStorage.removeItem(PLANNER_DRAFT_KEY);
    localStorage.removeItem(SEARCH_CACHE_KEY);
  } finally {
    window.location.reload();
  }
}

function getCachedSearch(query) {
  try {
    const cache = JSON.parse(localStorage.getItem(SEARCH_CACHE_KEY) || "{}");
    const entry = cache[query.toLowerCase()];
    return entry && Date.now() - entry.savedAt < SEARCH_CACHE_MAX_AGE
      ? entry.results
      : null;
  } catch {
    return null;
  }
}

function pruneSearchCache() {
  try {
    const cache = JSON.parse(localStorage.getItem(SEARCH_CACHE_KEY) || "{}");
    const current = Object.fromEntries(
      Object.entries(cache).filter(
        ([, entry]) => Date.now() - entry.savedAt < SEARCH_CACHE_MAX_AGE,
      ),
    );
    if (Object.keys(current).length === 0) {
      localStorage.removeItem(SEARCH_CACHE_KEY);
    } else if (Object.keys(current).length !== Object.keys(cache).length) {
      localStorage.setItem(SEARCH_CACHE_KEY, JSON.stringify(current));
    }
  } catch {
    try {
      localStorage.removeItem(SEARCH_CACHE_KEY);
    } catch {
      // Place search still works when browser storage is unavailable.
    }
  }
}

function cacheSearch(query, results) {
  try {
    const cache = JSON.parse(localStorage.getItem(SEARCH_CACHE_KEY) || "{}");
    const entries = Object.entries(cache)
      .filter(([, entry]) => Date.now() - entry.savedAt < SEARCH_CACHE_MAX_AGE)
      .slice(-19);
    localStorage.setItem(
      SEARCH_CACHE_KEY,
      JSON.stringify({
        ...Object.fromEntries(entries),
        [query.toLowerCase()]: { savedAt: Date.now(), results },
      }),
    );
  } catch {
    // Search still works when storage is unavailable or full.
  }
}

function routingControls() {
  const controls = [];
  for (let stopIndex = 0; stopIndex < stops.length; stopIndex += 1) {
    const stop = stops[stopIndex];
    controls.push({
      id: stop.id,
      kind: "stop",
      longitude: stop.longitude,
      latitude: stop.latitude,
    });
    if (stopIndex === stops.length - 1) continue;
    for (const shape of shapingPoints) {
      if (shape.segmentStartId !== stop.id) continue;
      controls.push({ ...shape, kind: "shape" });
    }
  }
  return controls;
}

function legGeometry(leg) {
  const coordinates = [];
  for (const step of leg?.steps || []) {
    for (const coordinate of step?.geometry?.coordinates || []) {
      const previous = coordinates.at(-1);
      if (!previous || previous[0] !== coordinate[0] || previous[1] !== coordinate[1]) {
        coordinates.push(coordinate);
      }
    }
  }
  return coordinates;
}

function closestRouteLeg(lngLat, maximumDistancePixels = Number.POSITIVE_INFINITY) {
  if (!lngLat || routeLegGeometries.length === 0) return -1;
  const target = map.project(lngLat);
  let closestIndex = -1;
  let closestDistance = Number.POSITIVE_INFINITY;
  routeLegGeometries.forEach((coordinates, legIndex) => {
    for (let index = 1; index < coordinates.length; index += 1) {
      const distance = squaredPointToSegmentDistance(
        target,
        map.project(coordinates[index - 1]),
        map.project(coordinates[index]),
      );
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = legIndex;
      }
    }
  });
  return closestDistance <= maximumDistancePixels ** 2 ? closestIndex : -1;
}

function squaredPointToSegmentDistance(point, start, end) {
  const deltaX = end.x - start.x;
  const deltaY = end.y - start.y;
  if (deltaX === 0 && deltaY === 0) {
    return (point.x - start.x) ** 2 + (point.y - start.y) ** 2;
  }
  const position = Math.max(
    0,
    Math.min(
      1,
      ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) /
        (deltaX ** 2 + deltaY ** 2),
    ),
  );
  const projectedX = start.x + position * deltaX;
  const projectedY = start.y + position * deltaY;
  return (point.x - projectedX) ** 2 + (point.y - projectedY) ** 2;
}

function insertStopOnRoute(lngLat) {
  const legIndex = closestRouteLeg(lngLat);
  if (legIndex < 0) return;
  const startControl = routedControls[legIndex];
  if (!startControl) return;
  const segmentStartId =
    startControl.kind === "stop" ? startControl.id : startControl.segmentStartId;
  const stopIndex = stops.findIndex((stop) => stop.id === segmentStartId);
  if (stopIndex < 0 || stopIndex >= stops.length - 1) return;

  const afterShapes = shapesAfterControl(segmentStartId, startControl);
  addStop(
    {
      longitude: lngLat.lng,
      latitude: lngLat.lat,
      name: `Waypoint ${stopIndex + 2}`,
    },
    stopIndex + 1,
    false,
  );
  const newStop = stops[stopIndex + 1];
  for (const shape of afterShapes) shape.segmentStartId = newStop.id;
  renderStops();
  routeStops();
  focusStop(newStop.id);
}

function shapesAfterControl(segmentStartId, control) {
  const shapes = shapingPoints.filter(
    (shape) => shape.segmentStartId === segmentStartId,
  );
  if (control.kind === "stop") return shapes;
  const controlIndex = shapes.findIndex((shape) => shape.id === control.id);
  return controlIndex < 0 ? [] : shapes.slice(controlIndex + 1);
}

function installRouteDragging() {
  const canvas = map.getCanvas();
  canvas.addEventListener("pointerdown", (event) => {
    if (event.button > 0 || routeCoordinates.length < 2) return;
    const point = mapEventPoint(event, canvas);
    const startLngLat = map.unproject(point);
    const legIndex = closestRouteLeg(startLngLat, 20);
    if (legIndex < 0) return;
    routeDrag = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      legIndex,
      moved: false,
      dragPanWasEnabled: map.dragPan.isEnabled(),
      baseRouteCoordinates: routeCoordinates.map((coordinate) => [...coordinate]),
      baseDistance: elements.distance.textContent,
      baseDuration: elements.duration.textContent,
      baseDistanceValue: routeDistance,
      baseDurationValue: routeDuration,
      baseBendScoreValue: routeBendScoreValue,
      baseBendScore: elements.twistiness.textContent,
      controlsAtStart: routedControls.map((control) => ({ ...control })),
    };
    canvas.setPointerCapture?.(event.pointerId);
    map.dragPan.disable();
    canvas.classList.add("is-reshaping-route");
    window.addEventListener("pointermove", updateRouteDrag);
    window.addEventListener("pointerup", finishRouteDrag, { once: true });
    window.addEventListener("pointercancel", cancelRouteDrag, { once: true });
  });
}

function updateRouteDrag(event) {
  if (!routeDrag || event.pointerId !== routeDrag.pointerId) return;
  const distance = Math.hypot(
    event.clientX - routeDrag.startX,
    event.clientY - routeDrag.startY,
  );
  if (distance < 7) return;
  routeDrag.moved = true;
  const canvas = map.getCanvas();
  const lngLat = map.unproject(mapEventPoint(event, canvas));
  showShapePreview(lngLat);
  const startControl = routeDrag.controlsAtStart[routeDrag.legIndex];
  const segmentStartId =
    startControl.kind === "stop" ? startControl.id : startControl.segmentStartId;
  const controls = routeDrag.controlsAtStart.map((control) => ({ ...control }));
  controls.splice(routeDrag.legIndex + 1, 0, {
    id: "preview",
    kind: "shape",
    segmentStartId,
    longitude: lngLat.lng,
    latitude: lngLat.lat,
  });
  queueRoutePreview(controls);
}

function finishRouteDrag(event) {
  if (!routeDrag || event.pointerId !== routeDrag.pointerId) return;
  const completedDrag = routeDrag;
  cleanupRouteDrag(false);
  if (!completedDrag.moved) return;
  suppressNextMapClick = true;
  window.setTimeout(() => {
    suppressNextMapClick = false;
  }, 400);
  const lngLat = map.unproject(mapEventPoint(event, map.getCanvas()));
  addShapingPoint(completedDrag.legIndex, lngLat);
}

function cancelRouteDrag() {
  cleanupRouteDrag();
}

function cleanupRouteDrag(restoreRoute = true) {
  if (!routeDrag) return;
  const completedDrag = routeDrag;
  const canvas = map.getCanvas();
  canvas.releasePointerCapture?.(routeDrag.pointerId);
  if (routeDrag.dragPanWasEnabled) map.dragPan.enable();
  routeDrag = null;
  cancelRoutePreview();
  if (restoreRoute) {
    routeCoordinates = completedDrag.baseRouteCoordinates;
    routeDistance = completedDrag.baseDistanceValue;
    routeDuration = completedDrag.baseDurationValue;
    routeBendScoreValue = completedDrag.baseBendScoreValue;
    elements.distance.textContent = completedDrag.baseDistance;
    elements.duration.textContent = completedDrag.baseDuration;
    elements.twistiness.textContent = completedDrag.baseBendScore;
    updateMapLines();
  }
  canvas.classList.remove("is-reshaping-route");
  document.querySelector(".route-shape-preview")?.remove();
  window.removeEventListener("pointermove", updateRouteDrag);
  window.removeEventListener("pointerup", finishRouteDrag);
  window.removeEventListener("pointercancel", cancelRouteDrag);
}

function addShapingPoint(legIndex, lngLat) {
  const startControl = routedControls[legIndex];
  if (!startControl) return;
  recordRouteChange();
  const segmentStartId =
    startControl.kind === "stop" ? startControl.id : startControl.segmentStartId;
  let insertIndex;
  if (startControl.kind === "shape") {
    insertIndex = shapingPoints.findIndex((point) => point.id === startControl.id) + 1;
  } else {
    const index = shapingPoints.findIndex(
      (point) => point.segmentStartId === segmentStartId,
    );
    insertIndex = index < 0 ? shapingPoints.length : index;
  }
  createShapingPoint(
    {
      segmentStartId,
      longitude: lngLat.lng,
      latitude: lngLat.lat,
    },
    insertIndex,
  );
  renderStops();
  routeStops(false);
}

function createShapingPoint(
  { id: requestedId, segmentStartId, longitude, latitude },
  insertIndex,
) {
  const id = Number.isInteger(requestedId) ? requestedId : ++shapeSequence;
  shapeSequence = Math.max(shapeSequence, id);
  const markerElement = document.createElement("button");
  markerElement.className = "route-shape-marker";
  markerElement.type = "button";
  markerElement.title = "Drag to adjust this route shaping point";
  markerElement.setAttribute("aria-label", "Route adjustment. Drag to move or press Delete to remove.");
  const shape = {
    id,
    segmentStartId,
    longitude,
    latitude,
    marker: null,
  };
  const marker = new maplibregl.Marker({
    element: markerElement,
    draggable: true,
    anchor: "center",
  })
    .setLngLat([longitude, latitude])
    .addTo(map);
  shape.marker = marker;
  markerElement.addEventListener("click", (event) => {
    event.stopPropagation();
    showRouteAdjustmentPopup(shape);
  });
  markerElement.addEventListener("keydown", (event) => {
    if (!["Backspace", "Delete"].includes(event.key)) return;
    event.preventDefault();
    removeShapingPoint(shape.id);
  });
  marker.on("dragstart", () => {
    recordRouteChange();
    routeAdjustmentPopup?.remove();
  });
  marker.on("drag", () => {
    const position = marker.getLngLat();
    shape.longitude = position.lng;
    shape.latitude = position.lat;
    queueRoutePreview(routingControls());
  });
  marker.on("dragend", () => {
    cancelRoutePreview();
    routeStops(false);
  });
  shapingPoints.splice(insertIndex, 0, shape);
  return shape;
}

function showRouteAdjustmentPopup(shape) {
  routeAdjustmentPopup?.remove();
  routeAdjustmentPopup = null;
  const content = document.createElement("div");
  content.className = "route-adjustment-popup-content";
  const title = document.createElement("strong");
  title.textContent = "Route adjustment";
  const help = document.createElement("p");
  help.textContent = "Drag the purple handle to reshape the route again.";
  const removeButton = document.createElement("button");
  removeButton.type = "button";
  removeButton.textContent = "Remove adjustment";
  removeButton.addEventListener("click", (event) => {
    event.stopPropagation();
    removeShapingPoint(shape.id);
  });
  content.append(title, help, removeButton);
  routeAdjustmentPopup = new maplibregl.Popup({
    className: "route-adjustment-popup",
    offset: 12,
    maxWidth: "250px",
  })
    .setLngLat([shape.longitude, shape.latitude])
    .setDOMContent(content)
    .addTo(map);
}

function removeShapingPoint(id) {
  const index = shapingPoints.findIndex((shape) => shape.id === id);
  if (index < 0) return;
  recordRouteChange();
  routeAdjustmentPopup?.remove();
  shapingPoints[index].marker.remove();
  shapingPoints.splice(index, 1);
  renderStops();
  routeStops(false);
}

function queueRoutePreview(controls) {
  pendingPreviewControls = controls.map((control) => ({ ...control }));
  updateMapLines(pendingPreviewControls);
  const delay = Math.max(0, 1000 - (Date.now() - lastPreviewRouteAt));
  window.clearTimeout(previewRouteTimer);
  previewRouteTimer = window.setTimeout(runRoutePreview, delay);
}

async function runRoutePreview() {
  const controls = pendingPreviewControls;
  if (!controls || controls.length < 2) return;
  previewRouteRequest?.abort();
  previewRouteRequest = new AbortController();
  lastPreviewRouteAt = Date.now();
  const sequence = ++previewRouteSequence;
  try {
    const route = await requestRoadRoute(controls, previewRouteRequest.signal);
    if (sequence !== previewRouteSequence) return;
    routeCoordinates = route.geometry.coordinates;
    setSummary(route.distance, route.duration, routeBendScore(route));
    updateMapLines(controls);
  } catch (error) {
    if (error.name !== "AbortError") {
      // Keep the last valid preview while the pointer continues moving.
    }
  }
}

function cancelRoutePreview() {
  previewRouteRequest?.abort();
  previewRouteRequest = null;
  window.clearTimeout(previewRouteTimer);
  previewRouteTimer = null;
  pendingPreviewControls = null;
  previewRouteSequence += 1;
}

function showShapePreview(lngLat) {
  let preview = document.querySelector(".route-shape-preview");
  if (!preview) {
    preview = document.createElement("div");
    preview.className = "route-shape-preview";
    map.getCanvasContainer().append(preview);
  }
  const point = map.project(lngLat);
  preview.style.transform = `translate(${point.x - 8}px, ${point.y - 8}px)`;
}

function mapEventPoint(event, canvas) {
  const bounds = canvas.getBoundingClientRect();
  return { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
}

async function toggleExpandedMap() {
  const isExpanded =
    document.fullscreenElement === elements.mapShell ||
    elements.mapShell.classList.contains("is-expanded");
  if (isExpanded) {
    if (document.fullscreenElement) await document.exitFullscreen();
    setExpandedMap(false);
    return;
  }

  try {
    if (elements.mapShell.requestFullscreen) {
      await elements.mapShell.requestFullscreen();
      syncExpandedMapState();
    } else {
      setExpandedMap(true);
    }
  } catch {
    setExpandedMap(true);
  }
}

function syncExpandedMapState() {
  setExpandedMap(document.fullscreenElement === elements.mapShell);
}

function setExpandedMap(isExpanded) {
  elements.mapShell.classList.toggle("is-expanded", isExpanded);
  elements.expand.setAttribute("aria-pressed", String(isExpanded));
  elements.expand.setAttribute(
    "aria-label",
    isExpanded ? "Close full-screen map" : "Open map full screen",
  );
  elements.expandLabel.textContent = isExpanded ? "Close" : "Full screen";
  document.body.style.overflow = isExpanded ? "hidden" : "";
  window.setTimeout(() => map.resize(), 0);
}

function fitRoute() {
  if (routeCoordinates.length < 2) return;
  const bounds = routeCoordinates.reduce(
    (current, coordinate) => current.extend(coordinate),
    new maplibregl.LngLatBounds(routeCoordinates[0], routeCoordinates[0]),
  );
  map.fitBounds(bounds, { padding: 70, maxZoom: 14, duration: 700 });
}

function focusStop(id) {
  document.querySelector(`[data-stop-id="${id}"] input`)?.focus({ preventScroll: false });
}

function findStop(item) {
  return stops.find((stop) => stop.id === Number(item.dataset.stopId));
}

function cleanPlaceName(name) {
  const text = String(name || "").trim();
  return text.length > 100 ? `${text.slice(0, 97)}…` : text;
}

function isCoordinate(longitude, latitude) {
  return (
    Number.isFinite(longitude) &&
    Number.isFinite(latitude) &&
    longitude >= -180 &&
    longitude <= 180 &&
    latitude >= -90 &&
    latitude <= 90
  );
}

function escapeAttribute(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function emptyLineSource() {
  return { type: "geojson", data: lineData([]) };
}

function createRouteArrowImage(colour) {
  const canvas = document.createElement("canvas");
  canvas.width = 64;
  canvas.height = 64;
  const context = canvas.getContext("2d");
  context.fillStyle = colour;
  context.strokeStyle = "rgba(23, 24, 35, 0.9)";
  context.lineWidth = 5;
  context.lineJoin = "round";
  context.beginPath();
  context.moveTo(7, 23);
  context.lineTo(34, 23);
  context.lineTo(34, 11);
  context.lineTo(57, 32);
  context.lineTo(34, 53);
  context.lineTo(34, 41);
  context.lineTo(7, 41);
  context.closePath();
  context.stroke();
  context.fill();
  return context.getImageData(0, 0, canvas.width, canvas.height);
}

function lineData(coordinates) {
  return {
    type: "FeatureCollection",
    features:
      coordinates.length < 2
        ? []
        : [
            {
              type: "Feature",
              properties: {},
              geometry: { type: "LineString", coordinates },
            },
          ],
  };
}

function pointData(points) {
  return {
    type: "FeatureCollection",
    features: points.map((point) => ({
      type: "Feature",
      properties: point.properties || {},
      geometry: { type: "Point", coordinates: point.coordinate },
    })),
  };
}
