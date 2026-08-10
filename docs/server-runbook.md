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
**Give the host swap before it ever runs `docker build`.** The relay VM has
954 MB of RAM and around 270 MB of it free at rest, and a deploy builds the
server image on the box. A 2 GB swapfile went on on 9 August 2026 and the very
next build used 166 MB of it, so without swap that build was competing for the
free memory the running relay was using. Disk is not the constraint — the root
filesystem is 45 GB and about a quarter used:

```bash
sudo install -m 600 /dev/null /swapfile
sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
printf 'vm.swappiness = 10\nvm.vfs_cache_pressure = 50\n' \
  | sudo tee /etc/sysctl.d/99-relay-swap.conf
sudo sysctl --load /etc/sysctl.d/99-relay-swap.conf
```

`swappiness = 10` keeps the kernel using swap as headroom for build peaks rather
than as somewhere to page the live relay out to. Check the fstab line works
before trusting it to survive a reboot: `sudo swapoff -a && sudo swapon --all`
is what systemd does at boot, and `swapon --show` should still list it.

If push delivery is enabled, add the APNs/FCM credentials described in
[push-notifications.md](./push-notifications.md). A partially configured
provider intentionally prevents startup.

## Redeploying the live relay

The routine case: `main` has moved and the relay needs to catch up. This is
Rule 0 in [build-and-run.md](./build-and-run.md) — the relay must be on the same
commit as any app build you install, and the one time it was not, three app
builds were tested against a two-day-old server and the same failures were
re-reported each time.

**Host details are deliberately not in this repository.** It is public. The
operator's `~/.ssh/config` defines an alias with the address, user and key; every
command below uses that alias, so nothing here identifies the machine. If the
alias is missing, the details are in the operator's own notes, not here.

```bash
# 1. What is deployed right now, before changing anything.
ssh oracle-relay 'cd /opt/tailendcharlie && git log --oneline -1'

# 2. Is a deploy even needed? Only server-side commits matter.
git diff --stat <deployed-commit>..origin/main -- apps/server deploy
```

An empty diff means the relay is functionally current however many app commits
`main` is ahead — worth checking before blaming the server for an app-side
defect, and worth *saying* when reporting that a fix did not work.

```bash
# 3. Deploy.
ssh oracle-relay '
  set -euo pipefail
  cd /opt/tailendcharlie
  git fetch --quiet origin
  git checkout --quiet --detach origin/main
  git log --oneline -1
  export RIDE_RELAY_BUILD_COMMIT="$(git rev-parse --verify HEAD)"
  docker compose --env-file deploy/.env -f deploy/compose.yaml config >/dev/null
  docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
  # Only if this deploy changed deploy/Caddyfile - see below for why.
  docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --force-recreate caddy
'

# 4. Verify from outside, not from the box.
curl --fail --max-time 15 https://relay.example.com/health/live
curl --fail --max-time 15 https://relay.example.com/api/v1/compatibility \
  | jq -r .serverBuildCommit
ssh oracle-relay 'cd /opt/tailendcharlie && docker compose --env-file deploy/.env -f deploy/compose.yaml ps'
```

Things worth knowing before you run it:

- **The checkout is a detached HEAD at a pinned commit**, not a branch. That is
  deliberate: `git log --oneline -1` on the box then answers "what is deployed"
  exactly, with no chance of a stale local branch pointer lying about it.
- **The image is stamped from that pinned commit.** The exported
  `RIDE_RELAY_BUILD_COMMIT` becomes the public `serverBuildCommit` field on
  `/api/v1/compatibility`. `unknown` means the image was built outside the
  documented deploy command and must not be accepted as release-parity evidence.
- **Migrations run themselves.** The server image's entrypoint is
  `alembic upgrade head && exec ride-relay-server` (`apps/server/Dockerfile`), so
  a schema change is applied when the container starts. There is no separate
  migration step to forget — but it also means a bad migration stops the server
  coming up rather than failing later, so watch step 4.
- **A Caddyfile change needs `--force-recreate caddy`.** Plain `up -d` leaves
  Caddy alone: nothing in its service definition changed, only the contents of a
  file it bind-mounts. Worse, `git checkout` writes a new file and renames it
  over the old one, so the mount still resolves to the *original inode* — the
  running container keeps reading the file from before the deploy. `restart`
  does not help either, because mounts are resolved when a container is created.

  This fails silently and convincingly. `caddy reload` answers
  `config is unchanged` and exits 0, and `caddy validate` run *inside* the
  container happily validates the stale file. On 2 August that cost a deploy
  that reported success while serving the old config. Verify from outside the
  box, never from within it — that is what step 4 is for.
- **`docker` needs no `sudo`** for the deploy user.
- `RIDE_RELAY_AUTO_CREATE_SCHEMA` is `false` in production. Alembic is the only
  thing that may touch the schema.
- `--build` rebuilds the server image from `apps/server`. Caddy and Postgres are
  pinned images and are not rebuilt.
- Health checks are the gate for anything downstream: do not build an app
  against a relay whose `/health/live` is not answering 200.

Rollback is below, and is the same procedure with an older commit.

## Automatic deployment on merge

`.github/workflows/relay-deploy.yml` runs everything in the section above, on
every push to `main` that touches `apps/server/**` or `deploy/**`. Nothing else
can change what the relay serves, so nothing else deploys — see the parity note
under [Operations](#operations) for how the health probe agrees with that.

The shape is: run the `apps/server` test suite, deploy pre-production, smoke it,
promote the *same* commit to production, then verify from outside the box. Any
step failing stops the next one, so a pre-production smoke failure is what
stands between a bad merge and the riders.

**CI pushes; it does not poll.** GitHub reaches the host over SSH with a
dedicated key that is restricted with `command=`:

```
command="/usr/local/bin/relay-deploy",restrict ssh-ed25519 AAAA... relay-deploy-ci
```

That key cannot open a shell, read a file, or forward a port — `restrict`
refuses pty, agent, port and X11 forwarding, and `command=` discards whatever
the client asked for. The forced command (`deploy/relay-deploy-command`)
accepts exactly `staging` or `production`, optionally followed by a 40-character
commit, and nothing else. `deploy/relay-deploy.sh` then refuses any commit that
is not already an ancestor of `origin/main`, so the key cannot ship unreviewed
code either.

Four repository secrets carry the host details that must not be in this public
repository: `RELAY_DEPLOY_SSH_KEY`, `RELAY_DEPLOY_HOST`, `RELAY_DEPLOY_USER`
and `RELAY_DEPLOY_KNOWN_HOSTS`. The workflow writes them into an `~/.ssh/config`
alias so no command line ever carries an address.

Three things live on the host and are not deployed by git, because a deploy must
not be able to rewrite the thing that authorises it:

- `/usr/local/bin/relay-deploy` — a root-owned copy of
  `deploy/relay-deploy-command`.
- `/var/lib/relay-deploy/` — writable by the deploy user. Holds the last
  successfully deployed commit per target, which is how the script knows whether
  the Caddyfile changed. It is written only after the smoke test passes.
- `/etc/relay-deploy.conf` — optional. Set
  `RELAY_DEPLOY_PRODUCTION_OVERRIDES="compose.preproduction-proxy.yaml"` there
  once the pre-production route is enabled in the public proxy (#398), and the
  script will both include the override and watch `Caddyfile.preproduction`
  instead of `Caddyfile` — the file Caddy would then actually mount.

The script can also be run by hand on the box, which is the fastest way to
redeploy without waiting for CI:

```bash
ssh oracle-relay '/opt/tailendcharlie/deploy/relay-deploy.sh production'
```

Things worth knowing before trusting it:

- **The forced command bootstraps the checkout when the script is missing.**
  The deploy script lives in the checkout, and the checkout only moves once the
  script runs, so the first deploy after the script merged had nothing to
  `exec` — that is exactly how the first real run failed, on 9 August 2026. The
  same hole reopens after any rollback to a commit predating the script. The
  forced command now fetches and checks out far enough for the script to exist,
  under the same ancestor guard, and then hands over. It is the only deploy
  logic that cannot live in the repository, because it is what reaches the
  repository, and it is kept to the smallest thing that works.
- **The deploy script re-executes itself from the commit being deployed.** It
  checks out the pinned commit first, then hands over to that commit's copy of
  `relay-deploy.sh`. Without this, a change to the deploy logic would only take
  effect on the deploy *after* the one that merged it, and CI would report green
  for logic that never ran. The cost is that a merge which breaks the script
  breaks deploys; the manual procedure above still works in that case.
- **The pre-production smoke test runs over the host's internal Docker
  network**, not the public URL, and sends the pre-production hostname as an
  explicit `Host` header because the API rejects an untrusted one with a 400.
  Going through the public proxy would test the proxy — which is exactly what
  #398 says is broken — instead of the deploy.
- **The smoke test is a real round trip**, not a health check: it creates a plan
  and reads the GPX back, so the API, the encryption key and PostgreSQL all have
  to agree. It only writes on pre-production; production's database is riders'
  data, not a test fixture.
- **Both stacks share the one checkout**, so a staging deploy moves
  `/opt/tailendcharlie` before production is promoted. That is harmless —
  production keeps running its existing image — but it means `git log` on the
  box can disagree with production for the length of a deploy.
  `serverBuildCommit` remains the only trustworthy answer.
- **Caddy is recreated only when the Caddyfile actually changed** between the
  previously recorded commit and this one. On the very first automated deploy
  there is nothing to compare against, so it says so and leaves Caddy alone
  rather than recreating the one service whose failure takes riders offline.

## First deployment

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
After enabling push, also check
`ride_relay_push_deliveries_total` on `/metrics` and complete the locked-screen
physical-device matrix before treating background alerts as available.

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
Use separate pre-production Firebase/provider credentials where possible; do
not copy production push private keys merely to make a test build convenient.

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

## When the host stops answering

Every procedure above begins with `ssh oracle-relay`. On 9 August 2026 that
stopped working: the relay served nothing from 19:18 UTC, and neither the health
probe nor the operator's machine could reach port 22 or 443. This is what that
looks like and what actually fixed it.

**`ping` proves nothing here.** The security list permits TCP 22, 80 and 443 and
**no ICMP at all**, so a host that is perfectly healthy has never answered a
ping. Judge reachability on 22 and 443, which are open to `0.0.0.0/0`.

Everything below needs the OCI CLI. The stored session is a browser-issued token
that expires, so the first command is usually re-authentication, and that opens a
browser for a human to log in:

```bash
oci session authenticate --profile-name DEFAULT --region <region>
# then every command takes:  --auth security_token --profile DEFAULT
```

Work down this list. Each step rules something out, and the cheap ones come
first because the expensive answer is usually wrong.

```bash
# 1. Is the instance even running, and does it still have its address?
oci compute instance list --compartment-id <tenancy>   --query 'data[].{name:"display-name",state:"lifecycle-state"}' --output table
oci compute instance list-vnics --instance-id <instance>   --query 'data[].{public:"public-ip",state:"lifecycle-state"}' --output table
```

`RUNNING` with the public IP still `AVAILABLE` means the platform is fine and
the problem is inside the guest or in the network rules. A different address
means DNS is pointing at a machine that no longer exists, and nothing else in
this section applies.

```bash
# 2. Did the network rules change under you?
oci network subnet get --subnet-id <subnet> --query 'data."security-list-ids"[]'
oci network security-list get --security-list-id <list>
```

Expect ingress TCP 22, 80 and 443 from `0.0.0.0/0`. A missing rule explains the
symptom completely and needs no reboot.

```bash
# 3. Ask the guest what happened, before touching it.
history=$(oci compute console-history capture --instance-id <instance>   --query 'data.id' --raw-output)
oci compute console-history get-content --instance-console-history-id "$history"   --length 60000 --file /tmp/console.txt
grep -aiE 'out of memory|oom-kill|no space left|read-only file system|kernel panic' /tmp/console.txt
```

This is the step worth not skipping. It distinguishes a wedged kernel from a
full disk from the OOM killer, and those have different fixes. On 9 August it
showed the machine stuck in an early boot sequence with no OOM, no filesystem
error and no panic — a hung guest, nothing more.

```bash
# 4. Reset. SOFTRESET first.
oci compute instance action --instance-id <instance> --action SOFTRESET
```

`SOFTRESET` is a graceful ACPI shutdown and power-on. Prefer it: Postgres holds
a volume and a hard power cycle risks the database, not just the uptime. Only
use `RESET` if the guest is too far gone to honour ACPI — the state going
`RUNNING` → `STOPPING` tells you the kernel was alive enough to hear it.

It came back in about twenty seconds, with 566 MB of 954 MB free and the root
filesystem 20% used, so neither memory nor disk was the cause.

```bash
# 5. Docker starts itself; check it did, then restore parity.
ssh oracle-relay 'systemctl is-active docker; docker ps --format "{{.Names}}	{{.Status}}"'
ssh oracle-relay 'cd /opt/tailendcharlie && git log --oneline -1'
```

**The checkout on disk is not what is deployed.** After the 9 August reboot the
checkout was at `c1ecb1c` while `/api/v1/compatibility` reported an image built
from `fa13532` — the image had been built from a different commit than the one
checked out. `serverBuildCommit` is the only trustworthy answer to "what is
running", and a redeploy is what makes the two agree again.

Then run the ordinary redeploy above and verify from outside the box.

**What riders see during an outage.** The relay carries group coordination:
presence, hazards, quick messages and TEC status. Navigation and the map are
local and keep working, so a rider alone notices little and a group notices
everything. A build tested during an outage will produce presence and alert
failures that are the relay, not the app — which is Rule 0's lesson from 26 July
arriving by a different route. Do not ship a tester build while the probe is
red.

## Operations

- `.github/workflows/relay-health.yml` checks the public relay every 15 minutes.
  It verifies HTTPS liveness, compatibility metadata, and that no commit on
  `main` touching `apps/server` or `deploy` is newer than the commit the running
  image reports. It opens one repository issue on failure and closes it after
  recovery. Repository issue notifications are the maintainer-facing alert, so
  keep them enabled.

  The parity question is deliberately *not* "is the relay on the tip of `main`".
  Only `apps/server` and `deploy` change what the relay serves, and
  `relay-deploy.yml` only deploys pushes that touch them, so a docs merge
  legitimately leaves the relay a few commits behind and must not raise an
  alert. What must never be true is that a commit which *does* affect the relay
  is sitting undeployed — that is the five-day, 22-commit gap in #393, with the
  h2 advisory fix in it, stated exactly.
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
