# Charging collector — first rollout

Refs #971, #969. The collector runs in its own container, separate from the relay
process. The operator-approved first rollout co-hosts it on the existing TEC
server with a 128 MiB memory limit and a quarter-CPU limit.
`tools/charging/collection.toml` explicitly selects 21 sources: the initial 13
with working Location samples; Allego, Blink, ChargePoint, GRIDSERVE, Osprey,
Shell and ubitricity, whose issued credentials were not tested in the initial
survey; and Evology's operator-issued feed.
The 28 October deployed audit below supersedes the initial sample status.
Believ's single-label lookup cannot
enumerate a network and is excluded. Missing environment credentials skip that
source, without anonymous retries. No additional registrations are performed.

This is partial coverage. It does not claim statutory freshness or historical
uptime. Requests are serialized, at least 125 seconds apart per origin (also
across tenants); the eight tenants of Eco-Movement's shared open-chargepoints.com
origin use 240 seconds, about 15 requests an hour, after its rate limit was hit at 125. Location and tariff sweeps share this budget. Completed sweeps
repeat no sooner than ten minutes; a page failure backs off for an hour and
does not prevent another origin from progressing. Changes of status therefore
can be delayed substantially, especially on larger networks; clients must show
observation age and must not call an old observation current availability.

GRIDSERVE and Osprey publish their whole network in one response and ignore
pagination: GRIDSERVE as a bare JSON array, Osprey as an object holding
`locations[]`. Their register entries set `pagination = "none"` and a
`response_shape` (`array` or `locations-key`; `ocpi` is the default envelope).
Such a feed is fetched once per sweep with no query string, still within the
2 MiB, 20-second and 20,000-record bounds, and that one response is a complete
sweep. Evology's operator-supplied `locations.json` is also fetched once per
sweep without query parameters, using the default OCPI envelope and its issued
`Authorization: Token` credential. Its bounded sample contained 15 UK locations;
only tariff references were provided, so its prices stay unknown. Osprey's
tariffs are not OCPI objects, so its prices stay unknown.

Otherwise each page requests 100 records, reads at most 2 MiB within a 20-second deadline,
and never follows redirects or arbitrary Link URLs. Pagination uses bounded
OCPI offset or Monta page parameters on the configured HTTPS endpoint only.
When `X-Total-Count` is present, a short page does not finish the sweep until
the reported total is reached. Offsets advance by the rows actually received.
An empty page before the total is reached fails the sweep, retains old rows and
backs off. Without a reported total, a short page still ends the sweep.
Sweeps stop at 200 pages or 20,000 records. The SQLite snapshot retains at most
20,000 locations and tariffs per source and excludes records older than 48 hours
from responses. An incomplete sweep keeps old rows and is labelled incomplete;
only a complete sweep removes records missing from that source. A failure
leaves existing observations at their original timestamps.

Only published UK locations are ingested. Connector type and status stay
associated: an available CCS socket must not imply an available Type 2 socket.
Tariffs join by source, CPO country/party and tariff ID. Only one unconditional
GBP ENERGY component with explicit VAT, no additional charges/restrictions and
no ambiguous tariff alternatives becomes pence/kWh. Everything else remains
price unknown. Tariff observations expire after 24 hours or at their stated
end time, whichever is earlier. Uptime/reliability is not inferred from a sample.

## Existing TEC server rollout

The `charging` profile in `deploy/compose.yaml` publishes no port and does not
change the public Caddy configuration. The relay alone proxies viewport queries.

1. Create `/var/lib/tailendcharlie/charging`, owned by UID/GID 1000, mode 0700.
2. Store credential variables in an owner-only file outside the checkout.
   Set `CHARGING_ENV_FILE` to that path in the private `deploy/.env`.
3. Add `charging` to `COMPOSE_PROFILES` in that environment, preserving any
   existing profiles. Deploy the reviewed commit using the normal relay deploy.
4. Inspect aggregate source outcomes and counts inside the collector; do not
   print or save location payloads. Once useful rows exist, set
   `RIDE_RELAY_CHARGING_COLLECTOR_URL=http://charging:8090/v1/chargers` and
   recreate the relay server so it advertises the capability. This exact Docker
   service URL is the only HTTP exception; arbitrary HTTP targets are rejected.
5. Verify a bounded viewport through the public relay. To roll back, empty the
   collector URL and recreate the relay, then stop the collector. Keep its data
   and credentials private. Monitor host memory and container restarts.

## Loading a credential

Never paste a credential into a chat, an issue, a command line or a file in the
checkout. From an operator's Mac with the `oracle-relay` SSH alias, run once per
variable named in `feeds.toml` (`credential_env` or `api_key_env`):

```bash
deploy/charging/put-credential.sh --recreate OCPI_FEED_GRIDSERVE_TOKEN
```

The value is typed or pasted into a hidden prompt (`--clipboard` reads and then
clears the macOS clipboard instead), travels on SSH stdin only, and replaces any
previous entry in the host's owner-only env file atomically with mode 0600. The
script prints only the variable name. `--recreate` restarts only the collector,
loading the production env file explicitly, because Docker reads `env_file` only
when a container is created. HTTP Basic variables (`*_BASIC`) take
`username:password`.

## Alternative routing-host deployment


1. On the routing host, create `$ROUTING_DATA_DIR/charging`, owned by the routing
   UID/GID. It holds the private runtime database, never repository data.
2. Put the needed credential variable names from `feeds.toml` in an owner-only
   file outside the checkout; set `CHARGING_ENV_FILE` to its path. Never place
   credentials in the app, a public PR, image or logs.
3. From the reviewed checkout on the routing host, export the same runtime
   ownership used by `routing-deploy.sh` and explicitly load the routing environment:

   ```bash
   export ROUTING_UID="$(id -u)" ROUTING_GID="$(id -g)"
   docker compose --env-file deploy/routing/.env --profile charging \
     -f deploy/routing/compose.yaml up -d --build charging
   docker compose --env-file deploy/routing/.env --profile charging \
     -f deploy/routing/compose.yaml up -d --build --force-recreate caddy
   ```

   Recreating Caddy is necessary when its bind-mounted configuration changes.
   This starts network collection; offline tests never do so. The checked-in
   profile is intentionally opt-in. Review source terms and limits before enabling.
4. Through the routing edge, request `/charging/v1/chargers` with `west`, `south`,
   `east`, `north` and `X-Client-Id: tailendcharlie.app`. Bounds must be at most
   0.8° longitude and 0.5° latitude. Responses contain at most 300 locations and
   report truncation, per-source collection outcomes, and observation timestamps.
   Queries never trigger provider requests. Do not log viewport URLs.
5. Enable the relay/app integration only after this check returns usable data.
   Stop the `charging` service to roll back collection; disable the relay
   capability to return clients to offline OSM.

The image has no published port. Caddy applies the existing client-ID gate and
an additional per-address limit. The relay will be the app-facing interface.
The identity header is abuse control, not a secret. This PR does not deploy,
create a host, upload credentials or release a mobile build.

## Connector-embedded tariffs

The collector also accepts a connector's `tariffs` object or single-object list.
It must contain one identifiable tariff, agree with any tariff reference and
explicit operator namespace, and pass the existing unconditional GBP ENERGY,
explicit VAT and expiry checks. The resulting price belongs only to that
connector; it is never inserted into the shared tariff table. Multiple, malformed
or conflicting embedded tariffs suppress price output, including fallback to a
separate tariff record. Embedded observations expire after 24 hours or their
explicit end time, whichever comes first. No raw tariff object is retained.

This format support does not enable InstaVolt collection. Its endpoint, exact
Authorization format, pagination and request budget still require verification.

## Verification

### Deployed audit — 28 October 2026

The running collector reported `ok` and recently ingested locations for 18 of
20 configured sources: Allego, Arnold Clark, Blink, char.gy, ChargePlace Scotland,
ChargePoint, Evolt, EVYVE, Fastned, GRIDSERVE, IONITY, Monta, Osprey, PoGo, Shell,
Source EV, ubitricity and Urban Fox. Several were partway through paginated
sweeps; this is evidence of collection, not complete network coverage or
two-minute status freshness. Eleven existing credential variables were present;
their values were neither logged nor copied to the repository.

The public relay advertised `charging-status-v1` and returned HTTP 200, schema
version 1, 20 source summaries and 12 locations in a bounded test viewport.
No provider requests are triggered by these viewport checks.

Fresh, conservatively usable numeric tariffs were also present for ChargePlace
Scotland, Evolt, EVYVE, Fastned, IONITY, PoGo and Urban Fox. This checks stored
tariff health, not price coverage at every connector.

Two sources were failing with no retained locations: 3ti returned non-JSON to a
local check and failed the collector's bounded fetch from the host. GeniePoint
returned HTTP 403 from the collector host, while the identical documented URL
returned HTTP 200 with 100 valid UK locations from the development Mac. These
remain provider/access failures; do not describe them as working in production.

char.gy's HTTP 200 sample returned 50 locations despite `limit=100`, with
`X-Total-Count: 6019`. The deployed code incorrectly declared that first short
page complete and retained only 50 locations. The collector fix above continues
by actual row count until the advertised total is reached. Its rollout requires
an approved collector deployment; this audit does not claim the fix or Evology
is already running.

Evology also returned HTTP 200 with 15 normalizable locations when checked from
the collector host. Its credential is staged in the existing private env file
with mode 0600; the running container has not been recreated. No key belongs in
the app, image or repository.

`python3 -m unittest discover -s tools/charging/tests` uses synthetic data and
mocked HTTP. Tests cover source isolation, rate-limit backoff, credential gates,
partial sweep retention/removal, bounds, expiry, connector status and conservative
VAT-aware tariff joins. Existing Server CI runs these and Ruff. Physical-device
and deployed-host evidence remain deployment gates, not claims of these tests.

For this change, 43 collector/register tests, 13 relay charging tests and seven
mobile charging tests passed, together with the pinned Ruff checks. Regression
tests caught mutations that (1) restored short-page completion before the total
and (2) accepted an empty page before the total. The worktree source was not
modified by the mutation run.

## Relay and mobile rollout (Refs #973)

Set `RIDE_RELAY_CHARGING_COLLECTOR_URL` to the fixed internal service URL
above, or the routing edge's HTTPS `/charging/v1/chargers` URL, only after
a usable snapshot exists. The preproduction
Compose environment uses the `PREPRODUCTION_` prefix. Empty disables both the
relay endpoint and its advertised `charging-status-v1` capability. The relay
proxies bounded viewport requests with a 2 MiB response limit and a 12-second
deadline; it does not hold provider credentials or poll operators.

With electric fuel selected, the app combines provider locations with offline
OSM chargers, including locations absent from OSM. Connector preferences filter
both pins and navigation candidates. Observations older than two minutes never
count as currently available; failed refreshes preserve their original time.
Simple verified tariffs expire after 24 hours. Unknown status and prices remain
explicitly unknown. Recently available matching connectors rank ahead of nearby
unknown or reported broken candidates; distance still matters. No historical
reliability score is implemented yet (Refs #972).

The map refreshes while the charger layer is visible; viewport caching limits
repeat requests. The detail sheet shows attribution, observation age and tariff
when known. Disabling the relay capability returns the app to offline OSM.
A reviewed deployment and a new mobile build are required before users see this.
