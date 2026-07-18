# Tail End Charlie server

The online store-and-forward service for Tail End Charlie. It implements the mobile
`events:sync` contract with automatic first-use ride claiming, encrypted event
storage, authenticated opaque cursors, idempotent batches, bounded pagination,
rate limits and automatic retention.

The event store deliberately keeps only a hash of the ride bearer credential,
leaving final event-HMAC verification to receiving phones. To support the
six-digit numeric join flow, the server also holds an encrypted bootstrap
credential indexed by that short code for the bounded ride-retention window.
The code is the join credential, so it should only be shared with the intended
group; lookup attempts are rate limited.

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
