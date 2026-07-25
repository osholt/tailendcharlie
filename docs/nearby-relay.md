# Nearby relay: development-alpha contract

## What is implemented

Tail End Charlie now has an application-layer relay that is independent of the radio
provider:

```text
NearbyRelayController
        |
        v
RelayEngine -> durable RelayQueueStore -> EventStore
        |
        v
PeerTransport -> Google Nearby Connections (Swift / Play Services)
```

- `NearbyRelayController.start(session)` scopes the relay to one active ride.
- `publish(event)` queues an already-journalled event for delivery.
- `receivedEvents` emits newly accepted remote events.
- `publishPresence` and `presenceUpdates` carry one signed, 45-second,
  replace-only pre-start rider snapshot without touching the event store or
  durable relay queue.
- `status` exposes searching/reconnecting/connected state, peer IDs, queue depth,
  rejected-frame count and last exchange time.
- `stop()` cancels discovery, advertising, reconnect work and connections.

The queue is durable in `SqliteRelayQueue`. The in-memory implementation exists
for deterministic tests. Delivery is at-least-once: peers acknowledge event IDs,
lost acknowledgements cause safe replay, and the event journal deduplicates by
globally unique event ID.

Presence is intentionally different: it is best-effort and memory-only. A new
peer receives the local rider's still-fresh latest snapshot, but a disconnected
phone does not accumulate or replay pre-start movement history.

## Wire safety limits

Every frame is protocol-versioned and authenticated with HMAC-SHA256 using the
ride invite secret. The decoder validates the authentication tag before it
accepts an event. The signed envelope uses recursively sorted JSON keys, so the
schema, identifiers, type, timestamps, priority and payload cannot be changed
without invalidating the tag. The `acknowledged` flag is excluded because it is
per-device local delivery metadata, not a group event property. It also enforces:

- 28 KiB maximum frame size (below the documented 32 KiB cross-platform byte
  payload limit);
- 12 events or 64 acknowledgements per frame;
- 8 KiB maximum encoded event size;
- maximum eight relay hops;
- five-minute frame freshness and two-minute future-clock tolerance;
- per-event expiry (2h routine, 8h important, 24h critical by default); and
- a 512-event local queue cap that retains higher-priority/newer items first.

Presence frames additionally require the signed sender ID to match the rider
ID, carry either one bounded position or an explicit clear, and expire within
five minutes (45 seconds in the product flow).

HMAC with a group secret prevents outsiders without the invite secret from
injecting or altering accepted frames. It does not provide per-rider identity,
non-repudiation, or confidentiality. Device keys and application-layer
encryption remain release security gates.

## Native implementation and constraints

The selected native route is Google Nearby Connections because Google's current
documentation explicitly describes Android/iOS interoperability and the
`cluster` strategy as an M:N topology for small mesh-like payloads. Tail End Charlie
uses one service ID and strategy on both platforms:

- service ID: `me.osholt.ride_relay.relay.v1`;
- strategy: `P2P_CLUSTER` / `.cluster`;
- Android: `com.google.android.gms:play-services-nearby:19.3.0`;
- iOS: `google/nearby` Swift package pinned to revision
  `a6f799af7f13154ee8d6d3156750d0cfe3f5a788`; and
- Bonjour service: `_90AAE9C4995F._tcp`, derived from the service ID as required
  by the Swift setup guide.

Primary references:

- <https://developers.google.com/nearby/>
- <https://developers.google.com/nearby/connections/overview>
- <https://developers.google.com/nearby/connections/strategies>
- <https://developers.google.com/nearby/connections/android/get-started>
- <https://developers.google.com/nearby/connections/swift/get-started>
- <https://github.com/google/nearby>

There is still an important evidence gap. Older guidance from the maintainers
reported that iOS/Android exchange could depend on both devices sharing a LAN,
while current documentation and Swift source now advertise BLE and BLEV2 paths.
A successful SDK build does not prove fully offline cross-platform discovery on
the target phones, with locked screens, in motorcycle placement. Consequently:

- native capability reports `hardwareValidationRequired`;
- the UI/product must call this a development alpha, not a working mesh;
- no iOS background modes are enabled yet;
- simulators are not accepted as radio evidence; and
- a force-quit app is never claimed to keep relaying.

Android requests the current Nearby device/location permissions at runtime. iOS
uses the Bluetooth, local-network and Bonjour declarations required by Google's
Swift setup guide. Nearby's connection token is automatically accepted in this
alpha and the application HMAC rejects non-members. A user-visible transport
verification or ride-bound token check must be chosen before release to reduce
unauthenticated connection/denial-of-service exposure.

Android also keeps the normal `ACCESS_WIFI_STATE` and `CHANGE_WIFI_STATE`
permissions on Android 13 and newer. `NEARBY_WIFI_DEVICES` replaces the
dangerous Wi-Fi scan permission prompt, but Google Play services still checks
the two normal permissions when `P2P_CLUSTER` starts advertising. An Android 14
emulator run on 2026-07-25 confirmed Bluetooth, BLE and Wi-Fi LAN advertising
plus BLE and Wi-Fi LAN discovery after removing the obsolete SDK cap; before
that change, Play services aborted both operations as missing
`ACCESS_WIFI_STATE`.

## Hardware release gate

Run the matrix in `field-test-plan.md` on physical devices with mobile data off.
At minimum, demonstrate Android↔Android, iPhone↔iPhone, and both Android↔iPhone
directions while Wi-Fi is not associated with a common access point. Capture:

1. discovery medium/state and permission state;
2. connection and automatic reconnection latency;
3. authenticated priority-event delivery and ACK;
4. A→B→C convergence where A and C never meet;
5. screen-on, locked, backgrounded and force-quit behaviour; and
6. four-hour battery impact.

Do not change the capability gate or marketing language until that evidence is
recorded and the stated pass thresholds are met.
