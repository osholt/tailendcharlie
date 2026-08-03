#!/usr/bin/env bash
# Brings up Apple's CarPlay simulator and, optionally, installs and launches
# Tail End Charlie on it.
#
# Usage:
#   tools/carplay-simulator.sh                     # bring the CarPlay display up
#   tools/carplay-simulator.sh --install <app>     # ...and install/launch a built .app
#   tools/carplay-simulator.sh --shot <file.png>   # ...and save a screenshot of the head unit
#   tools/carplay-simulator.sh --recreate          # discard and rebuild the device first
#
# Environment:
#   CARPLAY_SIM_NAME     device name to use          (default "Tail End Charlie CarPlay")
#   CARPLAY_SIM_TYPE     simctl device type          (default iPhone-17-Pro)
#   CARPLAY_SIM_RUNTIME  simctl runtime              (default the newest installed iOS)
#
# Three things make this fail, and none of them are the app. They are the
# reason this script exists rather than a line in the docs saying "use the
# I/O menu":
#
#   1. `I/O > External Displays > CarPlay` acts on Simulator.app's *key device
#      window*. With no key window every item in that menu is disabled, and a
#      scripted click on it is accepted and silently does nothing. The device
#      window therefore has to be raised and the app made frontmost first.
#   2. CoreSimulatorService wedges. Once it does, `simctl boot` fails with
#      "launchd_sim may have crashed or quit responding" and plain `simctl`
#      commands hang, so the display can never be attached. Restarting the
#      service is the only fix, and it must happen before anything else.
#   3. A simulator device that has been through a wedged service keeps failing
#      afterwards: `carkitd` receives a session with a null identity and a 0x0
#      screen, discards it as partial, and the CarPlay window stays black
#      forever. A device created after the restart works. That is why this
#      script owns its own device rather than using whichever one is booted.
#
# Note for anyone screenshotting the result: `screencapture -l <window-id>` of
# the CarPlay window returns solid black. `--shot` reads CoreSimulator's
# external display pixels instead.
set -euo pipefail

DEVICE_NAME="${CARPLAY_SIM_NAME:-Tail End Charlie CarPlay}"
DEVICE_TYPE="${CARPLAY_SIM_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
APP_PATH=""
SHOT_PATH=""
RECREATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install) APP_PATH="${2:?--install needs a path to a built .app}"; shift 2 ;;
    --shot) SHOT_PATH="${2:?--shot needs a path to write a .png to}"; shift 2 ;;
    --recreate) RECREATE=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '==> %s\n' "$*"; }

# Quartz is provided by PyObjC, and the first `python3` on PATH is not
# necessarily the one that has it. Find a working interpreter once instead of
# emitting the same ModuleNotFoundError throughout the window-detection loops.
QUARTZ_PYTHON="${CARPLAY_QUARTZ_PYTHON:-}"
if [ -z "$QUARTZ_PYTHON" ]; then
  while IFS= read -r candidate; do
    if "$candidate" -c 'import Quartz' >/dev/null 2>&1; then
      QUARTZ_PYTHON="$candidate"
      break
    fi
  done < <(which -a python3 2>/dev/null | awk '!seen[$0]++')
fi
[ -n "$QUARTZ_PYTHON" ] || {
  echo "No Python interpreter with the PyObjC Quartz module was found." >&2
  echo "Set CARPLAY_QUARTZ_PYTHON to one that can run: import Quartz" >&2
  exit 1
}

# Deliberately NOT the newest runtime. On iOS 26.x, opening any CarPlay app whose
# root is a CPMapTemplate aborts CarPlayTemplateUIHost:
#
#   -[CPSTemplateInstance vehicleSupportsDestinationSharing]: unrecognized
#   selector, from -[CPSMapTemplateViewController _updateShareButtonVisibility]
#   via _configureNavigationBarShareButton in _viewDidLoad
#
# The head unit bounces straight back to its home screen, which reads as "our
# app crashes". It is Apple's code, it runs unconditionally for a map template,
# and no app-side property reaches it - `mapTemplateShouldProvideNavigationMetadata`
# returning false gives a byte-identical stack. Destination sharing is iOS 26.1+
# API (`CPTrip.hasShareableDestination`), so the crashing path does not exist on
# older runtimes, and the app's deployment target is 16.0.
#
# Override with CARPLAY_SIM_RUNTIME to test a specific runtime deliberately.
best_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [
    r for r in json.load(sys.stdin)["runtimes"]
    if r["isAvailable"] and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")
]
def version(runtime):
    return [int(part) for part in runtime["version"].split(".")]
runtimes.sort(key=version)
usable = [r for r in runtimes if version(r)[0] < 26]
# Falling back to the newest rather than refusing: a machine with only iOS 26
# installed should still get a CarPlay display, with the crash explained.
print((usable or runtimes)[-1]["identifier"] if runtimes else "")
'
}
RUNTIME="${CARPLAY_SIM_RUNTIME:-$(best_runtime)}"
case "$RUNTIME" in
  *iOS-2[6-9]*)
    echo "Warning: $RUNTIME crashes CarPlayTemplateUIHost on a map template." >&2
    echo "         See the comment in $0 and docs/build-and-run.md." >&2
    ;;
esac
[ -n "$RUNTIME" ] || { echo "No iOS simulator runtime is installed." >&2; exit 1; }

# 1. A healthy CoreSimulatorService. `simctl list` is the cheapest call that
# hangs when the service is wedged, so it doubles as the health check.
log "Checking CoreSimulatorService"
if ! timeout 20 xcrun simctl list devices >/dev/null 2>&1; then
  log "CoreSimulatorService is not responding - restarting it"
  osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
  pkill -9 -x Simulator 2>/dev/null || true
  killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true
  sleep 5
  timeout 30 xcrun simctl list devices >/dev/null 2>&1 \
    || { echo "CoreSimulatorService is still not responding." >&2; exit 1; }
fi

# 2. The device. Owned by this script so it is always one created after the
# most recent service restart.
udid_for_name() {
  xcrun simctl list devices -j | python3 -c '
import json,sys
name=sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == name and d.get("isAvailable"):
            print(d["udid"]); break
' "$DEVICE_NAME"
}

UDID="$(udid_for_name || true)"
if [ "$RECREATE" = 1 ] && [ -n "$UDID" ]; then
  log "Deleting the existing $DEVICE_NAME device"
  xcrun simctl delete "$UDID"
  UDID=""
fi
if [ -z "$UDID" ]; then
  log "Creating $DEVICE_NAME"
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")"
fi
log "Device $DEVICE_NAME ($UDID)"

if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  log "Booting"
  xcrun simctl bootstatus "$UDID" -b
fi

open -a Simulator
# Simulator.app needs a moment to adopt the booted device before its window
# exists to be raised.
for _ in $(seq 1 30); do
  if "$QUARTZ_PYTHON" - "$DEVICE_NAME" <<'PY'
import sys, Quartz
name = sys.argv[1]
wl = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
sys.exit(0 if any(w.get('kCGWindowOwnerName') == 'Simulator'
                  and w.get('kCGWindowName') == name for w in wl) else 1)
PY
  then break; fi
  sleep 1
done

# Install before attaching the external display. CarPlay's app catalogue is
# built when the session starts; replacing an app afterwards can remove its old
# entry without adding the new scene until the next attach.
if [ -n "$APP_PATH" ]; then
  [ -d "$APP_PATH" ] || { echo "No app bundle at $APP_PATH" >&2; exit 1; }
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
  log "Installing $BUNDLE_ID"
  xcrun simctl install "$UDID" "$APP_PATH"
  log "Launching $BUNDLE_ID"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
fi

# 3. The CarPlay display. Disabled first, so the display is rebuilt even when
# the menu already claims CarPlay is selected - a stale checkmark with no
# window is exactly the state a wedged service leaves behind.
carplay_window() {
  "$QUARTZ_PYTHON" - "$DEVICE_NAME" <<'PY'
import sys, Quartz
name = sys.argv[1]
wl = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
# The head unit is the device's only landscape window. Matching on shape rather
# than title keeps this working whether or not "Show Device Bezels" is on.
for w in wl:
    if w.get('kCGWindowOwnerName') == 'Simulator' and w.get('kCGWindowName') == name:
        b = w['kCGWindowBounds']
        if b['Width'] > b['Height']:
            print(int(w['kCGWindowNumber']))
            break
PY
}

# Set the display, once. The menu acts on Simulator.app's key device window, so
# with more than one device booted the *named* device's own window has to be
# raised first - otherwise the CarPlay display silently lands on somebody
# else's simulator, or the click is accepted and does nothing at all.
set_display() {
  osascript - "$DEVICE_NAME" "$1" <<'APPLESCRIPT' >/dev/null
on run argv
  set deviceName to item 1 of argv
  set choice to item 2 of argv
  tell application "System Events" to tell process "Simulator"
    set frontmost to true
    delay 1
    my raiseDevice(deviceName)
    set carPlayMenu to menu 1 of menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1
    set menuChoice to choice
    if choice is "CarPlay" and not (exists menu item "CarPlay" of carPlayMenu) then
      if exists menu item "CarPlay…" of carPlayMenu then
        set menuChoice to "CarPlay…"
      end if
    end if
    -- Enablement is recomputed when the menu is opened, and lags the window
    -- becoming key by a beat. Give it one, rather than reading "disabled" off a
    -- Simulator that is simply still settling.
    set ready to false
    repeat 10 times
      if enabled of menu item menuChoice of carPlayMenu then
        set ready to true
        exit repeat
      end if
      delay 0.5
      my raiseDevice(deviceName)
    end repeat
    if not ready then
      error "The External Displays menu is disabled - Simulator.app has no key device window."
    end if
    click menu item menuChoice of carPlayMenu
    if menuChoice is "CarPlay…" then
      delay 1
      click button "Run" of window "TV Out Extended Setup"
    end if
  end tell
  delay 4
end run

-- Raises the phone window belonging to one device. Its Window-menu entry is
-- "<device> - iOS <version>"; the head unit's is "<device> - CarPlay".
on raiseDevice(deviceName)
  tell application "System Events" to tell process "Simulator"
    set frontmost to true
    repeat with m in menu items of menu 1 of menu bar item "Window" of menu bar 1
      set n to name of m
      if n is not missing value then
        if n starts with deviceName and n does not end with "CarPlay" then
          click m
          delay 1
          return
        end if
      end if
    end repeat
    error "No Simulator window for " & deviceName
  end tell
end raiseDevice
APPLESCRIPT
}

# Disabled first, so the display is rebuilt even when the menu already claims
# CarPlay is selected - a stale checkmark with no window is exactly the state a
# wedged service leaves behind. Then retry the attach: the click is delivered
# through the accessibility API and is occasionally swallowed while the
# Simulator is still settling.
log "Attaching the CarPlay display"
if [ -n "$(carplay_window)" ]; then set_display Disabled; fi
CARPLAY_WINDOW=""
for attempt in 1 2 3; do
  set_display CarPlay
  CARPLAY_WINDOW="$(carplay_window)"
  [ -n "$CARPLAY_WINDOW" ] && break
  log "The CarPlay display did not open (attempt $attempt) - retrying"
  set_display Disabled
done

[ -n "$CARPLAY_WINDOW" ] || { echo "The CarPlay display did not open." >&2; exit 1; }
log "CarPlay display is up (window $CARPLAY_WINDOW)"

if [ -n "$SHOT_PATH" ]; then
  # Window capture returns black and a whole-screen capture can land on another
  # macOS Space. CoreSimulator owns the external display pixels directly.
  xcrun simctl io "$UDID" screenshot --display external "$SHOT_PATH" >/dev/null
  log "Screenshot written to $SHOT_PATH"
fi

log "Done. UDID=$UDID"
