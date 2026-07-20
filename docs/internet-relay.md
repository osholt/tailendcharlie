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

Nearby and internet acknowledgements remain separate. A server-acknowledged
event is still eligible for nearby carriage, which lets a connected phone move
events back into a group without coverage.

## API contract

```text
POST {base}/v1/rides/{ride-id}/events:sync
Content-Type: application/json
Authorization: Bearer rr1_<base64url-HMAC-SHA256>
Idempotency-Key: rr1-<base64url-SHA256-exact-request-body>
X-Ride-Relay-Device: <device-id>
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
HMAC check. Per-device keys, member revocation, and a formal security/privacy
review remain release gates.

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
