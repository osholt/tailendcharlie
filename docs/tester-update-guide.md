# Tester guide: getting updates and reporting which build you are on

This is the tester-facing guide. The maintainer-facing release procedure is in
[android-internal-testing.md](./android-internal-testing.md).

Android testers are on Google Play **closed testing** - the `alpha` track. That
is not the same thing as the public Play listing, and it is not the same thing
as Play "internal testing": a closed build is only offered to a Google account
that has opted in through the closed-testing link below. iOS testers are on
TestFlight.

Read this once before your first test ride, then use
[Reporting a bug](#5-reporting-a-bug) every time you report something.

## 1. Join closed testing

**Android (Google Play closed testing)**

The opt-in link is the same for every tester:

```
https://play.google.com/apps/testing/app.tailendcharlie
```

1. Open that link on the phone you will ride with, signed in to the same Google
   account you gave the maintainer. The invitation is per Google account, so
   accepting it on a laptop does not enrol the phone's account.
2. Accept the invitation on that page.
3. Follow the page's download link ("Download it on Google Play") and install
   Tail End Charlie.
4. Keep the link. You need it again after a reinstall, on a new phone, or if you
   ever leave and rejoin the programme.

Searching the Play Store for Tail End Charlie is not how you get it: until your
account has opted in, the public listing does not offer you the app at all.

**iOS (TestFlight)**

1. Install **TestFlight** from the App Store.
2. Open the TestFlight invitation the maintainer sends, accept it, and install
   Tail End Charlie from inside TestFlight.
3. Turn on **Automatic Updates** in TestFlight's settings so new builds install
   themselves.

The two channels behave differently and that is expected: TestFlight tells you
about new builds and can install them automatically; Play closed testing does
neither, which is why closed testers get an email instead (section 4).

## 2. Check which build you are on

The build identity is on the home screen and never more than two taps away:

- **Home screen**, under the buttons: `1.0.1 (build 137) · Play closed testing
  (alpha)`. Tap it to open the full detail.
- **Settings** (gear icon) → **About & build**.

That screen shows:

| Field                 | What it means                                            |
| --------------------- | -------------------------------------------------------- |
| App version           | The marketing version, e.g. `1.0.1`.                     |
| Build number          | The number that actually identifies your build, e.g. `137`. On Android this is the Play version code. |
| Distribution track    | Where the build is distributed: Play closed testing (alpha) or (beta), Play internal testing, TestFlight, CI, or a local build. |
| Built                 | When the build was produced, and how old it is.          |
| Relay endpoint        | The host of the ride relay this build talks to. Host only, deliberately - never a full address. |
| Last relay sync       | The last time this app successfully exchanged ride events with the relay in this session. |

**Copy build details for a bug report** puts all of it on the clipboard.

If **Distribution track** says something other than what you expect - for
instance "Play internal testing" when the release email said closed testing -
that is worth reporting: the track shown is the track the build was released
to, so a mismatch means something in the release went wrong.

## 3. Get the newer build

If the app shows **"A newer tester build is probably available"** on the home
screen or on About & build, tap the update button and update:

- On a closed-testing build the button is **Open closed testing page**, and it
  opens the opt-in link above - the page that can actually offer you the build.
- On iOS it is **Open TestFlight**.

The app judges this from how old your build is, not from asking the store, so
treat it as a prompt to check rather than a guarantee. Play never forces an
update on a closed-testing build, so **checking is always worth doing before a
test ride**, banner or no banner.

### Android: why Play may show no update immediately

All of these are normal, not bugs:

- **This device's account has not opted in.** The single most common cause. Open
  the closed-testing link on the phone itself and accept it there.
- **You are signed in as the wrong account.** Play offers a closed release only
  to accounts on the tester list.
- **Play has not noticed yet.** A newly promoted closed-testing build can take a
  few minutes to appear for your account, occasionally longer.
- **Play cached the old listing.** See the force-check steps below.

### Android: how to force a check

1. Open the closed-testing opt-in page on the phone -
   `https://play.google.com/apps/testing/app.tailendcharlie` - and follow its
   download link. That is the in-app **Open closed testing page** button.
2. In **Google Play**, tap your profile picture → **Manage apps & device** →
   **Updates available**, and pull down to refresh.
3. Still nothing? Force-stop Google Play (Settings → Apps → Google Play Store →
   Force stop), reopen it, and repeat step 2.
4. Still nothing after ten minutes? Tell the maintainer, and include your build
   number and the Google account you are testing with. Do not clear Play Store
   storage or uninstall the app - you would lose your ride history for no
   benefit.

### iOS: how to force a check

1. Open **TestFlight** and pull to refresh.
2. Tail End Charlie shows **Update** when a newer build is available.
3. If TestFlight says the build expired, ask for a new one. TestFlight builds
   expire after 90 days; Play closed-testing builds do not.

## 4. Release emails

When a build reaches the Android closed track, the tester group gets an email
with the version, the build number, what changed since the previous release, the
opt-in link, and the exact three values **About & build** must show once you have
updated. Check those three values after updating: if they do not match the email,
you are still on the old build.

iOS testers do not get this email. TestFlight already notifies its own testers
when a build is available, and two notifications for one release is noise.

## 5. Reporting a bug

Every report must say which build it is on, otherwise it cannot be matched to
the code that caused it.

1. Open **Settings → About & build** and tap **Copy build details for a bug
   report**.
2. Paste that into the report. It looks like:

   ```
   Tail End Charlie 1.0.1+137 · Play closed testing (alpha) · android
   Built: 24/07/2026 · 1 day old
   Relay: relay.tailendcharlie.app
   Last relay sync: 25/07/2026 09:30 · 30 min ago
   ```

3. Add what you expected, what happened, and roughly when - the relay keeps
   ride events, so a timestamp helps.
4. Say whether you had a data signal at the time, and whether the ride was a
   real ride or the simulator.

If a bug disappears after you update, say so and give **both** build numbers.

## 6. What changed in which build

Per-build tester notes live in
[tester-release-notes.md](./tester-release-notes.md), newest first, keyed by the
same build number the app shows you. **What changed in this build** on the
About & build screen opens it.

## If you are on Play internal testing instead

A few accounts may be on Play's **internal testing** track rather than closed
testing - it is a separate track with its own tester list, and a build reaches it
before being promoted to closed testing.

- Its opt-in link is a different, per-app internal-testing URL, not the
  `apps/testing` link above. Ask the maintainer for it.
- The app shows **Play internal testing** as the distribution track, and its
  update button is **Open Google Play listing**, because an internal tester who
  has accepted the invitation is offered the build from the listing itself.
- To force a check: Google Play → profile picture → **Manage apps & device** →
  **Updates available**, pull to refresh.
- Internal-testing releases are not covered by the release email in section 4.

Everything else in this guide - build identity, bug reports, tester notes -
applies unchanged.

## Known differences between the channels

| | Android (Play closed testing) | Android (Play internal) | iOS (TestFlight) |
| --- | --- | --- | --- |
| Told about new builds | Yes, by email to the tester group | No | Yes, with a notification |
| Automatic updates | Only via Play's general auto-update setting | Only via Play's general auto-update setting | Yes, per-app in TestFlight |
| Forced updates | Never | Never | Never |
| Builds expire | No | No | After 90 days |
| Install path | Closed-testing opt-in link | Google Play listing | TestFlight app |

The app's update prompt is deliberately non-blocking on every channel. The only
hard block is a build the relay reports as genuinely incompatible, which shows
**App update required** and cannot be dismissed - that one you must act on
before the app will sync.

Play's own pages occasionally change their wording; the link and the sequence
are what matter, not the exact button text.
