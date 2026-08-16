# Global ride heatmap operations

The global heatmap is a privacy-separated relay feature. The mobile app sends
only shuffled, deduplicated z17 cells after applying the rider's endpoint trim.
The relay never receives a ride ID, raw polyline, ride time, speed, name, group
identity, or the app's live-ride credential on this interface.

## Deployment sequence

1. Back up PostgreSQL and review production edge-log retention.
2. Run `alembic upgrade head`; revision `0011` adds only heatmap tables.
3. Deploy the server and cleanup worker from the same commit.
4. Confirm `/api/v1/compatibility` advertises `global-ride-heatmap-v1`.
5. Confirm the heatmap counters appear on `/metrics`, without contributor or
   geographic labels.
6. Exercise registration, one contribution, public viewing, and revocation
   using a non-production test credential before distributing clients.

The hourly cleanup worker removes 30-day upload receipts and contributor-cell
rows older than 24 complete calendar months, removes empty contributors after
90 days, and publishes at most one atomic snapshot per UTC day. Each new
snapshot replaces the previous one. Public cells require three distinct opaque
contributors at every served zoom.

## Kill switches

- `RIDE_RELAY_HEATMAP_CONTRIBUTIONS_ENABLED=false` disables registration and
  upload while keeping deletion and existing public coverage available.
- `RIDE_RELAY_HEATMAP_PUBLIC_ENABLED=false` immediately hides public coverage.

Use the public switch for suspected disclosure or polluted output. Disable
contributions first for a storage or schema problem. Do not remove the tables:
revocation and retention obligations continue even while writes are disabled.

## Monitoring

Alert on sustained `http_4xx`/`http_5xx` outcomes, a snapshot date older than
one UTC day, cleanup failures, or unexpected table growth. Heatmap metrics use
only operation/outcome and coarse response-size labels. Application logs must
not add request bodies, cell lists, credentials, handles, or viewport bounds.

## Rollback

Disable contribution writes, deploy the previous server, and leave migration
`0011` in place so cleanup and authenticated remove-all requests can continue.
Only run `alembic downgrade 0010` after the tables are empty and the privacy
owner has confirmed that no retention or deletion obligation remains. A code
rollback alone is not permission to discard or strand contributed data.
