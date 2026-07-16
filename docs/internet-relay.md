# Internet relay development contract

The mobile internet relay is a development-alpha client, not a hosted service.
It is disabled by default and performs no server traffic until an absolute
HTTPS endpoint is compiled into the app:

```bash
flutter run \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.example.test/api
```

The URL must not contain credentials, a query, or a fragment. There is no
default endpoint, API key, backend deployment, or secret in this repository.
The Ride screen says **Internet relay not configured** when the setting is
absent; a successful request is described only as the last successful sync,
not as proof that another rider is live or has received an event.

## Mobile behaviour

The worker uses the same idempotent `RideEvent` journal as nearby delivery:

- uploads at most 20 pending events per request;
- applies at most 100 downloaded events per response;
- marks only IDs explicitly accepted by the server as server-acknowledged;
- persists an opaque cursor only after authenticated downloaded events have
  been applied;
- rejects wrong-ride, wrong-schema, oversized, malformed, or HMAC-invalid
  events before mutating durable state;
- retries timeouts, network failures, HTTP 408/429, and server failures with
  bounded exponential backoff and jitter;
- wakes immediately when a local event is recorded and polls every 15 seconds
  while an active ride is open;
- limits request bodies to 64 KiB, responses to 128 KiB, and encoded events to
  8 KiB; and
- refuses HTTP redirects so a bearer credential cannot be forwarded away from
  the explicitly configured HTTPS origin.

Nearby delivery deliberately ignores the journal's server acknowledgement
flag. Its own durable queue owns peer delivery and deduplication, allowing a
phone to carry a server-downloaded event onwards to riders without coverage.

## Required server endpoint

The configured base URL receives:

```text
POST {base}/v1/rides/{percent-encoded-ride-id}/events:sync
Content-Type: application/json
Authorization: Bearer rr1_<base64url-HMAC-SHA256>
Idempotency-Key: rr1-<base64url-SHA256-request-body>
X-Ride-Relay-Device: <device-id>
```

Request body:

```json
{
  "protocolVersion": 1,
  "deviceId": "device-id",
  "cursor": "opaque-previous-cursor-or-null",
  "events": []
}
```

Successful response:

```json
{
  "protocolVersion": 1,
  "cursor": "opaque-next-cursor",
  "acceptedEventIds": [],
  "events": []
}
```

The bearer credential is derived locally as HMAC-SHA256 with the invitation
secret over `ride-relay-internet-token-v1\n<rideId>`. The invitation secret is
never transmitted. This is group-scoped alpha authentication, not individual
device identity or end-to-end payload encryption.

The server must be provisioned out of band with only the derived credential or
its hash. It must authorize the ride before reading or writing events, enforce
the client bounds or stricter ones, uniquely index `(ride_id, event_id)`, treat
the idempotency key as a replay-safe operation key, and return only accepted
IDs from the submitted batch. Cursors are opaque and limited to 512 characters.

Recommended status behaviour:

- `400` malformed protocol, `401`/`403` rejected credential;
- `409` conflicting event identity, `413` body or event too large;
- `429` rate limited, with an integer `Retry-After` of at most 300 seconds; and
- `5xx` transient server failure.

## Why no reference backend yet

A public-looking sample backend without provisioning, rate limits, retention,
deletion, abuse controls, audit boundaries, or operational ownership would be
misleading and unsafe for location data. A production backend must additionally
avoid logging credentials and event bodies, encrypt retained data at rest,
enforce ride expiry and deletion, isolate tenants, rotate credentials, and
receive security and privacy review. Until those gates have owners and tests,
the HTTPS contract above is the intentionally narrow integration seam.
