# Ride push notifications

Tail End Charlie can use APNs on iOS and FCM on Android to wake relevant
participants for selected durable ride alerts. Push is an optional,
best-effort hint: the authenticated event journal remains the source of truth
and is synchronised when the app opens.

Push does not replace emergency services, an agreed group safety plan, or
checking the in-app ride state. Delivery can be delayed or suppressed by the
operating system, network, provider or user settings.

## Targeting policy

The relay derives current roles from authenticated ride events. It excludes
the sending installation, riders whose membership is left or expired, and
revoked registrations.

| Durable event | Default recipients | Preference |
| --- | --- | --- |
| Emergency stop or assistance | Explicit recipients, otherwise lead and Tail End Charlie | Critical; app preference cannot suppress |
| Stopped, mechanical, fuel or blocked route | Explicit recipients, otherwise lead and Tail End Charlie | Safety |
| Urgent off-course | Affected rider, lead and Tail End Charlie | Safety |
| Critical off-course | Current group when the event audience is all riders | Critical; app preference cannot suppress |
| Marker started or ended | Lead and Tail End Charlie | Ride status |
| All passed or resolved | Lead, Tail End Charlie and current marker | Ride status |
| Ride paused, resumed or ended | Current group | Administrative |
| ICE information shared | Explicit recipients, or the current group for an explicit group share | Critical; lock-screen text contains no ICE data |

Trusted external watchers never receive push registrations or notifications.
Their separate personal/group observer credential reads only the current
bounded snapshot. A ride code or ordinary group bearer credential must not be
repurposed as an observer credential.

Repeated delivery of the same durable event to the same registration is
deduplicated in PostgreSQL. The `/metrics` endpoint reports only aggregate
`ride_relay_push_deliveries_total` outcomes. Per-attempt database rows retain
provider-safe status/error codes without tokens, coordinates, secrets or
medical content.

## Server configuration

Apply migration `0005`, then configure one or both providers in the deployment
environment. Provider settings are all-or-nothing; a partially configured
provider stops server startup rather than silently disabling delivery.

For APNs:

```text
RIDE_RELAY_APNS_TEAM_ID=<Apple team ID>
RIDE_RELAY_APNS_KEY_ID=<APNs key ID>
RIDE_RELAY_APNS_BUNDLE_ID=app.tailendcharlie
RIDE_RELAY_APNS_PRIVATE_KEY_BASE64=<base64 of the APNs .p8 PEM file>
RIDE_RELAY_APNS_SANDBOX=false
```

Use `RIDE_RELAY_APNS_SANDBOX=true` only for development-signed apps. TestFlight
and App Store builds use the production APNs environment.

For FCM HTTP v1:

```text
RIDE_RELAY_FCM_PROJECT_ID=<Firebase project ID>
RIDE_RELAY_FCM_CLIENT_EMAIL=<service-account email>
RIDE_RELAY_FCM_PRIVATE_KEY_BASE64=<base64 of the service-account private-key PEM>
```

The APNs key and FCM service-account key are server secrets. Keep them in the
host environment or secret manager, never in Git. Use independent Firebase
projects/provider credentials for production and pre-production where
possible. At minimum, keep their databases, encryption keys, APNs environment
and FCM registrations separate.

## Mobile build configuration

The Flutter client uses a small native bridge on each platform. iOS registers
directly with APNs, which avoids coupling the existing Nearby Swift package to
the Firebase iOS SDK. Android uses the native FCM SDK and creates its Firebase
options from public build-time values.

Enable iOS push with:

```text
--dart-define=RIDE_RELAY_PUSH_ENABLED=true
--dart-define=RIDE_RELAY_FIREBASE_IOS_APP_ID=<iOS app ID>
```

The app ID is a public build gate identifying the configured iOS app; APNs
registration itself uses the signed Push Notifications entitlement.

Enable Android push with the complete public Firebase option set:

```text
--dart-define=RIDE_RELAY_PUSH_ENABLED=true
--dart-define=RIDE_RELAY_FIREBASE_API_KEY=<public Firebase API key>
--dart-define=RIDE_RELAY_FIREBASE_PROJECT_ID=<project ID>
--dart-define=RIDE_RELAY_FIREBASE_MESSAGING_SENDER_ID=<sender ID>
--dart-define=RIDE_RELAY_FIREBASE_ANDROID_APP_ID=<Android app ID>
```

The TestFlight and Android internal workflows read these values from GitHub
Actions repository variables and enable push only when the relevant platform
configuration is present.

The iOS App ID and provisioning profile must include Push Notifications. Debug
and profile builds use the development APNs entitlement; release builds use
production. Android 13+ asks for `POST_NOTIFICATIONS` and creates separate
high-priority safety and ordinary ride-update channels.

Tokens are encrypted separately from the event journal, scoped to a
pseudonymous installation identity for one ride, refreshed after rotation or
app resume, and revoked on leaving or ending a ride. Notification preferences
are available from the active ride menu. Foreground OS presentation is
disabled so the existing in-app alert is not duplicated.

## Required real-device gate

Automated tests cover registration, encryption, targeting, preferences,
deduplication, revoked tokens and tap routing. Before claiming support, repeat
the following on physical iOS and Android devices against pre-production:

1. Locked screen, background and terminated-app delivery.
2. Tap opens the authorised active ride and Safety view.
3. Foreground alerts appear once through the in-app UI.
4. Permission denied, later enabled, and revoked-permission behaviour.
5. Network loss/reconnect and delayed provider delivery.
6. Token rotation/reinstall and invalid-token revocation.
7. Leave and ride-end exclusion.

Record device/OS/build/provider evidence in the field-test notes. Simulator
success is not evidence for APNs or FCM background reliability.
