# Server deployment runbook

## Get a free host

The whole stack (PostgreSQL, the API, cleanup, Caddy) is light enough for a
free-tier VM. Oracle Cloud's Always Free tier is the best fit: genuinely free
forever, no trial period, sized well past what this needs (as of mid-2026 the
Always Free Ampere A1 allowance is 2 OCPU / 12 GB RAM total, reduced from an
earlier 4 OCPU / 24 GB but still generous for this workload).

1. Create an account at [oracle.com/cloud/free](https://www.oracle.com/cloud/free/)
   (needs a card for identity verification; nothing is charged while you stay
   inside the Always Free limits).
2. Console -> Compute -> Instances -> Create instance. Choose an Ampere
   (Arm-based) shape under "Always Free eligible", Canonical Ubuntu as the
   image, and add your SSH key. If instance creation fails with an
   out-of-capacity error, retry in a different availability domain or region -
   this is a known, temporary Always Free capacity constraint, not a
   configuration problem.
3. In the instance's assigned VCN, open a public ingress security list rule
   for TCP 80, TCP 443, and UDP 443 (source `0.0.0.0/0`). Oracle's Ubuntu
   images also ship a restrictive host firewall (`iptables`/`netfilter`) on
   top of the cloud security list - both layers must allow the traffic, or
   connections will simply time out with the security list looking correct.
4. SSH in and install Docker Engine plus the Compose plugin (see
   [docs.docker.com/engine/install](https://docs.docker.com/engine/install/)
   for the current Ubuntu steps), then clone this repository onto the host.
5. At your domain's DNS provider, add an A record for a subdomain (for
   example `relay.yourdomain.com`) pointing at the instance's public IPv4
   address. Caddy (below) obtains its TLS certificate for whatever hostname
   you put in `RIDE_RELAY_DOMAIN`, so the DNS name and that setting must
   match exactly.

With the host and DNS in place, continue with the ordinary deployment below -
nothing past this point is free-tier-specific.

## Prepare

Use a host with Docker Compose, a public DNS record, inbound TCP 80/443 and UDP
443, persistent storage, monitoring, and backups. Never expose port 8080 or the
PostgreSQL port publicly; trusting forwarded IP headers is safe only behind the
included Caddy network boundary.

```bash
cp deploy/.env.example deploy/.env
python3 -c 'import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="))'
python3 -c 'import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="))'
```

Put two different generated values and a long random PostgreSQL password in
`deploy/.env`. Keep this file out of Git and in the host's secret backup.
Set `RIDE_RELAY_MAXIMUM_ACTIVE_RIDES` from the encrypted-volume capacity and
expected field-test population; the default is 100. The event and replay byte
quotas in the same file should also be kept within the available volume.

## Deploy and verify

```bash
docker compose --env-file deploy/.env -f deploy/compose.yaml config
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
curl --fail https://relay.example.com/health/live
docker compose --env-file deploy/.env -f deploy/compose.yaml exec -T server \
  python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health/ready')"
```

Caddy obtains and renews TLS automatically. Compile
`https://relay.example.com/api` into the field-test app only after both health
checks pass. For TestFlight builds, set it once as the `RIDE_RELAY_API_BASE_URL`
repository variable (`gh variable set RIDE_RELAY_API_BASE_URL --body
"https://relay.example.com/api"`, or Settings -> Secrets and variables ->
Actions -> Variables) rather than editing the workflow file; `testflight.yml`
reads it from there and fails the build with a clear error if it is unset. Run
a two-phone ride claim/sync test before a field ride.

For maps, add a licence-approved archive and matching style as described in
[maps-and-gpx.md](./maps-and-gpx.md), then add `--profile maps` to the Compose
command and verify the style plus representative tiles.

## Isolated pre-production on the same host

Pre-production can share the VM and public Caddy process without sharing API
containers, PostgreSQL data, credentials, or Docker volumes with production.
Create an A record such as `preprod-relay.example.com` pointing to the same
host, then prepare independent secrets:

```bash
cp deploy/preproduction.env.example deploy/.env.preproduction
python3 -c 'import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="))'
python3 -c 'import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="))'
```

Put the pre-production hostname and two new keys in
`deploy/.env.preproduction`; never copy the production database password or
encryption/signing keys. Put the same hostname in production's `deploy/.env`
as `RIDE_RELAY_PREPRODUCTION_DOMAIN`.

Start the isolated stack, then enable its route in the existing public proxy:

```bash
docker compose --env-file deploy/.env.preproduction \
  -f deploy/compose.preproduction.yaml up -d --build
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.preproduction-proxy.yaml up -d caddy
curl --fail https://preprod-relay.example.com/health/live
curl --fail https://preprod-relay.example.com/api/v1/compatibility
```

Once enabled, include `compose.preproduction-proxy.yaml` whenever recreating
the production Caddy service. The pre-production API service deliberately uses
the distinct Compose name `preproduction-server`; do not rename it to `server`,
because Docker would then publish a second `server` alias on the production
proxy network and could send production traffic to pre-production. Build test
clients with `RIDE_RELAY_API_BASE_URL=https://preprod-relay.example.com/api`;
production clients remain compiled against `https://relay.example.com/api`.
Destructive pre-production testing is safe only after confirming the two
Compose projects show different database containers and named PostgreSQL
volumes.

## Tailnet-only field-test host

For a private field test, the override runs a Tailscale sidecar with its own
persisted tailnet identity and proxies to the API over the private Docker
network. No API port is published on the Docker host. Tailscale Serve terminates
HTTPS and Funnel remains disabled. Do not start the public Caddy service in this
mode:

```bash
cp deploy/.env.example deploy/.env.tailnet
# Set RIDE_RELAY_DOMAIN=ride-relay.<tailnet>.ts.net, the database password,
# and both random keys. Optionally set RIDE_RELAY_TAILSCALE_HOSTNAME.
# Set TS_AUTHKEY to a one-off key for unattended first-time registration.
docker compose --project-name ride-relay-tailnet \
  --env-file deploy/.env.tailnet \
  --file deploy/compose.yaml \
  --file deploy/compose.tailnet.yaml \
  up -d --build db tailscale server cleanup
```

If no auth key is supplied, follow the one-time URL printed by `docker compose
logs tailscale`; the `tailscale-state` volume preserves the resulting identity
across restarts and container recreation. Verify it with:

```bash
docker compose --project-name ride-relay-tailnet \
  --env-file deploy/.env.tailnet \
  --file deploy/compose.yaml \
  --file deploy/compose.tailnet.yaml \
  exec -T tailscale tailscale status
curl --fail https://ride-relay.<tailnet>.ts.net/health/ready
```

Compile the field-test client with
`RIDE_RELAY_API_BASE_URL=https://ride-relay.<tailnet>.ts.net/api`. Tailscale ACLs
determine which tailnet members can reach the HTTPS address. Readiness and
metrics are tailnet-visible in this temporary topology, so use the public Caddy
topology before internet exposure.

## Operations

- Alert if readiness fails, 5xx rises, sync latency grows, PostgreSQL storage
  grows unexpectedly, or cleanup stops logging hourly completion.
- Back up with `pg_dump -Fc` to encrypted off-host storage and test restore.
- Upgrade by backing up, pulling the tagged commit, running `docker compose
  build`, and applying the Alembic migration through server startup.
- Rotate the cursor key only when invalidating all saved mobile cursors is
  acceptable; clients recover with a fresh cursor after clearing local state.
- Do not rotate the data-encryption key without a decrypt/re-encrypt migration;
  old events and idempotency replays otherwise become unreadable.
- Treat logs as sensitive even though the app does not intentionally log event
  bodies or bearer credentials.

## Rollback

Restore the previous image/commit only when its database migration is compatible.
If not, stop writes, restore the pre-deploy database backup, then restore the
previous containers. Mobile clients keep retrying bounded requests while the
service is unavailable.
