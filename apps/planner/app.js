(() => {
  "use strict";

  const state = {
    originalGpxText: null,
    points: [],
    selectedIndex: null,
    trimStart: null,
    trimEnd: null,
    edited: false,
  };

  const el = (id) => document.getElementById(id);

  const fileInput = el("gpx-file");
  const fileStatus = el("file-status");
  const nameInput = el("route-name");
  const editPanel = el("edit-panel");
  const generatePanel = el("generate-panel");
  const routeStats = el("route-stats");
  const preview = el("preview");
  const selectedLabel = el("selected-label");
  const btnDeletePoint = el("btn-delete-point");
  const btnMarkStart = el("btn-mark-start");
  const btnMarkEnd = el("btn-mark-end");
  const btnApplyTrim = el("btn-apply-trim");
  const btnReverse = el("btn-reverse");
  const btnReset = el("btn-reset");
  const btnGenerate = el("btn-generate");
  const generateStatus = el("generate-status");
  const codeResult = el("code-result");
  const codeValue = el("code-value");
  const btnCopyCode = el("btn-copy-code");
  const lookupCode = el("lookup-code");
  const btnLookup = el("btn-lookup");
  const lookupStatus = el("lookup-status");

  function localName(node) {
    return (node.localName || node.nodeName).toLowerCase();
  }

  function childrenNamed(parent, name) {
    return Array.from(parent.children).filter((child) => localName(child) === name);
  }

  function childText(parent, name) {
    const child = childrenNamed(parent, name)[0];
    if (!child) return null;
    const text = child.textContent.trim();
    return text.length ? text : null;
  }

  function parsePoint(node) {
    const lat = Number.parseFloat(node.getAttribute("lat"));
    const lon = Number.parseFloat(node.getAttribute("lon"));
    if (
      !Number.isFinite(lat) ||
      !Number.isFinite(lon) ||
      lat < -90 ||
      lat > 90 ||
      lon < -180 ||
      lon > 180
    ) {
      return null;
    }
    const eleText = childText(node, "ele");
    const ele = eleText !== null ? Number.parseFloat(eleText) : null;
    return { lat, lon, ele: Number.isFinite(ele) ? ele : null };
  }

  function parseGpx(text) {
    if (text.toUpperCase().includes("<!DOCTYPE")) {
      throw new Error("GPX files containing a document type declaration are not accepted.");
    }
    const doc = new DOMParser().parseFromString(text, "application/xml");
    if (doc.querySelector("parsererror")) {
      throw new Error("Invalid GPX XML.");
    }
    const root = doc.documentElement;
    if (!root || localName(root) !== "gpx") {
      throw new Error("The document root must be <gpx>.");
    }

    let name = null;
    const metadata = childrenNamed(root, "metadata")[0];
    if (metadata) name = childText(metadata, "name");

    const points = [];
    for (const track of childrenNamed(root, "trk")) {
      if (!name) name = childText(track, "name");
      for (const segment of childrenNamed(track, "trkseg")) {
        for (const pointNode of childrenNamed(segment, "trkpt")) {
          const point = parsePoint(pointNode);
          if (point) points.push(point);
        }
      }
    }
    if (points.length === 0) {
      for (const route of childrenNamed(root, "rte")) {
        if (!name) name = childText(route, "name");
        for (const pointNode of childrenNamed(route, "rtept")) {
          const point = parsePoint(pointNode);
          if (point) points.push(point);
        }
      }
    }
    if (points.length === 0) {
      for (const pointNode of childrenNamed(root, "wpt")) {
        const point = parsePoint(pointNode);
        if (point) points.push(point);
      }
    }
    if (points.length === 0) {
      throw new Error("The GPX file contains no tracks, routes, or waypoints.");
    }
    return { points, name };
  }

  function escapeXml(value) {
    const replacements = { "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" };
    return value.replace(/[<>&'"]/g, (char) => replacements[char]);
  }

  function serializeGpx(points, name) {
    const safeName = escapeXml(name || "Planned route");
    const trkpts = points
      .map((point) => {
        const ele = Number.isFinite(point.ele) ? `<ele>${point.ele}</ele>` : "";
        return `<trkpt lat="${point.lat}" lon="${point.lon}">${ele}</trkpt>`;
      })
      .join("");
    return (
      '<?xml version="1.0" encoding="UTF-8"?>' +
      '<gpx version="1.1" creator="Tail End Charlie planner">' +
      `<trk><name>${safeName}</name><trkseg>${trkpts}</trkseg></trk></gpx>`
    );
  }

  function haversineKm(a, b) {
    const earthRadiusKm = 6371;
    const dLat = ((b.lat - a.lat) * Math.PI) / 180;
    const dLon = ((b.lon - a.lon) * Math.PI) / 180;
    const lat1 = (a.lat * Math.PI) / 180;
    const lat2 = (b.lat * Math.PI) / 180;
    const sinLat = Math.sin(dLat / 2);
    const sinLon = Math.sin(dLon / 2);
    const h = sinLat * sinLat + Math.cos(lat1) * Math.cos(lat2) * sinLon * sinLon;
    return 2 * earthRadiusKm * Math.asin(Math.sqrt(h));
  }

  function totalDistanceKm(points) {
    let total = 0;
    for (let i = 1; i < points.length; i += 1) {
      total += haversineKm(points[i - 1], points[i]);
    }
    return total;
  }

  function resetSelection() {
    state.selectedIndex = null;
    state.trimStart = null;
    state.trimEnd = null;
    selectedLabel.textContent = "none";
  }

  function render() {
    routeStats.textContent = `${state.points.length} points · ${totalDistanceKm(state.points).toFixed(1)} km`;
    renderPreview();
    btnDeletePoint.disabled = state.selectedIndex === null || state.points.length <= 2;
    btnMarkStart.disabled = state.selectedIndex === null;
    btnMarkEnd.disabled = state.selectedIndex === null;
    btnApplyTrim.disabled =
      state.trimStart === null || state.trimEnd === null || state.trimStart >= state.trimEnd;
    generatePanel.hidden = state.points.length === 0;
  }

  function renderPreview() {
    const width = 600;
    const height = 400;
    const padding = 24;
    while (preview.firstChild) preview.removeChild(preview.firstChild);
    if (state.points.length === 0) return;

    const lats = state.points.map((p) => p.lat);
    const lons = state.points.map((p) => p.lon);
    const minLat = Math.min(...lats);
    const maxLat = Math.max(...lats);
    const minLon = Math.min(...lons);
    const maxLon = Math.max(...lons);
    const lonScale = Math.cos(((minLat + maxLat) / 2) * (Math.PI / 180)) || 1;
    const spanLat = Math.max(maxLat - minLat, 0.0001);
    const spanLon = Math.max((maxLon - minLon) * lonScale, 0.0001);
    const availableWidth = width - padding * 2;
    const availableHeight = height - padding * 2;
    const scale = Math.min(availableWidth / spanLon, availableHeight / spanLat);
    const xOffset = (availableWidth - spanLon * scale) / 2;
    const yOffset = (availableHeight - spanLat * scale) / 2;

    function project(point) {
      const x = padding + (point.lon - minLon) * lonScale * scale + xOffset;
      const y = height - padding - (point.lat - minLat) * scale - yOffset;
      return { x, y };
    }

    const svgNS = "http://www.w3.org/2000/svg";
    const projected = state.points.map(project);

    const polyline = document.createElementNS(svgNS, "polyline");
    polyline.setAttribute("points", projected.map((p) => `${p.x.toFixed(2)},${p.y.toFixed(2)}`).join(" "));
    polyline.setAttribute("class", "route-line");
    preview.appendChild(polyline);

    projected.forEach((p, index) => {
      const circle = document.createElementNS(svgNS, "circle");
      circle.setAttribute("cx", p.x.toFixed(2));
      circle.setAttribute("cy", p.y.toFixed(2));
      circle.setAttribute("r", "3");
      let classes = "route-point";
      if (index === state.selectedIndex) classes += " selected";
      if (index === state.trimStart || index === state.trimEnd) classes += " trim-marker";
      circle.setAttribute("class", classes);
      circle.addEventListener("click", () => {
        state.selectedIndex = index;
        selectedLabel.textContent = `point ${index + 1} of ${state.points.length}`;
        render();
      });
      preview.appendChild(circle);
    });
  }

  function loadPoints(points, name, { fromUpload } = {}) {
    state.points = points;
    state.edited = false;
    resetSelection();
    if (name && !nameInput.value) nameInput.value = name;
    editPanel.hidden = false;
    codeResult.hidden = true;
    generateStatus.textContent = "";
    render();
  }

  fileInput.addEventListener("change", () => {
    const file = fileInput.files[0];
    if (!file) return;
    fileStatus.textContent = `Reading ${file.name}…`;
    file.text().then((text) => {
      try {
        const parsed = parseGpx(text);
        state.originalGpxText = text;
        fileStatus.textContent = `Loaded ${file.name}.`;
        loadPoints(parsed.points, parsed.name, { fromUpload: true });
      } catch (error) {
        fileStatus.textContent = error.message;
        editPanel.hidden = true;
        generatePanel.hidden = true;
      }
    });
  });

  btnDeletePoint.addEventListener("click", () => {
    if (state.selectedIndex === null) return;
    state.points.splice(state.selectedIndex, 1);
    state.edited = true;
    resetSelection();
    render();
  });

  btnMarkStart.addEventListener("click", () => {
    state.trimStart = state.selectedIndex;
    render();
  });

  btnMarkEnd.addEventListener("click", () => {
    state.trimEnd = state.selectedIndex;
    render();
  });

  btnApplyTrim.addEventListener("click", () => {
    if (state.trimStart === null || state.trimEnd === null) return;
    state.points = state.points.slice(state.trimStart, state.trimEnd + 1);
    state.edited = true;
    resetSelection();
    render();
  });

  btnReverse.addEventListener("click", () => {
    state.points.reverse();
    state.edited = true;
    resetSelection();
    render();
  });

  btnReset.addEventListener("click", () => {
    if (!state.originalGpxText) return;
    const parsed = parseGpx(state.originalGpxText);
    state.points = parsed.points;
    state.edited = false;
    resetSelection();
    render();
  });

  btnGenerate.addEventListener("click", async () => {
    if (state.points.length === 0) return;
    const gpx =
      state.edited || !state.originalGpxText
        ? serializeGpx(state.points, nameInput.value.trim())
        : state.originalGpxText;
    generateStatus.dataset.tone = "";
    generateStatus.textContent = "Generating…";
    btnGenerate.disabled = true;
    try {
      const response = await fetch("/api/v1/plans", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: nameInput.value.trim() || null, gpx }),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || `Request failed (${response.status}).`);
      codeValue.textContent = body.code;
      codeResult.hidden = false;
      generateStatus.textContent = "";
    } catch (error) {
      generateStatus.dataset.tone = "error";
      generateStatus.textContent = error.message;
    } finally {
      btnGenerate.disabled = false;
    }
  });

  btnCopyCode.addEventListener("click", () => {
    navigator.clipboard?.writeText(codeValue.textContent).catch(() => {});
  });

  btnLookup.addEventListener("click", async () => {
    const code = lookupCode.value.trim().toUpperCase();
    if (!code) return;
    lookupStatus.dataset.tone = "";
    lookupStatus.textContent = "Looking up…";
    try {
      const response = await fetch(`/api/v1/plans/${encodeURIComponent(code)}`);
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || "Plan not found.");
      const parsed = parseGpx(body.gpx);
      state.originalGpxText = body.gpx;
      fileStatus.textContent = `Loaded plan ${body.code}.`;
      nameInput.value = body.name || parsed.name || "";
      loadPoints(parsed.points, null);
      lookupStatus.textContent = "Loaded. Editing this and generating again will create a new code.";
    } catch (error) {
      lookupStatus.dataset.tone = "error";
      lookupStatus.textContent = error.message;
    }
  });
})();
