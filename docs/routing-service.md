# Routing and geocoding service

Tracked by #917, for open-beta gate G2.1 (`open-beta-plan.md`). The operator
chose to self-host on an Oracle Cloud Always Free Ampere A1 VM rather than pay
a hosted provider.

The app and the web planner call three public demo services today, and none of
them permits production use:

- the OSRM demo server (default routing);
- FOSSGIS Valhalla (motorcycle routing, GPX import, route checks, speed limits);
- OSM Nominatim (destination search).

This service replaces Valhalla and Nominatim. OSRM is covered under
[What is not self-hosted](#what-is-not-self-hosted).

## What runs where

```
phone (X-Client-Id) / web planner (Origin)
   │ HTTPS
   ▼
Caddy, on its own A1 VM: TLS, client check, CORS, rate limits, 1 MB body cap
   ├── /valhalla/route, /sources_to_targets      → Valhalla 3.9 (motorcycle and auto costing)
   ├── /valhalla/trace_route, /trace_attributes,
   │   /locate, /status                          → Valhalla
   ├── /photon/api, /reverse, /status            → Photon 1.3
   └── /health, /health/valhalla, /health/photon (no client id needed)
```

Everything is in `deploy/routing/`:

| File | Purpose |
| --- | --- |
| `compose.yaml` | Caddy, Valhalla and Photon, with memory limits sized for 2 OCPU / 12 GB |
| `Caddyfile` | The public edge |
| `caddy/Dockerfile` | Caddy 2.11.4 plus the `caddy-ratelimit` module |
| `photon/Dockerfile` | Photon 1.3.0 on Temurin 21, with the jar pinned by SHA-256 |
| `tools/Dockerfile` | `curl` and `osmium`, to fetch and merge the extracts |
| `routing.env.example` | Every setting; copy it to `deploy/routing/.env` on the host |
| `routing-host-setup.sh` | Run once: data directory, swapfile, weekly timer |
| `routing-data-refresh.sh` | Build, test and promote new data, or roll it back |
| `routing-deploy.sh` | Deploy configuration and images from a commit on `main` |
| `routing-smoke.py` | The smoke test that every refresh and deploy runs |
| `routing-lib.sh` | Shared promotion and rollback logic, tested by `tests/routing-lib-test.sh` |

The repository is public, so it holds no host details. The hostname and data
directory live only in `deploy/routing/.env` on the host, the same way the
relay's do.

### Data

- **Valhalla.** Geofabrik extracts for Great Britain, Ireland and Northern
  Ireland, the Isle of Man and France, merged with `osmium` so that anything in
  two extracts appears once. The build makes routing tiles plus the admin and
  time-zone databases. Without the admin database, `trace_attributes` reports no
  country code, and the speed-limit sign cannot tell a UK limit from a French
  one. Elevation is not built: nothing in the app uses it.
- **Photon.** GraphHopper's weekly Europe JSON dump (13.3 GB compressed),
  streamed through `photon import -country-codes GB,IE,IM,FR` and checksummed as
  it passes. The dump is never stored.
- **Configuration changed from Valhalla's defaults:**
  - The longest route goes up from 500 km to `VALHALLA_MAX_ROUTE_KM` (1,500).
  - The slow-request log is raised out of reach. That log writes the whole
    request, which is a rider's route.
  - Nothing on the host keeps a record of requests. Caddy has no access log.
    Valhalla's container log is discarded (`driver: none`), because
    `valhalla_service` always writes each request line with its query string,
    and the app and planner send their route there. To debug Valhalla, run
    `valhalla_service` by hand on the same data.

### Refreshes

`routing-data-refresh.sh` runs weekly from `routing-data-refresh.timer`, Monday
23:00 UK time. Group rides cluster at the weekend, and the Photon dump appears
early on Monday. For each engine in turn, it:

1. Deletes every build except the one being served and the one before it, then
   checks the free space.
2. Builds into `ROUTING_DATA_DIR/<engine>/builds/<UTC stamp>/`. The build runs
   under a memory limit, so on the small shape it is the build that gets killed,
   not the engines that are serving.
3. Starts the new build on a throwaway candidate container and runs
   `routing-smoke.py` against it. The test covers routes in every country, both
   costings, `locate`, `trace_attributes` (including the country code and at
   least one speed limit), `trace_route`, and a Photon search in every country.
4. Only then moves `live` to the new build and `previous` to the old one, and
   recreates the engine. It runs the smoke test again against what is now
   serving. If that fails, it rolls straight back.

A failure at any step before 4 deletes the new build and leaves the service
exactly as it was. Promotion restarts the engine, and Caddy holds requests for
up to 10 s while it comes back. Valhalla returns in seconds. Photon takes up to
a minute, and a search in that window fails and can be retried.

## Size and cost

### Oracle's allowance has halved

Oracle's [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm)
page, read on 9 October 2026, says:

> All tenancies get the first 1,500 OCPU hours and 9,000 GB hours per month for
> free for VM instances using the VM.Standard.A1.Flex shape … For Always Free
> tenancies, this is equivalent to 2 OCPUs and 12 GB of memory.

Until mid-2026 the allowance was 3,000 OCPU hours and 18,000 GB hours (4 OCPU,
24 GB). The open-beta plan's "4 OCPU / 24 GB" predates the cut. The same page
still gives:

- **200 GB** of block volume in total, boot volumes included, with a minimum
  boot volume of 47–50 GB;
- **10 TB** of outbound data a month.

The allowance is per tenancy, so **whatever A1 capacity and block volume the
relay already uses comes out of the same totals.** The relay runbook says to
pick an Ampere shape. If the relay is a 1 OCPU / 1 GB A1, the routing VM can
have 1 OCPU / 11 GB at £0. If the relay is an AMD `VM.Standard.E2.1.Micro`, it
has its own allowance and the routing VM can have the full 2 OCPU / 12 GB.
Check before creating anything.

| Configuration | Monthly cost | Notes |
| --- | --- | --- |
| **2 OCPU / 12 GB / 150 GB boot** (the default in `routing.env.example`) | **£0** | This assumes the relay is not an A1 and that its boot volume is 50 GB or less. |
| 1 OCPU / 11 GB (beside a 1 OCPU / 1 GB A1 relay) | £0 | Set `VALHALLA_SERVER_THREADS=1` and `VALHALLA_BUILD_THREADS=1`. The weekly build takes about twice as long. Serving still fits. |
| 4 OCPU / 24 GB | about US$27 (roughly £20) | Pay As You Go only. 1,420 OCPU-h × $0.01 plus 8,520 GB-h × $0.0015 over the allowance, at Oracle's [published A1 rates](https://www.oracle.com/cloud/compute/arm/pricing/). A free-only tenancy cannot create it. |

Outbound traffic stays far inside 10 TB. A ride costs a rider perhaps 10–20 MB
of routing and speed-limit responses, so 1,000 riders doing 8 rides a month is
about 160 GB. Downloads into the VM are not charged.

Oracle may reclaim an Always Free instance that is idle for 7 days. Idle means
CPU, network and (for A1) memory all below 20 % at the 95th percentile. The
serving engines hold more than 20 % of 12 GB in memory, so this VM should not
qualify. Watch for Oracle's warning email anyway.

### Memory, disk and build time on 2 OCPU / 12 GB

**These figures are estimates**, scaled from the extract sizes on 9 October 2026
(Great Britain 2.18 GB, Ireland and Northern Ireland 0.41 GB, Isle of Man
0.006 GB, France 5.10 GB) and from the engines' published planet figures. No
build at this size has been run yet. Record the measured values on #917 after
the first build, and correct this table.

| | Valhalla | Photon |
| --- | --- | --- |
| Downloaded per refresh | 7.7 GB of PBF, deleted after the merge | 13.3 GB, streamed, never stored |
| Serving data on disk | 8–10 GB (tiles tar, admin and time-zone DBs) | 9–12 GB |
| Extra disk at the build's peak | 30–40 GB (merged PBF, intermediate files, tiles before tarring) | the size of the new index |
| Build time | 6–12 h on 2 OCPU. PBF parsing is single-threaded. | 1.5–4 h |
| Build memory | capped at `VALHALLA_BUILD_MEMORY_LIMIT` (7 GB), pages to swap past it | 3 GB heap, capped at 5 GB |
| Serving memory | 0.5–1.5 GB resident, capped at 3 GB. Tiles are memory-mapped, so the rest is reclaimable page cache. | 2 GB heap, about 3 GB resident, capped at 4 GB |

**Disk.** At the peak of a Valhalla rebuild the host holds:

- the OS and images, about 10 GB;
- three Valhalla builds (live, previous and new), about 30 GB;
- the build's intermediate files, about 40 GB;
- two Photon builds, about 24 GB.

That is roughly 100 GB, so give the VM a 150 GB boot volume. If the relay's boot
volume is 50 GB, that uses the whole 200 GB allowance.

**Memory.** At the peak the host holds:

- the serving engines, about 4.5 GB;
- one build, about 7 GB;
- the kernel and Caddy.

That is the reason for the 8 GB swapfile, and for the builds running one at a
time. A full refresh takes up to about 16 hours; the timer allows 24.

**Throughput.** On 2 OCPU this was not measured either. A short Valhalla route
takes tens of milliseconds and a cross-country one under a second. The
rate-limit defaults allow 1,200 routes and 3,000 matching calls a minute across
the whole service. Check them against the Caddy metrics once there is real
traffic.

## What the operator does

Steps 1–4 need a person at the Oracle console and the DNS provider. Steps 5–9
are on the host over SSH. Nothing here was done by an agent.

1. **Check the tenancy.** In the Oracle console, note:
   - whether the account is free-only or Pay As You Go;
   - the relay's shape (Compute → Instances);
   - every boot and block volume (Storage → Block Volumes, plus boot volumes).

   Then choose a row from the cost table above.
2. **Create the instance.** Compute → Instances → Create instance:
   - Image: Canonical Ubuntu 24.04, **aarch64**.
   - Shape: Ampere `VM.Standard.A1.Flex`, 2 OCPU and 12 GB (or what step 1
     leaves).
   - Boot volume: 150 GB, or whatever is left of the 200 GB.
   - Your SSH key, and a public IPv4 address.

   If you get "out of host capacity", try another availability domain, or try
   again later. The relay runbook says the same.
3. **Open the ports.**
   - Add ingress rules to the instance's security list or NSG for TCP 80, TCP 443
     and UDP 443, from `0.0.0.0/0`.
   - Leave TCP 22 restricted as it is for the relay.
   - Oracle's Ubuntu image also rejects these ports in `iptables`. On the host:

     ```bash
     sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
     sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
     sudo iptables -I INPUT 6 -p udp --dport 443 -j ACCEPT
     sudo netfilter-persistent save
     ```
4. **DNS.** Add an A record for the routing hostname you choose, for example
   `routing.tailendcharlie.app`, pointing at the instance's public IPv4 address.
   The website's content security policy already allows any
   `https://*.tailendcharlie.app` host. A hostname outside that domain needs
   `apps/website/_headers` changed.
5. **Docker and the checkout.**
   - Install Docker Engine and the Compose plugin, following
     [Docker's Ubuntu steps](https://docs.docker.com/engine/install/ubuntu/).
   - `sudo usermod -aG docker $USER`, then log in again.
   - `sudo git clone https://github.com/osholt/tailendcharlie /opt/tailendcharlie`
     and `sudo chown -R $USER: /opt/tailendcharlie`.
6. **Settings.**
   - `cp deploy/routing/routing.env.example deploy/routing/.env`.
   - Set `ROUTING_DOMAIN` to the hostname from step 4.
   - Leave the other values at their defaults on the 2 OCPU shape. On 1 OCPU,
     set both thread counts to 1.
7. **Host setup.** `sudo deploy/routing/routing-host-setup.sh`. It:
   - creates the data directory;
   - adds the swapfile;
   - installs and starts the weekly timer;
   - warns if `iptables` still blocks 80 or 443.
8. **First data build.** It takes most of a day, so detach it from the SSH
   session: `sudo systemctl start --no-block routing-data-refresh.service`.
   Follow it with `journalctl -fu routing-data-refresh`.
   - When it finishes, both engines are serving on the internal network and
     have each passed the smoke test twice.
   - `cat /srv/routing/state/*.refreshed` shows what is live.
9. **Deploy the edge.** `deploy/routing/routing-deploy.sh`. It:
   - builds Caddy;
   - starts all three services;
   - waits for the TLS certificate;
   - runs the full smoke test through `https://<ROUTING_DOMAIN>`, including the
     client check and the planner's CORS.

   The commit is recorded only if that test passes.

Then [verify](#verify), [cut over](#cut-the-app-over), and record the measured
build times, memory peak and disk use on #917.

The deploy refuses any commit that is not on `main`, as the relay's does. Run
step 9 after the `deploy/routing` changes have merged.

## Verify

```bash
# The edge, without a client id
curl -s https://ROUTING_HOST/health                       # {"status":"ok"}
curl -s https://ROUTING_HOST/health/valhalla | jq .version
curl -s https://ROUTING_HOST/health/photon               # {"status":"Ok",...}

# The client gate
curl -s -o /dev/null -w '%{http_code}\n' https://ROUTING_HOST/valhalla/status   # 403
curl -s -H 'X-Client-Id: tailendcharlie.app' https://ROUTING_HOST/valhalla/status | jq .available_actions

# A geocode, as the app and planner will make it
curl -s -H 'X-Client-Id: tailendcharlie.app' 'https://ROUTING_HOST/photon/api?q=Bristol&limit=3' |
  jq '.features[].properties | {name, countrycode}'

# The full smoke test, from the host
deploy/routing/routing-deploy.sh "$(cat /srv/routing/state/deploy.commit)"

# Rate-limit counters and per-route latency, host only
curl -s http://127.0.0.1:2020/metrics | grep -E 'caddy_rate_limit|caddy_http_request_duration'
```

## Cut the app over

The relay tells every app where these services are, so moving them needs no
app release. The app and the web planner read `serviceUrls` from
`/api/v1/compatibility`:

- The app keeps the last set it was given and uses it on later launches.
- When the relay advertises nothing, both fall back to the public endpoints
  they use today.
- A `--dart-define` set at build time still overrides both, for development.

This needs the relay and app change in #927, and the planner change in #929. Builds without it
keep calling the public services whatever the relay says.

1. In the relay's `deploy/.env`, add:

   ```bash
   RIDE_RELAY_SERVICE_VALHALLA_URL=https://ROUTING_HOST/valhalla
   RIDE_RELAY_SERVICE_PHOTON_URL=https://ROUTING_HOST/photon
   ```

   Leave `RIDE_RELAY_SERVICE_OSRM_URL` unset; see below.
2. Recreate the relay so it reads them. Dispatch `relay-deploy.yml` at the
   deployed commit, or run `relay-deploy.sh production <deployed commit>` on the
   relay host.
3. Check what the relay now says:

   ```bash
   curl -s https://relay.tailendcharlie.app/api/v1/compatibility | jq .serviceUrls
   ```
4. **Field check.** The apps pick up the change on their next compatibility
   check, at launch or within `cacheSeconds` (5 minutes) of a relay call, and
   the web planner on its next page load. On one phone, then check the metrics:
   - plan a route, with motorcycle preferences;
   - import a GPX;
   - watch the speed-limit sign for a few minutes while moving;
   - search for a destination.

   `caddy_http_requests_total` on the routing host should rise for `/valhalla`
   and `/photon`.
5. Tell the FOSSGIS Valhalla operators that the app no longer uses their
   instance, as `maps-and-gpx.md` committed to before any public rollout.

## Roll back

| What went wrong | Do this |
| --- | --- |
| The routing VM is down or wrong, and riders need service now | Remove the `RIDE_RELAY_SERVICE_*` lines from the relay's `.env` and recreate the relay as in step 2. Apps return to the public endpoints at their next compatibility check. This puts the whole user base back on the demo servers, so it is a stopgap for a tester-sized group only. |
| This week's data is bad (a missing region, a wrong road) | `deploy/routing/routing-data-refresh.sh rollback valhalla` (or `photon`). It swaps `live` and `previous`, recreates the engine and smoke-tests it. Running it again undoes it. |
| A configuration or image change broke the edge | `deploy/routing/routing-deploy.sh <previous commit>`. The last good commit is in `/srv/routing/state/deploy.commit` until a new deploy passes. |
| A refresh keeps failing | Nothing to roll back. A failed refresh never touches what is serving. Read `journalctl -u routing-data-refresh` and `df -h`. |

## Operating it

- **Logs:**
  - `journalctl -u routing-data-refresh` for refreshes;
  - `docker compose --env-file deploy/routing/.env -f deploy/routing/compose.yaml logs <service>`
    for the engines. Container logs are capped at 30 MB each.
- **State:** `/srv/routing/state/`:
  - `deploy.commit`: the last deploy that passed;
  - `<engine>.refreshed`: when each engine's live build was made;
  - `routing.lock`: held by a deploy or refresh, so the two never overlap.
- **Monitoring:** not yet wired up. Add `https://ROUTING_HOST/health/valhalla`
  and `/health/photon` to the operator's alerting before phase 2 of the beta.
  The relay's `relay-health.yml` is the pattern to copy. Tracked on #917.
- **Disk:** keep the data volume below 85 % full. Photon's embedded search
  engine stops allocating index shards past that watermark, so an import on a
  nearly full disk fails.
- **Upgrades:**
  - The Valhalla, Photon, Caddy and rate-limit module versions are pinned in
    `compose.yaml` and the Dockerfiles. Bump them in a pull request.
  - After a Valhalla upgrade, run a refresh. Tiles from an older version are
    not guaranteed to load.
  - Photon dumps are versioned by major release (`1.0-latest` serves 1.x).
- **Attribution:** both engines serve OpenStreetMap data under the ODbL. The app
  and planner already credit "© OpenStreetMap contributors".

## What is not self-hosted

**OSRM.** Valhalla's `auto` costing can serve every call the app makes to the
OSRM demo, so no OSRM is built here. But moving those calls changes the routes
riders get, and it needs field validation, not just configuration. The calls
are:

- routing with no motorcycle preference;
- the rejoin planner;
- the web planner's `/table` travel times.

#930 tracks that change. Until it lands, those calls stay on the
OSRM demo through the same configuration, and a relay can point them at an
OSRM-compatible host with `RIDE_RELAY_SERVICE_OSRM_URL`.

**Map tiles** stay on OpenFreeMap (`open-beta-plan.md`).

## Sources

- [Oracle: Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm),
  for the A1 allowance, block volume, outbound data and idle reclamation
- [Oracle: Ampere A1 pricing](https://www.oracle.com/cloud/compute/arm/pricing/)
- [Valhalla Docker images and settings](https://github.com/valhalla/valhalla/tree/master/docker)
- [Photon](https://github.com/komoot/photon) and its
  [usage notes](https://github.com/komoot/photon/blob/master/docs/usage.md)
  on JSON dump import and country filtering
- [GraphHopper Photon dumps](https://download1.graphhopper.com/public/)
- [Geofabrik extracts](https://download.geofabrik.de/europe.html)
- [caddy-ratelimit](https://github.com/mholt/caddy-ratelimit)
