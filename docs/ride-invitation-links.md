# Ride invitation links

Tail End Charlie shares a private HTTPS invitation in this form:

```text
https://tailendcharlie.app/join.html#123456%23HIGH_ENTROPY_RESOLVE_TOKEN
```

The six-digit code and resolve token are the same private invitation accepted by
the existing paste-to-join flow. The token is after the first `#`, as part of the
URL fragment. A browser does not send that fragment to Cloudflare Pages, web
server logs or referrer headers. Do not move it into the path or query.

The installed app validates the exact HTTPS origin and `/join.html` path, decodes
one exact `code#token` fragment, then asks the rider before calling the normal
server-validated join-code directory. This has three useful properties:

- an inactive, expired or revoked invitation gets the directory's plain-language
  response rather than creating a stale local ride;
- joining has the same authenticated ride secret and transport state as pasting
  the private invitation; and
- copying the complete URL into the existing **Paste** action still works.

The URL is not the offline invitation. **Show QR** carries a full
`RideJoinPayload` and the in-app scanner can join without a relay lookup. The
tappable link intentionally retains server validation.

## Active rides and first launch

The native bridge queues one cold- or warm-start link until Dart consumes it.
The app waits for journal restoration and onboarding to finish, then shows the
ride code and requires **Join ride** confirmation. A current ride is never
silently replaced. The rider is told to leave or end it through **Ride actions**
and tap the new invitation again.

Without the app installed, `/join.html` is a static, no-script page explaining
TestFlight and Play closed testing plus the paste fallback. It declares
`no-referrer`, `no-store`, `connect-src 'none'` and does not inspect or transmit
the fragment.

## Domain registration

- iOS: `apple-app-site-association` lists `/join.html` beside `/planner.html` for
  `UY4624PH6X.app.tailendcharlie`; the existing associated-domains entitlement
  covers `applinks:tailendcharlie.app`.
- Android: a separate verified `VIEW`/`BROWSABLE` intent filter covers
  `https://tailendcharlie.app/join.html`; `assetlinks.json` contains both Play
  App Signing and local debug certificate fingerprints.

## Release verification

After the website and app build are deployed:

1. Share a fresh invitation through WhatsApp and through an email client.
2. On iOS and Android, test cold launch, warm launch, decline and confirmed join.
3. Confirm the joined session has internet/nearby authenticated credentials, not
   a short-code-only degraded state.
4. Tap a malformed and an inactive/revoked invitation and check the explanation.
5. Tap a different invitation while a ride is active; confirm the current ride
   remains unchanged.
6. Uninstall the app and confirm the same link opens the static install/help page
   without any request containing the fragment.
7. On Android, also verify association and dispatch directly:

   ```bash
   adb shell pm verify-app-links --re-verify app.tailendcharlie
   adb shell pm get-app-links app.tailendcharlie
   adb shell am start -a android.intent.action.VIEW \
     -d 'https://tailendcharlie.app/join.html#123456%23TOKEN_WITH_16_CHARS' \
     app.tailendcharlie
   ```

Parser, lifecycle, active-ride and fallback-page behavior are covered by the
`ride_invitation_link_*` Flutter tests and `apps/website/app-links.test.mjs`.
