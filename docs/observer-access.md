# Safety-contact observer access

Status: experimental MVP. Issue #36 remains open until the physical-device and
deployment evidence below is recorded.

## User boundary

A rider may explicitly create a private, read-only link for one trusted safety
contact. It follows only that phone's rider, lasts from 30 minutes to 24 hours,
and can be reviewed or revoked from that phone. It is not a group monitoring
link and does not make the viewer a ride member.

The app receives three independent 256-bit credentials:

- `om1_`: inspect or revoke the grant;
- `op1_`: replace the one minimized snapshot; and
- `ro1_`: read the snapshot.

The relay stores only hashes. The consenting phone stores all three credentials
in platform secure storage. Only the grant ID and `ro1_` credential enter the
shared URL fragment:

```text
https://tailendcharlie.app/observer.html#<grant-id>.<ro1-token>
```

Fragments are not sent in the initial HTTP request or Referer header. Page
JavaScript sends `ro1_` to the relay in `Authorization`. The shared URL never
contains the ride credential, management credential, or publisher credential.

## Data flow and minimization

The relay does not read or transform the group event journal for an observer.
The consenting app publishes a separate encrypted snapshot containing only:

- local display name;
- the local device's one last-known latitude/longitude, recorded time and
  accuracy;
- ride lifecycle: waiting, active, paused, or ended;
- an assistance or emergency-stop state set by a successful quick-message
  action on this installation; and
- component update times used to prevent stale requests rolling state back.

Speed, heading, ride ID/code, join/invite secrets, raw signed events, other
riders, trails, route/destination, markers, hazards, ICE details and medical
notes are excluded. A forged shared-journal `deviceId` therefore cannot select
another rider's position or create observer assistance.

Ride lifecycle is the local app's view of the shared ride journal. That journal
uses the group credential and is not per-device authenticated, so a malicious
ride member may be able to falsify lifecycle state. The observer page treats
lifecycle as informational and never as evidence of safety.

Every update is labelled **last known**. Freshness is unavailable, fresh (up to
90 seconds), delayed (up to five minutes), or offline. Missing updates never
imply that the rider is safe.

## Consent, restart, expiry and revocation

Creation requires an explicit disclosure checkbox. Creating a grant does not
start ride-track recording. While the app is open, an active grant may publish
foreground GPS independently of whether the ride has started.

After app restart, active grants are restored from secure storage and foreground
sampling resumes only when location permission is already granted. The resume
path never displays a permission prompt. Locked-screen/background/force-quit
continuity is not claimed until physical testing passes.

Creation uses the existing ride bearer only to prove membership and bind expiry
to the ride retention window. The shared ride credential cannot publish,
inspect, read or revoke a created grant. Per-ride caps, a tight per-ride-secret
creation limit and a much higher IP abuse ceiling bound nuisance grant creation
without letting a handful of requests block other riders behind the same
carrier NAT.

Publishing and revocation lock the same grant row. Revocation clears encrypted
snapshot state and all three credentials fail on the next request; an observer
may retain a response already received. Expired grants fail with the same
generic response and cleanup deletes their records.

## Browser and map boundary

The observer page is no-index, no-referrer, no-store and frame-denied. Its
specific CSP permits snapshot and map requests only to the Tail End Charlie
relay. It cannot use the planner's public OpenFreeMap permission. Its reviewed
MapLibre GL JS 5.24.0 executable and stylesheet are served from the same host
with the upstream MIT licence; the observer CSP permits no third-party
executable origin.

An observer map is optional. The configured style is
`<current-relay-origin>/maps/styles/ride-relay.json`; every style import,
source, tile, sprite and glyph URL must also remain on that host. The
repository does not include the operator map archive or production style, so
the page falls back to bounded coordinates until those assets pass deployment
verification. Do not claim the observer map is operational before that gate.

## API

```text
POST   /api/v1/rides/{ride-id}/observer-grants
Authorization: Bearer rr1_<ride credential>

GET    /api/v1/observer-grants/{grant-id}/management
DELETE /api/v1/observer-grants/{grant-id}/management
Authorization: Bearer om1_<management credential>

PUT    /api/v1/observer-grants/{grant-id}/snapshot
Authorization: Bearer op1_<publisher credential>

GET    /api/v1/observer-grants/{grant-id}
Authorization: Bearer ro1_<viewer credential>
```

All timestamps require an explicit timezone. Snapshot generations are
monotonic, and position, lifecycle and assistance components merge using their
own timestamps. Rapid phone samples coalesce to at most one in-flight and one
latest pending snapshot; up to four independent grants publish concurrently.

## Evidence gate

Deploy migration `0006`, then the relay, then the static observer page before a
mobile build advertises `observer-access-v1`. Record:

1. foreground, lock, background and force-quit behaviour on oldest/current iOS
   and representative stock/aggressive-battery Android;
2. restart with permission granted, denied and later removed;
3. good signal, GPS loss, mobile-data loss and relay outage freshness changes;
4. revoke racing with publish, open-page next-refresh denial and automatic
   expiry;
5. four-hour battery impact with and without active sharing;
6. link leakage across share previews, browser history and server logs; and
7. recursively validated same-party map URLs plus CSP rejection of a
   third-party fixture, or a recorded coordinate-only fallback.

Deferred: route/destination sharing, whole-group consent, app-based observers,
observer push notifications, background guarantees and per-device
authentication for the shared ride journal.

Production builds use:

```text
RIDE_RELAY_API_BASE_URL=https://relay.tailendcharlie.app/api
OBSERVER_WEB_BASE_URL=https://relay.tailendcharlie.app/observer.html
```

Pre-production builds must set both values to the same pre-production origin,
for example `https://preprod-relay.example.com/api` and
`https://preprod-relay.example.com/observer.html`. The mobile configuration
rejects mismatched origins. Both Caddy virtual hosts serve their own observer
assets with a same-origin CSP; pre-production intentionally uses the
coordinate fallback unless separate map assets are installed.
