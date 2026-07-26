# Tester guide: getting updates and reporting which build you are on

This is the tester-facing guide. The maintainer-facing release procedure is in
[android-internal-testing.md](./android-internal-testing.md).

Read this once before your first test ride, then use
[Reporting a bug](#reporting-a-bug) every time you report something.

## 1. Join internal testing

**Android (Google Play internal testing)**

1. Ask the maintainer for the internal-testing **opt-in link**. It is
   specific to this app and to the Google account you will test with.
2. Open the link on the phone you will ride with, signed in to that same
   Google account, and accept the invitation.
3. Follow the **download it on Google Play** link from the opt-in page and
   install Tail End Charlie.
4. Keep the opt-in link. If you ever leave the programme, or reinstall on a new
   phone, you need it again.

**iOS (TestFlight)**

1. Install **TestFlight** from the App Store.
2. Open the TestFlight invitation the maintainer sends, accept it, and install
   Tail End Charlie from inside TestFlight.
3. Turn on **Automatic Updates** in TestFlight's settings so new builds install
   themselves.

The two channels behave differently and that is expected: TestFlight tells you
about new builds and can install them automatically; Play internal testing does
neither.

## 2. Check which build you are on

The build identity is on the home screen and never more than two taps away:

- **Home screen**, under the buttons: `1.0.1 (build 137) · Play internal
  testing`. Tap it to open the full detail.
- **Settings** (gear icon) → **About & build**.

That screen shows:

| Field                 | What it means                                            |
| --------------------- | -------------------------------------------------------- |
| App version           | The marketing version, e.g. `1.0.1`.                     |
| Build number          | The number that actually identifies your build, e.g. `137`. |
| Distribution track    | Where the build came from: Play internal testing, TestFlight, CI, or a local build. |
| Built                 | When the build was produced, and how old it is.          |
| Relay endpoint        | The host of the ride relay this build talks to. Host only, deliberately - never a full address. |
| Last relay sync       | The last time this app successfully exchanged ride events with the relay in this session. |

**Copy build details for a bug report** puts all of it on the clipboard.

## 3. Get the newer build

If the app shows **"A newer tester build is probably available"** on the home
screen or on About & build, tap **Open Google Play** (or **Open TestFlight** on
iOS) and update.

The app judges this from how old your build is, not from asking the store, so
treat it as a prompt to check rather than a guarantee. Play internal testing has
no way to force an update, so **checking is always worth doing before a test
ride**, banner or no banner.

### Android: why Play may show no update immediately

All of these are normal, not bugs:

- **Play has not noticed yet.** A newly uploaded internal-testing build can
  take a few minutes to appear for your account, occasionally longer.
- **You are signed in as the wrong account.** The invitation is per Google
  account. Play shows internal releases only to accounts on the tester list.
- **You have not accepted the invitation on this device.** Accepting it on a
  laptop does not enrol the phone's account.
- **Play cached the old listing.** See the force-check steps below.

### Android: how to force a check

1. Open **Google Play**.
2. Tap your profile picture → **Manage apps & device** → **Updates
   available**, and pull down to refresh.
3. If Tail End Charlie is not listed, open its store page directly - the
   in-app **Open Google Play** button goes straight there - and look for
   **Update**.
4. Still nothing? Force-stop Google Play (Settings → Apps → Google Play Store →
   Force stop), reopen it, and repeat step 2.
5. Still nothing after ten minutes? Tell the maintainer, and include your build
   number and the Google account you are testing with. Do not clear Play Store
   storage or uninstall the app - you would lose your ride history for no
   benefit.

### iOS: how to force a check

1. Open **TestFlight** and pull to refresh.
2. Tail End Charlie shows **Update** when a newer build is available.
3. If TestFlight says the build expired, ask for a new one. TestFlight builds
   expire after 90 days; Play internal-testing builds do not.

## 4. Reporting a bug

Every report must say which build it is on, otherwise it cannot be matched to
the code that caused it.

1. Open **Settings → About & build** and tap **Copy build details for a bug
   report**.
2. Paste that into the report. It looks like:

   ```
   Tail End Charlie 1.0.1+137 · Play internal testing · android
   Built: 24/07/2026 · 1 day old
   Relay: relay.tailendcharlie.app
   Last relay sync: 25/07/2026 09:30 · 30 min ago
   ```

3. Add what you expected, what happened, and roughly when - the relay keeps
   ride events, so a timestamp helps.
4. Say whether you had a data signal at the time, and whether the ride was a
   real ride or the simulator.

If a bug disappears after you update, say so and give **both** build numbers.

## 5. What changed in which build

Per-build tester notes live in
[tester-release-notes.md](./tester-release-notes.md), newest first, keyed by the
same build number the app shows you. **What changed in this build** on the
About & build screen opens it.

## Known differences between the two channels

| | Android (Play internal) | iOS (TestFlight) |
| --- | --- | --- |
| Told about new builds | No | Yes, with a notification |
| Automatic updates | Only via Play's general auto-update setting | Yes, per-app in TestFlight |
| Forced updates | Never | Never |
| Builds expire | No | After 90 days |
| Install path | Google Play listing | TestFlight app |

The app's update prompt is deliberately non-blocking on both platforms. The
only hard block is a build the relay reports as genuinely incompatible, which
shows **App update required** and cannot be dismissed - that one you must act
on before the app will sync.
