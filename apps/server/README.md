# Tail End Charlie server

The online store-and-forward service for Tail End Charlie. It implements the mobile
`events:sync` contract with automatic first-use ride claiming, encrypted event
storage, authenticated opaque cursors, idempotent batches, bounded pagination,
rate limits and automatic retention.

`GET /api/v1/compatibility` advertises the current protocol, supported and
required capabilities, bounded cache lifetime and platform update URLs. Sync
requests may also send `X-TailEndCharlie-Protocol` and
`X-TailEndCharlie-Capabilities`; incompatible clients receive a structured 426
`update_required` or 409 `server_upgrade_required` response before events are
accepted. Missing headers remain compatible with the protocol-1 request body
for staged rollout.

The event store deliberately keeps only a hash of the ride bearer credential,
leaving final event-HMAC verification to receiving phones. To support the
six-digit numeric join flow, the server also holds an encrypted bootstrap
credential indexed by that short code for the bounded ride-retention window.
The code is the join credential, so it should only be shared with the intended
group; lookup attempts are rate limited.

Safety-contact access uses independent hash-only `om1_` management, `op1_`
publisher and `ro1_` viewer credentials. The app, not the relay event journal,
publishes one minimized local-device snapshot. The observer endpoint cannot
return the ride feed or create membership. See `docs/observer-access.md` for
the privacy boundary, deployment order, threat model and evidence gate.

## Development

```bash
uv sync --extra dev
uv run alembic upgrade head
uv run ride-relay-server
uv run pytest
uv run ruff check .
uv run ruff format --check .
```

Configuration is documented in `.env.example`. Production requires PostgreSQL,
two independently generated 32-byte keys, TLS termination and a scheduled
`ride-relay-cleanup` invocation.

## Moderated motorcycle discovery data

`POST /api/v1/discovery/suggestions` accepts a rate-limited, idempotent rider
suggestion into private pending storage. It never writes directly to the public
catalogue. `GET /api/v1/discovery/features` requires a viewport no larger than
10° × 10° and returns approved GeoJSON only.

The `/api/v1/admin/discovery/*` queue and moderation endpoints require
`Authorization: Bearer <RIDE_RELAY_DISCOVERY_ADMIN_TOKEN>`. Leave that setting
unset to disable moderation completely. Approved revisions retain their audit
provenance; rejected and superseded private submissions are removed after the
configured retention period. The static website's `admin-suggestions.html`
provides the corresponding no-index review UI and keeps the administrator token
in memory only.
