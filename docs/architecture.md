# Architecture

## Current shape

The app is a Flutter client with thin Swift and Kotlin platform bridges. The
domain model does not depend on a particular network transport.

```text
UI -> RideController -> local event journal
                            |
                            +-> NearbyRelayController -> durable relay queue
                                                           |
                                                           +-> PeerTransport
                            |
                            +-> InternetRelayController -> bounded HTTPS sync
                                                           -> opaque cursor

Flutter -> method channel -> Swift / Kotlin nearby transport adapters
```

Every state-changing user action is converted into a `RideEvent` and appended
to SQLite before it is considered accepted. Event IDs are primary keys, so a
relay may safely deliver the same event repeatedly. Read models can be rebuilt
from the journal.

## Event envelope

The initial envelope contains:

- schema version;
- globally unique event ID;
- ride and device IDs;
- type, priority, creation and expiry times;
- typed JSON payload;
- ride-secret HMAC; and
- local acknowledgement state.

New events use one canonical ride-secret HMAC body. Verification retains
read-compatibility with the earlier development-alpha body. Downloaded internet
events are verified before storage. This group HMAC is not the final security
design: device identity, key rotation, and application-layer encryption remain
production gates.

## Relay transport

The transport-neutral relay engine implements bounded, HMAC-authenticated,
ACK-driven store-and-forward exchange. Its native adapter links Google Nearby
Connections cluster transport on Android and iOS. Physical cross-platform
offline validation is still a release gate; see `nearby-relay.md`.

The development-alpha HTTPS worker batches pending journal events and pulls
missing events by opaque cursor. It is disabled unless an HTTPS endpoint is
configured, and the server contract is documented in `internet-relay.md`.
Retries are automatic, bounded, and jittered. Request, response, event, and
timeout limits are enforced on the client.

Server acknowledgement and nearby delivery are separate concerns. The journal
acknowledgement currently represents server acceptance; nearby scans every ride
event and relies on its own durable queue for per-peer ACK and deduplication.
This allows an internet-connected phone to carry downloaded events back into an
offline cluster.

The event journal is the source of truth. Neither a WebSocket nor a nearby
session is assumed to remain connected.

## Uncertainty is part of the model

The eventual UI states are `live`, `relayed`, `stale`, and `unknown`. A
timestamp or a successful API call alone must never be presented as proof that
another rider has received an event.

## Deliberately absent

- No production server or cloud credentials.
- No real location tracking or background modes.
- No claim that the linked Nearby SDK has passed the physical-device matrix.
- No distribution signing configuration.
- No claim that an app force-quit by the user can continue relaying on iOS.
