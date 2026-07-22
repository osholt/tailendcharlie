# Tail End Charlie route planner

A static, dependency-free page for prepping a ride's GPX route from a
desktop browser: upload, preview, trim/reverse/delete points, and generate a
short plan code. No build step, no third-party network calls, no client-side
framework — same philosophy as `apps/website`.

It only talks to the relay's `/api/v1/plans` endpoints and never creates or
touches a live ride; see `docs/` in the repo root for the full design
rationale. Deployed alongside the relay server behind the same Caddy
instance, at `/plan/`.
