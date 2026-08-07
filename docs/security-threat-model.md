# Security threat model and protocol-v2 decision

Status: architecture decision for issue #272. The protocol-v2 work described
here is **not implemented**. Protocol 1 remains suitable only for invited,
private field testers who know and trust one another. Public distribution is
blocked until the implementation and validation gates at the end of this
document pass.

## Scope and assets

The system must protect:

- precise current and historical rider locations;
- phone, ICE and medical details;
- priority and assistance messages;
- membership, role and ride-lifecycle authority;
- private invitation and watcher credentials; and
- event integrity while phones are offline, partitioned or relaying through an
  untrusted peer or server.

Availability is important, but Tail End Charlie is not an emergency service.
No design can guarantee immediate revocation, delivery or a consistent roster
while every path between two phones is unavailable. The UI must continue to
describe stale, relayed and unknown evidence honestly.

## Current protocol-1 threat model

Protocol 1 gives every ride member the same invitation secret. That secret
authenticates events and nearby frames with HMAC and derives the internet-relay
bearer. Roles are reducer state, not cryptographic principals.

| Role | Can forge today | Can read today | Can replay today |
| --- | --- | --- | --- |
| Leader | Any ride event, device ID or role, including another leader | Every plaintext event delivered to the app, including data allowed by the UI only to a coordination role | Any retained signed event or frame; IDs and expiry reduce duplicate impact |
| Marker | Exactly the same cryptographic power as the leader | Exactly the same delivered plaintext; UI restrictions are not a cryptographic boundary | Exactly the same replay power as the leader |
| Tail End Charlie | Exactly the same cryptographic power as the leader | Exactly the same delivered plaintext; UI restrictions are not a cryptographic boundary | Exactly the same replay power as the leader |
| Rider | Exactly the same cryptographic power as the leader | Exactly the same delivered plaintext; UI restrictions are not a cryptographic boundary | Exactly the same replay power as the leader |
| Personal watcher | No ride events unless a ride credential is separately leaked; the read token cannot publish or revoke | One minimised last-known snapshot for the consenting rider | Can repeat reads and retain any response already received until or after revocation |
| Whole-group watcher | No ride events unless a ride credential is separately leaked; the read token cannot publish or revoke | The minimised roster, positions, lifecycle and route outline published by the leader app | Can repeat reads and retain any response already received until or after revocation |

The relay can read event bodies while processing them because its AES-GCM is
encryption at rest, not end-to-end encryption. It can delay, drop, reorder or
replay stored envelopes but cannot mint a new valid HMAC without the shared
secret. An attacker who obtains a private invitation, ride bearer or watcher
link inherits the corresponding bearer capability.

Existing deduplication, expiry, canonical signatures, strict parsing and
retention bounds are useful controls. They do not provide device attribution,
member revocation or confidentiality from the relay and must not be described
as doing so.

## Protocol-2 decisions

### Per-install device identity

Each installation generates two independent key pairs on the device:

- Ed25519 for signing; and
- X25519 for HPKE recipient encryption.

Private keys are used through a small native cryptography bridge. iOS stores
them with Keychain `AfterFirstUnlockThisDeviceOnly` accessibility so background
ride work can use them without synchronising them to another device. Android
uses direct, non-exportable Android Keystore keys when the device/API supports
the chosen curves. Otherwise it stores an encrypted private-key blob wrapped
by a non-exportable Keystore AES key; that fallback and its device coverage
must be measured rather than hidden. Hardware-backed storage is preferred when
available. Public keys and a versioned key identifier may be stored in SQLite.

An installation ID is a domain-separated SHA-256 fingerprint of the signing
public key. A separate, ride-scoped rider ID prevents that stable fingerprint
being exposed in ordinary relay or watcher data. A leader-signed membership
certificate binds the ride ID, ride-scoped rider ID, display identity, both
public keys, permitted role/capabilities, membership epoch and expiry.

Identity does not promise to survive uninstall. Android removes app Keystore
material on uninstall, while iOS Keychain survival after uninstall is an
undocumented implementation detail rather than an API contract. A reinstall or
key/database mismatch therefore creates a new identity and requires a new
invitation. No account, cloud backup or recovery key is introduced silently.

### Authority and role enforcement

The creator's signed ride-creation record is the trust anchor. Membership,
removal, role assignment and leadership transfer records are signed by the
currently authorised leader and form a hash-linked, monotonically numbered
authority chain. Every event identifies the authority epoch and signer key and
has a per-signer monotonically increasing counter.

Verification first checks the device signature and membership certificate,
then an event-policy table checks that the signer held the required role at
that authority revision. The policy must cover every event type and must reject
unknown combinations by default. A leadership transfer is valid only from the
leader in the preceding authority state. If a malicious leader signs two
successors for one revision, a documented deterministic branch rule makes all
peers converge and records the equivocation for the UI and diagnostics.

This changes a role check from “this event knows the group secret” to “this
specific admitted device was authorised to perform this action at this point
in the authority chain.” It cannot stop an authorised leader abusing powers
the product intentionally grants to the leader.

### Offline revocation and rotation

Revocation is a high-priority, leader-signed authority transition. It:

1. removes the member and their signing/encryption keys;
2. increments the membership and content-key epoch;
3. states the last accepted event counter for every old-epoch signer; and
4. distributes the new epoch key only to remaining devices, using an HPKE
   envelope for each device's X25519 public key.

Once a phone learns the transition it rejects the revoked signer and rejects
old-epoch events above the signed counter cut-offs. Old-epoch events that had
already been stored above a cut-off remain quarantined for bounded diagnostic
retention but no longer reduce into ride state. This makes peers converge even
if one saw a forged or delayed event before it received the revocation.

The explicit availability trade-off is that **queued old-epoch events not
covered by the leader's cut-offs are invalidated by rotation**, including
honest events from a retained phone that was isolated from the leader. After it
receives the new epoch, that phone reissues still-current state and warns about
one-shot actions that could not be carried forward. Security takes precedence
over silently accepting an event a removed member could have backdated.

A partitioned phone that has not received the revocation will temporarily
continue to trust the old epoch. Instant offline revocation is impossible; the
app must show the last authority revision and uncertainty. Revocation prevents
future access only. A removed member cannot be made to forget plaintext or old
epoch keys they already received.

### Event and sensitive-data encryption

Protocol 2 encrypts private payloads before they enter Nearby, the internet
relay or durable relay queues. The authenticated clear header contains only the
version, ride locator, event ID, signer key ID, authority/key epoch, event
counter, creation/expiry bounds and a coarse routing priority. Event type,
coordinates, names, message text and safety/contact fields are ciphertext.
The Ed25519 signature covers the complete header and ciphertext.

Ordinary group events use AES-256-GCM with a unique per-event key and nonce
derived under disjoint HKDF-SHA256 labels from the epoch key and a
domain-separated tuple containing ride, epoch, signer, counter and event ID.
Counter reservation must be crash-safe and atomic; event-ID uniqueness is a
second reuse defence. The header is AEAD associated data. Implementations must
use an audited library and test for counter rollback, key/nonce reuse,
truncation and header substitution rather than constructing cryptographic
primitives themselves.

Phone, ICE and medical payloads are not encrypted to the whole group. A fresh
content key is wrapped with RFC 9180 HPKE only to the currently authorised
recipients for that data type. Priority messages use the group epoch unless
their audience is narrower. The product's recipient-policy table remains an
explicit, testable input to encryption; hiding a button is not access control.

Watcher snapshots get a separate end-to-end content key generated by the
publishing phone and carried only in the URL fragment beside the read
credential. The browser decrypts an opaque snapshot locally. The relay does
not receive that key or any ride epoch key. Watcher keys cannot sign events,
grant membership or derive ride keys. Revocation stops future reads but cannot
erase a snapshot the watcher retained.

### Relay authentication and abuse control

Protocol 2 replaces the group write bearer with a short-lived request proof
signed by the admitted device. The relay stores the ride trust anchor,
membership certificates, authority transitions and revocations needed to
verify membership without learning content keys. It continues to treat event
bodies as opaque and does not claim that acceptance proves delivery.

Before public release, limits for invitation resolution, membership changes,
event writes, watcher creation and reads must be shared across API replicas
through an edge, Redis/Valkey or PostgreSQL-backed limiter. The existing
in-process limiter remains acceptable only for a declared single-replica
private test deployment. Limits must combine IP, ride, device and endpoint
dimensions so carrier NAT does not let one rider block everyone else.

### Privacy impact and deployment region

A documented DPIA is mandatory before public release because the service
systematically processes precise movement and location, and can include
emergency contacts or medical context. It must record purpose, lawful basis,
data minimisation, role/watcher disclosure, children/vulnerable-user risks,
retention and deletion, data-subject requests, processors, logs/backups,
breach handling and international transfers. Tester consent is not a substitute
for that decision.

Multi-region is not an initial public-release requirement. A single documented
UK or EU region is acceptable if the app makes no emergency-availability claim
and backup/restore, monitoring, retention cleanup and region residency are
tested. Multi-region may be added only with a written consistency, encryption,
failover and data-residency design; duplicating precise location “for
reliability” without that work would increase privacy exposure.

### Backward compatibility and downgrade prevention

Protocol 2 is a negotiated, incompatible envelope version. The rollout order is
server read/advertise support, mobile support behind a capability, private
tester migration, then protocol-2-only public rides.

- A ride is created as protocol 1 or protocol 2 and never changes version in
  place.
- Existing protocol-1 tester rides may finish under the current private-test
  policy and retention window; migration means creating a new ride.
- Protocol-2 clients never send protocol-2 secrets or events to a protocol-1
  endpoint and never downgrade a protocol-2 ride.
- Protocol-1 clients cannot join a protocol-2 ride and receive a specific
  update-required response rather than a generic sync failure.
- The server may support both versions during one measured tester release
  window. New public rides require protocol 2; protocol 1 is then disabled or
  confined to an explicitly private test environment.
- Mixed-version, downgrade, replay and partially upgraded relay tests are part
  of the release gate. The additive unknown-event behavior in issue #37 stays
  valid within a protocol version; it is not a licence to strip or reinterpret
  a protocol-2 security envelope.

## Implementation and validation gates

The work is deliberately split so each layer can land disabled, with tests,
before the public-release switch:

1. [per-install Ed25519/X25519 identity and secure platform storage](https://github.com/osholt/tailendcharlie/issues/332);
2. [protocol-2 signed and encrypted event/frame envelopes](https://github.com/osholt/tailendcharlie/issues/333);
3. [membership certificates, role policy and leadership authority chain](https://github.com/osholt/tailendcharlie/issues/334);
4. [offline revocation, epoch re-keying and queued-event cut-offs](https://github.com/osholt/tailendcharlie/issues/335);
5. [end-to-end encrypted watcher snapshots](https://github.com/osholt/tailendcharlie/issues/336);
6. [per-device relay authentication and shared rate limiting](https://github.com/osholt/tailendcharlie/issues/337);
7. [DPIA, retention, residency and operator controls](https://github.com/osholt/tailendcharlie/issues/338); and
8. [adversarial migration and key-lifecycle validation](https://github.com/osholt/tailendcharlie/issues/339).

None may remove protocol-1 compatibility until the staged migration gate above
has passed. No public release may rely on protocol 1.

## Standards and platform references

- [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
  and [storing keys in the Keychain](https://developer.apple.com/documentation/security/storing-keys-in-the-keychain)
- [Apple DTS: Keychain survival after uninstall is not an API contract](https://developer.apple.com/forums/thread/36442)
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [RFC 8032: Ed25519](https://www.rfc-editor.org/rfc/rfc8032)
- [RFC 7748: X25519](https://www.rfc-editor.org/rfc/rfc7748)
- [RFC 9180: HPKE](https://www.rfc-editor.org/rfc/rfc9180)
- [RFC 5116: AEAD interface and nonce requirements](https://www.rfc-editor.org/rfc/rfc5116)
- [ICO guidance on data protection impact assessments](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/accountability-and-governance/data-protection-impact-assessments-dpias/)
