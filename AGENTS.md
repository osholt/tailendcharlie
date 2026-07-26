# Tail End Charlie — Codex Instructions

<!-- Current work and verified handoff -->
@docs/next-agent-handoff.md

## Project overview

Tail End Charlie is an offline-first group motorcycle coordination system. The
repository contains a Flutter mobile client, native Swift/Kotlin transport
bridges, a FastAPI/PostgreSQL relay, deployment configuration, and a static
Cloudflare Pages website.

## Before you build or run anything

Read [docs/build-and-run.md](docs/build-and-run.md) **first** if the task
involves building, running on a device or simulator, signing, TestFlight, or a
store upload. It states which configuration to use for which purpose, the
`--dart-define` values a device build needs, the exact commands, and a
symptom-first index of the ways a device build goes wrong. Four points that have
each cost hours:

- An iOS **debug** build cannot be launched from the home screen; a device build
  a person is meant to tap must be `--profile`.
- On iOS, `--release` is signed for the App Store and will not install on a
  development device. `--profile` is the device configuration.
- The CarPlay entitlement and the CarPlay scene declaration in `Info.plist` are a
  matched pair. Removing either alone makes iOS kill the app at launch, and
  automatic signing can never work for this target.
- CI signing is already correct and evidenced on both platforms. Do not "fix" it.

## Entry points

- `PLAN.md` — product scope, acceptance criteria, and release gates.
- `apps/mobile/` — Flutter app and native iOS/Android shells.
- `apps/server/` — relay service and migrations.
- `apps/website/` — static production website.
- `docs/` — architecture, field-test, navigation, release, and runbook detail.

## Narrow verification

```bash
cd apps/mobile
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

```bash
cd apps/server
uv sync --frozen --extra dev
uv run ruff format --check .
uv run ruff check .
uv run pytest
```

## Project rules

- Preserve offline-first event-journal and transport-neutral domain boundaries.
- Do not claim Nearby, background, battery, navigation-device, CarPlay, Android
  Auto, or PiP support without the physical/platform evidence required in the
  corresponding issue and field-test documentation.
- Use only documented provider integrations; GPX sharing remains the safe
  fallback when an official deep integration is unavailable.
- Never commit signing keys, service-account JSON, passwords, or API tokens.
- Treat app identifiers and signing keys as release decisions. Ask before
  creating a store app, changing a permanent identifier, or generating an
  upload key without an agreed encrypted backup.
