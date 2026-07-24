# Planner app links

Tail End Charlie route emails use the same HTTPS URL that opens the editable
web planner:

```text
https://tailendcharlie.app/planner.html?code=AB12CD34
```

When the mobile app is installed and the platform has verified the domain, the
link opens the app. The app validates the exact production origin and path,
fetches the short-lived plan, and stages its GPX through the existing route
review flow. A leader already in a ride must still review and confirm a route
replacement. Without the app, the same URL continues to open the web planner.

Invalid and expired links show a recoverable message and direct the rider to
the existing manual **Change route → Load a planned route** code entry.

## Domain association

The website publishes:

- `/.well-known/apple-app-site-association` for
  `UY4624PH6X.app.tailendcharlie`
- `/.well-known/assetlinks.json` for `app.tailendcharlie`

Both files must be served directly over HTTPS as `application/json`, without a
redirect. The checked-in Android association includes both the Play App Signing
certificate and the local debug certificate so Play-distributed and development
builds can be exercised. The upload-key fingerprint is intentionally excluded:
Google signs tester downloads with the Play App Signing key, not the upload key.

iOS development and distribution provisioning profiles must be regenerated
after enabling **Associated Domains** for `app.tailendcharlie`. Verify the new
profiles retain Push Notifications and the existing CarPlay driving-task
entitlement as well as `applinks:tailendcharlie.app`.

## Release verification

After the website association files are deployed:

1. Open an emailed planner link on a physical iPhone with a freshly provisioned
   development build, then repeat with the TestFlight build.
2. Test both a cold launch and a warm launch. Confirm a current code reaches
   route review, an expired code gives the manual-code fallback, and cancelling
   review leaves an active ride route unchanged.
3. Install the Play-distributed Android build and run:

   ```bash
   adb shell pm verify-app-links --re-verify app.tailendcharlie
   adb shell pm get-app-links app.tailendcharlie
   adb shell am start -a android.intent.action.VIEW \
     -d 'https://tailendcharlie.app/planner.html?code=AB12CD34' \
     app.tailendcharlie
   ```

4. Uninstall the app and confirm the same URL opens the editable web planner.

The mobile parser and controller lifecycle are covered by
`test/services/planner_link_channel_test.dart` and
`test/controllers/shared_route_controller_test.dart`.
