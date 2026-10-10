# Internet relay

Tail End Charlie includes a deployable FastAPI/PostgreSQL store-and-forward server in
`apps/server`. The mobile client remains disabled until an absolute HTTPS API
base URL is compiled into the app:

```bash
flutter run \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.example.com/api
```

The URL cannot contain credentials, a query, or a fragment. A missing setting
causes no server traffic and is shown as **Internet relay not configured**.

## Mobile behaviour

The worker uses the same durable `RideEvent` journal as nearby delivery:

- uploads at most 20 pending events and downloads at most 100 per request;
- marks only IDs explicitly accepted by the server as acknowledged;
- persists an opaque cursor only after authenticated downloads are applied;
- verifies the ride-secret HMAC on every downloaded event before storage;
- coalesces rapid local changes into a sync at most four seconds later;
- retries network, timeout, rate-limit, and server failures automatically with
  bounded exponential backoff and jitter;
- enforces 64 KiB request, 128 KiB response, and 8 KiB event limits; and
- rejects redirects so a bearer credential cannot leave the configured HTTPS
  origin.

Before joining or synchronizing, current clients request the bounded
compatibility document:

```text
GET {base}/v1/compatibility
X-TailEndCharlie-Protocol: 1
X-TailEndCharlie-Platform: iOS|android|...
X-TailEndCharlie-App-Version: <version>
X-TailEndCharlie-App-Build: <build>
X-TailEndCharlie-Capabilities: ride-start-v1,membership-v1,route-revisions-v1,pre-start-presence-v1,push-notifications-v1
```

The server advertises its deployed Git commit, minimum/maximum protocol,
supported and required capabilities, a 30–3600 second cache interval and
platform update URLs. `serverBuildCommit: "unknown"` means the image was built
outside the documented deployment path and is not parity evidence. An old client
receives HTTP 426 `update_required`; a client newer than the server receives
HTTP 409 `server_upgrade_required`. A relay returning 404 for this endpoint is
treated as legacy protocol 1 for five minutes. Core events can still
synchronize, but capability-dependent events stay durable and local instead of
being silently misinterpreted. The cache is in memory; after an app restart, an
offline compatibility check must succeed before a new join/sync.

### Compatibility rollout and emergency cutoff

Protocol changes should be additive while the server advertises both the old
and new capability set. Validate these three contract paths before deployment:
current client/current server, a supported protocol-1 client/current server,
and current client/a legacy server that returns 404 for the compatibility
document. Deploy server support first, then the capability-gated client. Raise
`RIDE_RELAY_MINIMUM_CLIENT_PROTOCOL` only after the supported client is
available through the relevant store/TestFlight path and operators have
checked compatibility-response counts and structured 426 rates. Keep at least
one release window unless an unsafe protocol requires an emergency cutoff. For
an emergency cutoff, set the minimum protocol and platform update URLs together;
the server rejects join-code and sync state before accepting events. Do not
retire the old hostname until supported clients have received the new endpoint.

### Minimum app build and the "Update required" screen (#37)

The protocol cutoff above only moves when the wire format does, which is the
wrong tool for retiring one bad or ancient beta build. A second, finer gate
declares a **minimum app build per platform**, read from the
`x-tailendcharlie-app-build` header every store build already sends. It is **off
by default** and fails open.

What exists, end to end:

| Layer | Behaviour |
| --- | --- |
| Relay config | `RIDE_RELAY_MINIMUM_CLIENT_BUILD_IOS` and `RIDE_RELAY_MINIMUM_CLIENT_BUILD_ANDROID` (`0` = off). `deploy/compose.yaml` and `compose.preproduction.yaml` pass them through (pre-production names carry the `PREPRODUCTION_` prefix), together with `RIDE_RELAY_MINIMUM_CLIENT_PROTOCOL` and the three `*_UPDATE_URL` values, which were documented but never reached the container. |
| `GET /api/v1/compatibility` | Adds `minimumClientBuilds`, e.g. `{"iOS": 103}`, listing only the platforms whose gate is on; `{}` when off. Older apps ignore the field. |
| Join-code register and resolve, sync, presence | A readable build below its platform's minimum is refused before any ride state is read or accepted: HTTP 426, `code: update_required`, `message`, `updateUrl` (the platform's configured URL) and `minimumClientBuild`. Those first three are exactly what every shipped app parses from a 426. Counted in `ride_relay_client_update_required_total{platform,reason}` with reason `build`, `protocol` or `capability`. |
| App, at launch | `AppUpdateGateController` reads the compatibility document once. If this build is below the minimum, the home map shows an **Update required** banner and opens the **Update required** screen once per launch. |
| App, join form | A refused join shows an **Update Tail End Charlie** button that opens the same screen, instead of a bare sentence. |
| App, in a ride | The ride dashboard's relay status card says **App update required**, that SOS, alerts and navigation are not affected, and offers the update link. The full-screen explanation is never opened over a ride. |

The update link is the build's own track-aware destination - the closed-testing
opt-in page for a Play `alpha`/`beta` build, TestFlight for an iOS build - and
falls back to the relay's `updateUrl` only for a build with none of its own, so
a closed-testing tester is not sent to a store listing that will not offer them
the app.

**What the gate does not touch.** It decides what the home map says and whether
the ride service takes this build's traffic. It is not consulted by the SOS and
alert controls, navigation, route or ride recording, the ride journal or the
Nearby transport, and the screen can always be left ("Continue without
updating", or back). A refused build keeps recording: events stay in the durable
journal, are never quarantined for the refusal, and are delivered once the build
is updated or the minimum is lowered (`client_build_gate_test.dart` proves an
SOS survives a refused build and is delivered afterwards). What *does* stop is
sharing through the ride service, including SOS and alerts reaching riders
through it. The screen says so in those words, and does not claim Nearby covers
the gap.

**Fail open.** The relay judges only a readable build on a known platform: a
request with no or an unknown platform (the web watcher, curl, monitors), a
missing build header, or an `unknown`/non-integer build (an unstamped local
build) is never refused for being old. The app applies the same rule, so a local
build is not told to update. An unreachable relay, a timeout, a relay with no
compatibility document, or an app *newer* than the relay never produces an update
request, and a later failed check never takes one back.

Skew matrix (all covered by tests):

| App | Relay | Result |
| --- | --- | --- |
| current | current, gate off | Syncs. The document carries `minimumClientBuilds: {}`. |
| current, at or above the minimum | current, gate on | Syncs. |
| below the minimum | current, gate on | Update screen and banner; join, sync and presence refused with 426 before any state is accepted; local features unaffected; resumes when the build is updated or the minimum lowered. |
| current | older, no `minimumClientBuilds` | Syncs; nothing is refused. |
| current | no compatibility document (404) | Legacy protocol-1 mode, five minutes, as before. |
| builds that predate the gate (up to build 102) | current, gate on | The relay still refuses them with the 426 they already parse: the in-ride card shows **App update required** with the relay's `updateUrl`. The join form shows "Ride code service returned HTTP 426", which cannot be improved without a new binary. Set the platform update URLs to the store or TestFlight link before raising a minimum. |

**Raising a minimum** is an operator decision. In order:

1. Publish the replacement build to the platform's testers and confirm they can
   install it (store evidence on the release issue).
2. Exercise it on pre-production first: set
   `PREPRODUCTION_RIDE_RELAY_MINIMUM_CLIENT_BUILD_<PLATFORM>` above a real old
   build, recreate the pre-production server, and confirm that build shows the
   screen with the right link and that a current build is untouched.
3. Set the platform's update URL to the store or TestFlight page, then raise
   `RIDE_RELAY_MINIMUM_CLIENT_BUILD_<PLATFORM>` in `deploy/.env` and recreate the
   server. One platform at a time, and never while a ride is known to be out:
   the gate stops an in-progress ride's old builds syncing, and the app can only
   protect what is on the phone.
4. Watch `ride_relay_client_update_required_total{reason="build"}` and the
   compatibility document (`curl .../api/v1/compatibility | jq .minimumClientBuilds`).
   Apps cache the document for `cacheSeconds` (default 300), so the effect is
   gradual.
5. To undo it, set the value back to `0` and recreate the server.

Evidence still owed (#37 stays open): the screen and link on a physical old build
from TestFlight and from Play closed testing, against pre-production.

Nearby and internet acknowledgements remain separate. A server-acknowledged
event is still eligible for nearby carriage, which lets a connected phone move
events back into a group without coverage.

### Capability-gated event types

`RelayProtocolCapabilities` maps an event type to the capability that must be
advertised before it is offered for upload. When a capability is missing, the
events stay in the durable journal, the count surfaces as
`PresenceLimitation.uploadCapabilityMissing`, and the feature that owns them
raises its own named limitation. Two capabilities were added by #128:

| Capability | Event types | Retention | Limitation when absent |
| --- | --- | --- | --- |
| `tec-role-assignment-v1` | `tecRoleRequested`, `tecRoleResponded` | 2 h | `tecAssignmentUnsupportedByService`, or `tecAssignmentUnsupportedByPeer` for a named rider |
| `rejoin-route-sharing-v1` | `rejoinRouteShared` | 30 min, the same band as `riderLocationUpdated` | `rejoinSharingUnsupportedByService` |
| `ride-reopen-v1` | `rideReopened` | the ride's own retention | the resume action is hidden, and `RideReopenOutcome.relayUnsupported` says why |

`ride-reopen-v1` (#206/#207) is the leader un-ending a ride. Three things about it
are deliberate:

- `rideReopened` is **not** `rideResumed`. That one is the other half of
  `ridePaused` and means the group is moving again; conflating them would make a
  pause look like a resurrection to every reducer.
- The journal stays append-only. Nothing removes the `rideEnded` event — the later
  of the pair decides, on the client (`RideController.rideEnded`) and on the relay
  (`_ride_presence_phase`) alike.
- Reopening restores the ride's **full** retention window. The end had shortened
  `delete_after` to the grace period, and a running ride must not delete itself
  out from under the group.


`road-ratings-v1` (#159) is negotiated the same way but is not an event type — it
is a standalone endpoint with its own retention, described below.

Both are additive in the direction that matters for mixed builds: an older client
skips an unknown event type per event and keeps the rest of the batch or frame
(`describeUnsupportedRelayEvent`), so a newer peer cannot stall it. The relay's
own event-type allowlist stays closed — a type the server does not know is
rejected with HTTP 400 rather than stored — so forward compatibility is the
client's per-event skip, never a server that stores whatever it is sent.

### Anonymous road ratings

`road-ratings-v1` carries a rider's one-tap verdict on a catalogued road, asked
only after the ride has ended (#159). It is not an event type, so it is not in
the worker's event-to-capability map; it is a standalone endpoint on the
discovery API origin, negotiated through the same compatibility document.

```text
POST {discovery-origin}/api/v1/discovery/road-ratings
Content-Type: application/json
```

```json
{
  "featureId": "osm-good-biking-road-0006a6641990bc7c",
  "sourceFeatureId": "derived/osm-good-biking-road-0006a6641990bc7c",
  "category": "good_biking_road",
  "verdict": "worth_including",
  "catalogueVersion": "uk-osm-2026-07-23-v1"
}
```

That is the whole request, and the reply is `204` with no body. There is
deliberately **no** `Authorization`, no `X-Ride-Relay-Device`, and none of the
`X-TailEndCharlie-*` descriptor headers: platform, app version, build and
distribution track together fingerprint a rider better than a rider ID would,
and the relay needs none of them to count a verdict. The request schema is
`extra="forbid"`, so a client that tried to attach a rider, device, ride,
position or timestamp gets HTTP 400 rather than having it quietly stored.

The client holds each answer in its own durable store — not the ride journal and
not the completed-ride archive — and releases it after an independently drawn
delay of 30 minutes to 18 hours, one request per rating. The relay sees the
source IP of a rating and of the ride's own sync traffic, so sending at ride end
would let anyone holding the relay's logs line the two up; the delay and the
one-per-request rule remove that. Ratings therefore survive the ride being
archived or removed, which is the point: an answer outlives the ride it came
from.

Storage is a tally, not a log: primary key `(feature_id, catalogue_version,
verdict)` with a counter, and receipt recorded as a date rather than a
timestamp. There is no row that represents a single rating, so the relay cannot
attribute one even from a full database dump. The cost is no per-submitter
deduplication — one person can answer twice from two devices — bounded by an IP
rate limit and by an aggregation rule that promotes but never removes. See
[motorcycle-discovery-data.md](./motorcycle-discovery-data.md) for the rule and
`tools/discovery/road_ratings.py` for the review-side join.

When the relay does not advertise the capability, or returns 404 for the
endpoint, the answers stay durable and the card says so instead of thanking the
rider for something that went nowhere.

### Pre-start assembly presence

When a rider explicitly enables foreground location before the leader starts
the ride, a capability-gated client can exchange only that rider's latest
position:

```text
POST {base}/v1/rides/{ride-id}/presence:sync
Authorization: Bearer rr1_<derived-ride-token>
X-Ride-Relay-Device: <device-id>
X-TailEndCharlie-Capabilities: pre-start-presence-v1
```

This endpoint does not use the event journal. It replaces one in-memory
position per rider, expires positions after 45 seconds by default, and clears
the ride's cache when a `rideStarted` or `rideEnded` event is observed. These
positions therefore do not create rider tracks, route progress, ride
statistics, off-course alerts, summaries, or GPX data.

A `live-presence-v2` caller also receives `members`: the ride roster derived
from the durable membership events without consulting the caller's cursor, so a
wedged or backed-off batch sync cannot hide a participant. A rider who has left
stays in that list with `left: true` and `leftAt` (the departure's own time), and
a later `riderJoined` clears both — one identity, and a client can order a
departure against a rejoin without waiting for the batch. `leftAt` is additive:
an older client reads `left` alone, and a relay that does not report it leaves it
null. Departed members are roster history only; they are never live presence, so
they carry no position and are drawn nowhere.

The initial implementation is internet-relay-only and process-local. Run one
relay worker until the cache is moved to a shared short-lived store; otherwise
different workers can return different assembly snapshots. Nearby exchange is
a separate follow-up for groups without mobile data.

Safety contacts use separate, revocable, least-privilege management, publisher
and read-only credentials plus a sanitized last-known snapshot; they never
receive this presence response, the group invite or the event journal. See
[Safety-contact observer access](./observer-access.md).

### Background notification hints

When configured, the client registers its provider token through a separate
authenticated endpoint. Tokens never enter the ride event journal. Selected
durable events can then produce a privacy-minimised APNs/FCM hint for current,
role-relevant participants; repeated copies of the same event are
deduplicated. See [push-notifications.md](./push-notifications.md) for the
target matrix, provider configuration and real-device release gate.

## API contract

```text
POST {base}/v1/rides/{ride-id}/events:sync
Content-Type: application/json
Authorization: Bearer rr1_<base64url-HMAC-SHA256>
Idempotency-Key: rr1-<base64url-SHA256-exact-request-body>
X-Ride-Relay-Device: <device-id>
X-TailEndCharlie-Protocol: 1
X-TailEndCharlie-Capabilities: <comma-separated capabilities>
```

```json
{
  "protocolVersion": 1,
  "deviceId": "device-id",
  "cursor": null,
  "events": []
}
```

```json
{
  "protocolVersion": 1,
  "cursor": "rrc1.0.signed-value",
  "acceptedEventIds": [],
  "events": []
}
```

The bearer credential is derived locally as HMAC-SHA256 with the ride secret
over `ride-relay-internet-token-v1\n<rideId>`. The secret is stored in the iOS
Keychain or Android encrypted storage and is never sent on event-sync calls.

## Six-digit ride codes

The lead shares a six-digit numeric code and a paired high-entropy join
token, generated together at ride creation. When creating a non-simulated
ride, the app registers both as one short-lived lookup record with the
configured relay:

```text
PUT {base}/v1/join-codes/{six-digit-code}
Authorization: Bearer rr1_<derived-ride-token>
```

The request contains the ride ID, its bootstrap secret, and the join token.
The relay encrypts all three at rest and returns them only from
`GET {base}/v1/join-codes/{six-digit-code}`. Six digits alone favour roadside
usability - said aloud, texted, read off a screen - but are brute-forceable
across enough source IPs, so the lookup accepts the join token as an optional
header:

```text
GET {base}/v1/join-codes/{six-digit-code}
X-Ride-Relay-Join-Token: <join-token>
```

A request carrying the correct token is checked cryptographically and is
exempt from the six-digit code's own rate limit. A request with no token
still works - the code is still a valid, if weaker, bootstrap - but is bounded
by a second, IP-independent global rate limit across every unauthenticated
lookup on the server, so the entire keyspace cannot be enumerated quickly even
by an attacker spreading guesses across many IPs. `Share` puts both the code
and the token in one pasted invite (`123456#<token>`); the app's paste button
recognises this shape and fills in the token silently, so a rider who shares
or receives an invite through text gets the stronger path automatically.
Reading or typing the six digits alone still joins, just under the weaker,
rate-limited path. The code is a group credential either way, not a public
identifier: share it only with the intended group.

The resolved join token is also returned to whoever looked it up, so any
rider who has joined - not only the ride's creator - can go on to re-share a
fully hardened invite (the "Share ride code" action available from the ride
dashboard, not just right after creation).

## Server behaviour

The first valid request atomically claims its high-entropy ride ID for the
derived bearer token. Subsequent requests must use that credential. The server:

- stores a SHA-256 token hash for event relay, and encrypts the temporary
  bootstrap secret and join token needed to resolve a six-digit ride code
  together, comparing a supplied join token only after decrypting;
- encrypts event and idempotency-response JSON with AES-256-GCM at rest;
- signs opaque, ride-bound sequence cursors;
- accepts a valid batch atomically or returns a bounded error;
- deduplicates `(ride_id, event_id)` and rejects conflicting reuse;
- expires locations after at most 30 minutes, hazards after 24 hours, most
  other events after 72 hours, and ended rides after the configured grace;
- caps active rides and per-ride event/body storage before accepting more data;
- rate-limits by client IP and ride credential, plus a separate global limit
  on token-less ride-code lookups; and
- exposes liveness, readiness, and internal Prometheus metrics endpoints.

This is group-scoped authentication, not individual rider identity or
application-layer payload encryption. Receiving phones provide the final event
HMAC check. The protocol-2 decisions for per-device identity, member revocation,
payload encryption and migration are in
[security-threat-model.md](security-threat-model.md); implementation remains a
public-release gate.

## Run locally

```bash
cd apps/server
cp .env.example .env
uv sync --extra dev
uv run alembic upgrade head
uv run ride-relay-server
```

For TLS, PostgreSQL, scheduled cleanup, and the optional map service, follow
[server-runbook.md](./server-runbook.md). The full design and trust boundaries
are in [server-architecture.md](./server-architecture.md).
