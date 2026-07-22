# Next-agent handoff

Updated: 2026-07-22

## Current branch

Active work is on `codex/ui-navigation-batch` in
[draft PR #43](https://github.com/osholt/tailendcharlie/pull/43). The branch
also contains the earlier UI/navigation, simulator service connection, iOS
device-crash, rider-count and foreground screen-awake fixes. Do not split or
overwrite the user's unrelated local Xcode signing edit or the untracked
`docs/carplay-entitlement-submission/` material.

## Current issue batch

- #27: canonical signed membership reducer, explicit leave, stable ride-scoped
  installation identity, two-minute inactive state and twelve-hour expiry.
- #33: roster sheet with current/attention/all filters, role, freshness,
  transport evidence and canonical alert counts.
- #28: leader-authored, chunked and verified route revisions; ride-scoped local
  storage; explicit confirmed clear; late-join/reconnect journal recovery.
- #37: relay protocol/capability negotiation, bounded legacy behavior and
  explicit app-update/server-upgrade states.
- #42: persistent first-run profile setup and education, optional skip,
  permission-degraded guidance, create/join handoff, Settings editing and replay.

All five issues require some physical, cross-platform, deployment or usability
evidence, so automated implementation alone must not be described as satisfying
their field gates.

## Narrow verification

```bash
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
```

```bash
cd apps/server
uv run ruff format --check .
uv run ruff check .
uv run python -m pytest
```

Use `uv run python -m pytest` if the direct `uv run pytest` entry point has a
stale virtual-environment shebang.

## Remaining evidence

- Exercise explicit leave/rejoin and roster/alert counts across mixed physical
  iOS and Android phones.
- Publish, replace and clear leader routes across late join, offline reconnect,
  restart and lead handover on both platforms.
- Deploy the compatibility endpoint and test old-client/current-server plus
  current-client/old-server rollout combinations.
- Run onboarding with at least one person who has not used the app and record
  accessibility observations at supported text sizes and with a screen reader.
- The full Nearby, background, battery, route-alert and vehicle-interface gates
  in `PLAN.md` and `docs/field-test-plan.md` remain authoritative.
