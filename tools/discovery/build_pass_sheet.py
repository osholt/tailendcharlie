"""Render the 45 mountain-pass candidates for review, with real basemap tiles.

The first review sheet drew geometry as bare SVG on a blank card, which made it hard
to judge whether a candidate sits on a road worth riding. This one fetches raster
tiles and inlines them as data URIs, so the sheet stays a single self-contained file
with no network access at view time.

Tile fetching is deliberately modest and rate-limited: four tiles per candidate at
one zoom level, ~180 requests total, with a descriptive User-Agent. That is light
use, not bulk download.
"""

import base64
import html
import json
import os
import math
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

OUT = os.environ.get('DISCOVERY_WORK_DIR', '/private/tmp/discovery-out')
ZOOM = 13
TILE = 256
USER_AGENT = 'tailendcharlie-discovery-review/1.0 (+https://github.com/osholt/tailendcharlie)'

_cache = {}


def deg2num(lon, lat, zoom):
    lat_rad = math.radians(lat)
    n = 2.0**zoom
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n
    return x, y


def fetch_tile(z, x, y):
    key = (z, x, y)
    if key in _cache:
        return _cache[key]
    url = f'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = response.read()
    except Exception as error:
        print(f'  tile {z}/{x}/{y} failed: {error}')
        data = None
    _cache[key] = data
    time.sleep(0.05)
    return data


def tile_mosaic(lon, lat):
    """Return a 2x2 tile mosaic centred on the point, plus the marker offset."""
    fx, fy = deg2num(lon, lat, ZOOM)
    # Choose the 2x2 block that keeps the point nearest the middle.
    x0 = int(fx - 0.5)
    y0 = int(fy - 0.5)
    tiles = []
    for dy in (0, 1):
        for dx in (0, 1):
            tiles.append((x0 + dx, y0 + dy))
    marker_x = (fx - x0) * TILE
    marker_y = (fy - y0) * TILE
    return tiles, marker_x, marker_y, x0, y0


def data_uri(png):
    if png is None:
        return None
    return 'data:image/png;base64,' + base64.b64encode(png).decode('ascii')


def main():
    catalogue = json.load(open(f'{OUT}/discovery-catalogue.geojson'))
    enrichment = json.load(open(f'{OUT}/enrichment-deterministic.json'))
    overlay = json.load(open(f'{OUT}/editorial-overlay.json'))['entries']

    passes = [
        f
        for f in catalogue['features']
        if f['properties']['category'] == 'mountain_pass'
    ]

    def elevation(feature):
        try:
            return float(feature['properties'].get('sourceElevation') or 0)
        except (TypeError, ValueError):
            return 0.0

    passes.sort(key=elevation, reverse=True)

    # Warm the tile cache in parallel; the mosaics overlap between nearby passes.
    wanted = set()
    for feature in passes:
        lon, lat = feature['geometry']['coordinates']
        tiles, *_ = tile_mosaic(lon, lat)
        wanted.update(tiles)
    print(f'fetching {len(wanted)} tiles at z{ZOOM}...')
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda t: fetch_tile(ZOOM, t[0], t[1]), sorted(wanted)))
    got = sum(1 for v in _cache.values() if v)
    print(f'  {got}/{len(wanted)} tiles retrieved')

    cards = []
    for index, feature in enumerate(passes, 1):
        props = feature['properties']
        lon, lat = feature['geometry']['coordinates']
        enriched = enrichment[props['id']]
        editorial = overlay[props['id']]
        status = editorial['researchStatus']

        tiles, mx, my, x0, y0 = tile_mosaic(lon, lat)
        images = []
        for tx, ty in tiles:
            uri = data_uri(_cache.get((ZOOM, tx, ty)))
            left = (tx - x0) * TILE
            top = (ty - y0) * TILE
            if uri:
                images.append(
                    f'<image href="{uri}" x="{left}" y="{top}" '
                    f'width="{TILE}" height="{TILE}"/>'
                )

        limit = enriched['speedLimit']
        if limit['value']:
            speed = f"{limit['value']}"
            if limit['provenance'] != 'tagged':
                speed += ' <span class="prov">(inferred)</span>'
            if limit.get('mixed'):
                lo, hi = limit['range']
                speed = f'{lo}–{hi} <span class="prov">(varies)</span>'
        else:
            speed = '<span class="unknown">not mapped</span>'

        average = enriched['averageSpeedCheck']
        if average.get('present'):
            enforcement = 'Average speed check'
        elif enriched['fixedSpeedCameras']:
            enforcement = f"{enriched['fixedSpeedCameras']} fixed camera(s) nearby"
        else:
            enforcement = '<span class="unknown">none in OSM</span>'

        locality = enriched.get('locality') or {}
        peak = enriched.get('nearestPeak') or {}

        name = html.escape(editorial.get('name') or props['name'])
        badge = {
            'researched': ('ok', 'researched'),
            'pending': ('warn', 'research pending'),
            'classification-rejected': ('bad', editorial.get('verdict', 'rejected')),
        }[status]

        body = []
        if status == 'classification-rejected':
            body.append(
                f'<p class="verdict-note">{html.escape(editorial["reason"])}</p>'
            )
        elif status == 'researched':
            body.append(f'<p class="note">{html.escape(editorial["riderNote"])}</p>')
            body.append(
                '<p class="busy"><b>Busy:</b> '
                + html.escape(editorial.get('busyPeriods', '—'))
                + '</p>'
            )
            if editorial.get('enforcementNote'):
                body.append(
                    '<p class="busy"><b>Enforcement:</b> '
                    + html.escape(editorial['enforcementNote'])
                    + '</p>'
                )
            links = ' · '.join(
                f'<a href="{html.escape(u)}">{html.escape(u.split("/")[2])}</a>'
                for u in editorial.get('sources', [])
            )
            body.append(f'<p class="sources">{links}</p>')
        else:
            body.append(
                '<p class="note pending">No online cross-check yet. Name is the raw '
                'OpenStreetMap value; no rider description written.</p>'
            )

        cards.append(f"""
<article class="card {badge[0]}">
 <header>
  <span class="idx">{index}</span>
  <h2>{name}</h2>
  <span class="badge {badge[0]}">{html.escape(badge[1])}</span>
 </header>
 <div class="split">
  <svg class="map" viewBox="0 0 {TILE * 2} {TILE * 2}" width="{TILE * 2}" height="{TILE * 2}">
   {''.join(images)}
   <circle cx="{mx:.1f}" cy="{my:.1f}" r="9" class="pin-outer"/>
   <circle cx="{mx:.1f}" cy="{my:.1f}" r="4" class="pin-inner"/>
  </svg>
  <div class="facts">
   <dl>
    <dt>Elevation</dt><dd>{html.escape(str(props.get('sourceElevation') or '—'))} m</dd>
    <dt>Speed limit</dt><dd>{speed}</dd>
    <dt>Enforcement</dt><dd>{enforcement}</dd>
    <dt>Nearest place</dt><dd>{html.escape(locality.get('name', '—'))} <span class="prov">{locality.get('distanceMetres', '')}&thinsp;m</span></dd>
    <dt>Nearest peak</dt><dd>{html.escape(peak.get('name', '—'))} <span class="prov">{peak.get('elevation', '')}</span></dd>
    <dt>Roads</dt><dd>{html.escape(', '.join(enriched['roadRefs'] + enriched['roadNames']) or '—')}</dd>
    <dt>Coordinates</dt><dd class="mono">{lat:.4f}, {lon:.4f}</dd>
   </dl>
   {''.join(body)}
  </div>
 </div>
</article>""")

    researched = sum(
        1 for f in passes if overlay[f['properties']['id']]['researchStatus'] == 'researched'
    )
    rejected = sum(
        1
        for f in passes
        if overlay[f['properties']['id']]['researchStatus'] == 'classification-rejected'
    )

    document = f"""<title>Mountain pass review — {html.escape(catalogue['properties']['catalogueVersion'])}</title>
<style>
:root {{ color-scheme: light dark; --bg:#fff; --fg:#17181c; --muted:#6b7280;
  --line:#e3e5ea; --card:#fff; --ok:#0a7d3f; --warn:#9a6700; --bad:#b3261e; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#14151a; --fg:#e8eaf0;
  --muted:#9aa1ad; --line:#2a2d36; --card:#1b1d24; --ok:#4ade80; --warn:#facc15;
  --bad:#f87171; }} }}
body {{ background:var(--bg); color:var(--fg); margin:0; padding:24px;
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }}
h1 {{ font-size:22px; margin:0 0 4px; }}
.lede {{ color:var(--muted); margin:0 0 22px; max-width:70ch; }}
.tally {{ display:flex; gap:18px; flex-wrap:wrap; margin:0 0 26px;
  padding:14px 16px; border:1px solid var(--line); border-radius:10px; }}
.tally div {{ font-size:13px; color:var(--muted); }}
.tally b {{ display:block; font-size:21px; color:var(--fg); }}
.card {{ border:1px solid var(--line); border-left-width:4px; border-radius:10px;
  background:var(--card); margin:0 0 16px; overflow:hidden; }}
.card.ok {{ border-left-color:var(--ok); }}
.card.warn {{ border-left-color:var(--warn); }}
.card.bad {{ border-left-color:var(--bad); }}
header {{ display:flex; align-items:center; gap:10px; padding:12px 16px;
  border-bottom:1px solid var(--line); }}
header h2 {{ font-size:16px; margin:0; flex:1; }}
.idx {{ color:var(--muted); font-variant-numeric:tabular-nums; min-width:2ch; }}
.badge {{ font-size:11px; text-transform:uppercase; letter-spacing:.04em;
  padding:3px 8px; border-radius:999px; border:1px solid currentColor; }}
.badge.ok {{ color:var(--ok); }} .badge.warn {{ color:var(--warn); }}
.badge.bad {{ color:var(--bad); }}
.split {{ display:flex; gap:18px; padding:16px; flex-wrap:wrap; }}
.map {{ border-radius:8px; border:1px solid var(--line); flex:0 0 auto;
  max-width:100%; height:auto; background:var(--line); }}
.pin-outer {{ fill:none; stroke:#e11d48; stroke-width:3; }}
.pin-inner {{ fill:#e11d48; }}
.facts {{ flex:1 1 340px; min-width:0; }}
dl {{ display:grid; grid-template-columns:auto 1fr; gap:2px 14px; margin:0 0 12px; }}
dt {{ color:var(--muted); font-size:13px; }}
dd {{ margin:0; font-size:14px; }}
.mono {{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px; }}
.prov, .unknown {{ color:var(--muted); font-size:12px; }}
.note {{ margin:10px 0; }}
.note.pending {{ color:var(--muted); font-style:italic; }}
.verdict-note {{ margin:10px 0; color:var(--bad); }}
.busy {{ margin:6px 0; font-size:13.5px; color:var(--muted); }}
.busy b {{ color:var(--fg); }}
.sources {{ margin:10px 0 0; font-size:12px; }}
.sources a {{ color:var(--muted); }}
footer {{ margin-top:28px; padding-top:16px; border-top:1px solid var(--line);
  color:var(--muted); font-size:12.5px; }}
</style>
<h1>Mountain pass review — {html.escape(catalogue['properties']['catalogueVersion'])}</h1>
<p class="lede">All {len(passes)} <code>mountain_pass</code> candidates, highest first.
Speed limits and enforcement are derived from the OpenStreetMap extract. Names,
rider notes and busy periods are hand-researched and cited; anything not yet checked
says so rather than guessing.</p>
<div class="tally">
 <div><b>{len(passes)}</b> candidates</div>
 <div><b>{researched}</b> researched &amp; cited</div>
 <div><b>{len(passes) - researched - rejected}</b> research pending</div>
 <div><b>{rejected}</b> wrong category</div>
</div>
{''.join(cards)}
<footer>Basemap &copy; OpenStreetMap contributors, ODbL. Candidate data derived from
the {html.escape(catalogue['properties']['catalogueVersion'])} extract. Tiles are
inlined, so this file needs no network access.</footer>
"""

    path = f'{OUT}/pass-review-sheet.html'
    open(path, 'w').write(document)
    size = len(document.encode()) / 1e6
    print(f'\nwrote {path} ({size:.1f} MB)')
    print(f'  {researched} researched, {rejected} wrong category, '
          f'{len(passes) - researched - rejected} pending')


if __name__ == '__main__':
    main()
