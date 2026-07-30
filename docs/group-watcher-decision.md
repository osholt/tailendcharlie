# ADR-001: Publish whole-group watcher snapshots from the leader

**Status:** Accepted

**Date:** 30 July 2026
**Deciders:** Product owner and implementation maintainer

## Context

Issue #263 requires a trusted contact to monitor a group ride in a browser
without joining the ride. The existing issue #36 observer is deliberately a
single-phone safety link. Reusing a ride code would make the watcher a
participant and expose the durable event feed; projecting the event journal on
the server would also break the relay's transport-only privacy boundary.

The solution must remain read-only, revocable and time-limited, work with the
existing hash-only observer credentials, preserve personal links, and bound
the location data exposed to a browser.

## Decision

Add a distinct `group` observer-grant scope. The current leader's phone
publishes a replace-in-place encrypted snapshot containing only:

- current live rider display names, roles, identity colours, last-known
  positions, accuracy, timestamps and per-rider freshness inputs;
- ride lifecycle; and
- a maximum 500-point planned-route outline and bounded route name.

The app offers group scope only to the current group leader and requires an
explicit confirmation that the leader has told the group. If that phone stops
being the leader it stops publishing group snapshots. The relay persists the
grant scope and rejects a personal payload sent to a group grant or a group
payload sent to a personal grant.

The watcher receives no ride or join credential, durable events, trails,
speed/heading, phone or ICE details, quick-message history, nearby identifiers,
hazards, rejoin routes or participant controls. The watcher never appears in
the ride roster.

## Options considered

### A. Give the watcher a restricted ride credential

| Dimension | Assessment |
| --- | --- |
| Complexity | Medium |
| Privacy risk | High |
| Backward compatibility | Low |
| Relay changes | Authorization model rewrite |

**Pros:** The watcher could read the group directly.

**Cons:** A ride credential currently implies participant/event-feed access.
Splitting every existing endpoint and client assumption is easy to get wrong
and would turn a read-only link into a latent membership credential.

### B. Project the group event journal on the relay

| Dimension | Assessment |
| --- | --- |
| Complexity | Medium |
| Privacy risk | Medium-high |
| Backward compatibility | Medium |
| Relay changes | Event interpretation and identity projection |

**Pros:** Group updates would continue without the leader app foregrounded.

**Cons:** The relay would begin interpreting durable events for external
viewers, increasing its trust and data-processing role. Forged shared-journal
identity remains possible because the ride bearer is group-scoped.

### C. Leader-published bounded snapshot

| Dimension | Assessment |
| --- | --- |
| Complexity | Medium |
| Privacy risk | Lowest of the viable options |
| Backward compatibility | High |
| Relay changes | Scoped grant plus validated encrypted payload |

**Pros:** Extends the reviewed observer credential design, keeps the relay
blind to the ride journal, and makes the disclosure surface explicit and
testable.

**Cons:** Updates depend on the publishing leader phone and current background
execution limits. The app, rather than the relay, enforces the leader-only UI
because ride credentials are not per-device authenticated.

## Consequences

- Personal safety links remain protocol-version 1 and existing clients default
  missing grant scope to `rider`.
- Group watcher responses use protocol-version 2 and show independent
  freshness for every rider.
- Migration `0009` and the updated observer page must deploy before the tester
  build is advertised.
- Physical tests must cover leader handover, revoke/expiry, background and
  signal loss. A stale watcher view must never be described as live or safe.
- Per-device cryptographic leader authorization and per-rider watcher opt-in
  remain future hardening; the current disclosure is explicit and client
  enforced.

## Action items

1. Deploy migration `0009`, relay code and the observer web assets.
2. Validate personal and group links on physical iOS and Android devices.
3. Exercise leader handover and confirm group snapshots stop from the former
   leader.
4. Record the background, battery, outage, revocation and link-leakage matrix
   before claiming production safety coverage.
