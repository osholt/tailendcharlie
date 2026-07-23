# Tester build notes — 23 July 2026

## What to test

1. Plan or import a route and confirm that the upcoming-turn banner advances
   through real manoeuvres without jumping backwards.
2. Run a real ride with at least two location fixes, end it, remove the live
   ride, then open **Previous rides** from the home screen.
3. Confirm that the archived map fits the complete planned route and your
   recorded trail, including routes that cross themselves.
4. Restart the app and confirm the archived ride remains available.
5. Export its GPX to Files/Downloads, reopen it in a GPX-capable app, and then
   export it a second time.
6. Delete one archived ride and confirm that other archived rides remain.
7. Open **Navigate or export** and verify the Harley-Davidson option explains
   that it uses the native GPX share sheet.
8. On CarPlay, confirm the Driving Task companion shows a bounded ride-status
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

## Privacy check

Completed rides stay on the device until explicitly deleted. The archive
contains the local rider's trail and optional planned route, not invitation
secrets, join tokens, another rider's trail, or a permanent relay copy.
