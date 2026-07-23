# Next-agent handoff

Updated: 2026-07-23

## Current branch

Issue #34 and #38 work is on `codex/route-review-push` in
[draft PR #52](https://github.com/osholt/tailendcharlie/pull/52), rebased on
current `main` after PR #43, the pre-production routing hotfix in PR #55, the
curvy-route calibration in PR #56 and the Android mini-map fallback in PR #45
merged. The user's primary worktree still contains an unrelated local Xcode
signing edit and untracked `docs/carplay-entitlement-submission/` material; this
feature work was completed in a separate clean worktree and must not overwrite
either item.

PR #44 (`codex/turn-by-turn-guidance`) remains a separate open navigation
branch.

## Current issue batch

- #34: every calculated, imported, recorded, shared and demo route is reviewed
  before it becomes authoritative. The screen fits the complete route, lists
  ordered points, reports distance/duration and warnings, supports destination
  stop editing/reordering/deletion and leaves the current route unchanged on
  cancel.
- #38: the relay now stores encrypted per-installation APNs/FCM registrations,
  derives role targeting from the durable journal, deduplicates provider
  attempts, minimises lock-screen data and exposes aggregate outcomes. The app
  has native APNs/FCM bridges, registration rotation/revocation, tap routing and
  ride-scoped notification preferences.

Trusted external observers remain excluded from push targeting until their
separate authorisation/privacy issue exists.

## Verified

```bash
cd apps/mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --debug
```

The full Flutter suite passes (309 tests). Android also builds with a complete
dummy FCM dart-define set, exercising generated Firebase resource values.

```bash
cd apps/server
uv sync --frozen --extra dev
uv run ruff format --check .
uv run ruff check .
uv run python -m pytest -q
```

The full server suite passes (73 tests). Both deployment Compose files render,
the changed workflow/deployment YAML parses, and `git diff --check` passes.

## Remaining evidence

- #34 still benefits from leader usability and mixed-device field feedback.
- #38 must remain open until APNs/FCM credentials are configured in
  pre-production and the real-device locked/background/terminated, denied
  permission, reconnect and token-rotation matrix in
  `docs/push-notifications.md` is recorded.
- Simulator builds prove compilation only; they are not evidence of push
  delivery or background reliability.
- The full Nearby, background, battery, route-alert and vehicle-interface gates
  in `PLAN.md` and `docs/field-test-plan.md` remain authoritative.
