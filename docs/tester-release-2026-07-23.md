# Tester build notes — 23 July 2026

## What to test

1. Create a route on the web planner, choose **Create app code**, and verify
   that copy, email and editable-link options appear.
2. In the app, choose **Create a ride**, enter that code in **Planned route
   code**, and confirm that the fetched route opens for review.
3. Confirm that route review and **Record a route** show the configured map
   beneath their geometry, and that the group mini-map appears when rider
   locations exist even before a route has been selected.
4. Confirm that the review says **Visual turn-by-turn ready**, then start the
   ride near the route and verify the upcoming-turn banner advances through
   real manoeuvres without jumping backwards.
5. Run a real ride with at least two location fixes, end it, remove the live
   ride, then open **Previous rides** from the home screen.
6. Confirm that the archived map fits the complete planned route and your
   recorded trail, including routes that cross themselves.
7. Restart the app and confirm the archived ride remains available.
8. Export its GPX to Files/Downloads, reopen it in a GPX-capable app, and then
   export it a second time.
9. Delete one archived ride and confirm that other archived rides remain.
10. Open **Navigate or export** and verify the Harley-Davidson option explains
   that it uses the native GPX share sheet.
11. On CarPlay, confirm the Driving Task companion shows a bounded ride-status
   snapshot and that the phone remains the full interactive map.

## Expected limitations

- The UK speed-camera/police feed is not enabled yet. Cyclops partner sandbox
  access and redistribution terms are required before real provider data can
  be shown.
- Posted speed limits and automatic incident rerouting remain unavailable
  until their provider integration is complete.
- CarPlay native maps and CarPlay-hosted turn-by-turn require Apple's separate
  CarPlay Navigation entitlement; this build uses the approved Driving Task
  companion.
- Push delivery is enabled only when the relevant APNs/FCM repository and
  server credentials are configured. The in-app event journal remains the
  source of truth.
- Remote observer access is not enabled in this build. It requires a separate,
  explicitly consented and revocable observer credential rather than reusing a
  rider join code.

## Privacy check

Completed rides stay on the device until explicitly deleted. The archive
contains the local rider's trail and optional planned route, not invitation
secrets, join tokens, another rider's trail, or a permanent relay copy.
