#!/usr/bin/env python3
"""Fail CI when machine-checkable CarPlay/Android Auto safeguards regress."""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class ChecklistRow:
    identifier: str
    checked: bool
    status: str
    line: str


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def require_text(
    failures: list[str], relative_path: str, required_fragments: list[str]
) -> None:
    content = read(relative_path)
    for fragment in required_fragments:
        if fragment not in content:
            failures.append(f"{relative_path}: missing {fragment!r}")


def parse_carplay_rows(content: str) -> list[ChecklistRow]:
    row_pattern = re.compile(
        r"^\| \[(?P<done>[ xX])\] \| (?P<id>CP-[A-Z]+-\d+) \|.*"
        r"\| (?P<status>PASS|PARTIAL|FAIL|UNVERIFIED|OPTIONAL) \|"
    )
    rows: list[ChecklistRow] = []
    for line in content.splitlines():
        match = row_pattern.match(line)
        if match:
            rows.append(
                ChecklistRow(
                    identifier=match.group("id"),
                    checked=match.group("done").lower() == "x",
                    status=match.group("status"),
                    line=line,
                )
            )
    return rows


def expand_checklist_ids(text: str) -> set[str]:
    pattern = re.compile(
        r"CP-(?P<category>[A-Z]+)-(?P<start>\d+)"
        r"(?:[–-](?:(?:CP-)?(?P<end_category>[A-Z]+)-)?(?P<end>\d+))?"
    )
    expanded: set[str] = set()
    for match in pattern.finditer(text):
        category = match.group("category")
        start_text = match.group("start")
        end_text = match.group("end")
        if end_text is None:
            expanded.add(f"CP-{category}-{start_text}")
            continue
        if match.group("end_category") not in (None, category):
            continue
        start = int(start_text)
        end = int(end_text)
        width = max(len(start_text), len(end_text))
        for value in range(start, end + 1):
            expanded.add(f"CP-{category}-{value:0{width}d}")
    return expanded


def carplay_checklist(failures: list[str], strict: bool) -> tuple[int, int]:
    content = read("docs/carplay-compliance-checklist.md")
    rows = parse_carplay_rows(content)
    if not rows:
        failures.append("CarPlay checklist contains no machine-readable rows")
        return (0, 0)

    identifiers = [row.identifier for row in rows]
    duplicates = sorted({item for item in identifiers if identifiers.count(item) > 1})
    if duplicates:
        failures.append(f"CarPlay checklist has duplicate IDs: {', '.join(duplicates)}")

    for row in rows:
        if row.checked != (row.status == "PASS"):
            failures.append(
                f"{row.identifier}: checkbox and status disagree ({row.status})"
            )

    traceability = content.split("## 9. Ticket traceability", maxsplit=1)[-1]
    traceability = traceability.split("## 10.", maxsplit=1)[0]
    ticketed_lines = "\n".join(
        line for line in traceability.splitlines() if re.search(r"\[#\d+\]", line)
    )
    mapped = expand_checklist_ids(ticketed_lines)
    missing_tickets = sorted(
        row.identifier for row in rows if not row.checked and row.identifier not in mapped
    )
    if missing_tickets:
        failures.append(
            "Unchecked CarPlay items lack ticket traceability: "
            + ", ".join(missing_tickets)
        )

    required = [row for row in rows if row.status != "OPTIONAL"]
    passed = sum(row.status == "PASS" for row in required)
    if strict:
        remaining = [row.identifier for row in required if row.status != "PASS"]
        if remaining:
            failures.append(
                "Strict CarPlay gate has unresolved required items: "
                + ", ".join(remaining)
            )
    return passed, len(required)


def android_checklist(failures: list[str], strict: bool) -> tuple[int, int]:
    content = read("docs/carplay-compliance-implementation-plan.md")
    section = content.split("## Android Auto compliance baseline", maxsplit=1)[-1]
    section = section.split("### A1.", maxsplit=1)[0]
    pattern = re.compile(
        r"^\| (?P<id>[^|]+?) \| (?P<status>PASS|PARTIAL|FAIL|UNVERIFIED) "
        r"\| (?P<work>.+) \|$"
    )
    rows = [match.groupdict() for line in section.splitlines() if (match := pattern.match(line))]
    if not rows:
        failures.append("Android Auto plan contains no machine-readable baseline rows")
        return (0, 0)

    missing_tickets = [
        row["id"]
        for row in rows
        if row["status"] != "PASS" and re.search(r"#\d+", row["work"]) is None
    ]
    if missing_tickets:
        failures.append(
            "Unresolved Android Auto criteria lack tickets: "
            + ", ".join(missing_tickets)
        )

    passed = sum(row["status"] == "PASS" for row in rows)
    if strict:
        remaining = [row["id"] for row in rows if row["status"] != "PASS"]
        if remaining:
            failures.append(
                "Strict Android Auto gate has unresolved criteria: "
                + ", ".join(remaining)
            )
    return passed, len(rows)


def structural_checks(failures: list[str]) -> None:
    for entitlements in (
        "apps/mobile/ios/Runner/DebugProfile.entitlements",
        "apps/mobile/ios/Runner/Release.entitlements",
    ):
        require_text(
            failures,
            entitlements,
            [
                "com.apple.developer.carplay-driving-task",
                "com.apple.developer.carplay-maps",
            ],
        )

    require_text(
        failures,
        "apps/mobile/ios/Runner/Info.plist",
        [
            "CPTemplateApplicationSceneSessionRoleApplication",
            "CarPlaySceneDelegate",
        ],
    )
    require_text(
        failures,
        "apps/mobile/ios/Runner/CarPlaySceneDelegate.swift",
        [
            "CPMapTemplate()",
            "CarPlayNavigationProjectionV2",
            "CarPlayNavigationProjectionStore",
            "CarPlayRoutePreviewPayload",
            "showTripPreviews(",
            "selectedPreviewFor trip:",
            "startedTrip trip:",
            "updateEstimates(",
            "CarPlayNavigationCoordinator",
            "startNavigationSession(for: trip)",
            "upcomingManeuvers = maneuvers",
            "CPNavigationAlert(",
            "mapTemplateDidCancelNavigation",
            "resumeTrip(updatedRouteInformation:",
            "CPSessionConfiguration(delegate: self)",
            "limitedUserInterfacesChanged",
            "panButton(mapTemplate: mapTemplate)",
            "panBeganWith direction:",
            "mapTemplateDidBeginZoomGesture",
            "mapTemplateDidBeginRotationGesture",
            "mapTemplateDidBeginPitchGesture",
        ],
    )
    carplay_scene = read("apps/mobile/ios/Runner/CarPlaySceneDelegate.swift")
    map_base = carplay_scene.split(
        "final class CarPlayNavigationViewController", maxsplit=1
    )[-1].split("private final class CarPlayRiderAnnotation", maxsplit=1)[0]
    for forbidden in (
        "view.addSubview(",
        "CarPlayTecBadge",
        "CarPlaySpeedLimitBadge",
        "CarPlayCompassBadge",
        "CarPlayGroupMiniMapView",
        "CarPlayClockLabel",
        "CarPlayRouteProgressView",
        "CarPlayGuidanceView",
        "CarPlayRideActionsView",
    ):
        if forbidden in map_base:
            failures.append(
                "apps/mobile/ios/Runner/CarPlaySceneDelegate.swift: "
                f"base map still contains {forbidden!r}"
            )
    require_text(
        failures,
        "apps/mobile/lib/services/carplay_route_preview.dart",
        [
            "class CarPlayTripPreview",
            "choices.take(3)",
            "class CarPlayRoutePreviewTransaction",
            "_pending = null",
        ],
    )
    require_text(
        failures,
        "apps/mobile/lib/services/carplay_bridge.dart",
        [
            "case 'previewDestination':",
            "case 'commitDestinationPreview':",
            "case 'cancelDestinationPreview':",
            "case 'cancelNavigation':",
            "_completeAction(",
        ],
    )
    require_text(
        failures,
        "apps/mobile/ios/Runner/AppDelegate.swift",
        [
            "CarPlayCommandCompletion",
            "deadline: .now() + 8",
            "applicationProtectedDataDidBecomeAvailable",
            'invokeMethod("requestState"',
        ],
    )
    projected_sources = "\n".join(
        read(path)
        for path in (
            "apps/mobile/lib/services/carplay_bridge.dart",
            "apps/mobile/lib/features/home/home_screen.dart",
            "apps/mobile/lib/features/ride/active_ride_shell.dart",
            "apps/mobile/ios/Runner/AppDelegate.swift",
            "apps/mobile/ios/Runner/CarPlaySceneDelegate.swift",
            "apps/mobile/ios/Runner/CarPlayStatusTemplate.swift",
        )
    )
    for forbidden in (
        "Finish setup on iPhone",
        "Try again on the iPhone",
        "Show your location on the iPhone",
        "Allow location access on the iPhone",
        "Open Tail End Charlie on the iPhone",
    ):
        if forbidden in projected_sources:
            failures.append(f"CarPlay flow contains phone-directed text: {forbidden!r}")
    require_text(
        failures,
        "apps/mobile/ios/RunnerTests/RunnerTests.swift",
        [
            "testCarPlayRoutePreviewRejectsNoRoute",
            "testCarPlayRoutePreviewAcceptsOneRouteAndCommitsItOnce",
            "testCarPlayRoutePreviewAcceptsAndSelectsThreeRoutes",
            "testCarPlayRoutePreviewRejectsStalePlanningResult",
            "testCarPlayRoutePreviewCancellationDoesNotLeaveASelection",
            "testCarPlayNavigationLifecycleIsIdempotent",
            "testCarPlayNavigationLifecycleReroutesArrivesAndCancelsOnce",
            "testCarPlayVehicleCancellationSuppressesSameRouteReplay",
            "testCarPlayDrivingRestrictionsHideOnlyUnsafeDetail",
            "testCarPlayBaseViewContainsOnlyTheMap",
            "testCarPlayCommandCompletionResolvesExactlyOnce",
            "testCarPlaySafeAreaUsesEveryHostInset",
            "testCarPlayUnitsPreferExplicitChoiceThenLocale",
            "testCarPlayDashboardAcceptsOnlyActiveGuidance",
        ],
    )
    require_text(
        failures,
        "apps/mobile/ios/Runner/CarPlaySceneDelegate.swift",
        [
            "CarPlayMapSafeArea",
            "viewSafeAreaInsetsDidChange",
            "mapView.contentInset = safeArea.contentInsets",
            "contentStyleChanged contentStyle",
            "contentStyleDidChange",
            "hostContentStyle.contains(.dark)",
            "CarPlayUnitPolicy",
            "overviewCoordinates",
            "CarPlayDashboardSceneDelegate",
            "CarPlayDashboardProjectionState",
            "private var carWindow: CPWindow?",
            "private var dashboardWindow: UIWindow?",
        ],
    )
    require_text(
        failures,
        "apps/mobile/ios/Runner/Info.plist",
        [
            "CPSupportsDashboardNavigationScene",
            "CPTemplateApplicationDashboardSceneSessionRoleApplication",
            "CarPlayDashboardSceneDelegate",
        ],
    )
    require_text(
        failures,
        "apps/mobile/ios/Runner/AppDelegate.swift",
        [
            "carPlayDashboardDidConnect",
            "carPlayDashboardDidDisconnect",
            "carPlayDashboardSceneDelegate?.apply(snapshot: value)",
            "carPlayDashboardSceneDelegate?.apply(viewport: value)",
        ],
    )
    require_text(
        failures,
        "apps/mobile/lib/services/basemap_configuration.dart",
        ["final String lightStyleUrl", "lightStyleUrl: lightStyleUrl"],
    )
    require_text(
        failures,
        "apps/mobile/lib/services/carplay_navigation_projection.dart",
        [
            "'schemaVersion': 2",
            "'navigationLifecycle'",
            "'trafficSide'",
            "'routeChoiceId'",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/AndroidManifest.xml",
        [
            "androidx.car.app.category.NAVIGATION",
            "androidx.car.app.NAVIGATION_TEMPLATES",
            "androidx.car.app.ACCESS_SURFACE",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/res/xml/automotive_app_desc.xml",
        ['<uses name="template" />'],
    )
    require_text(
        failures,
        "apps/mobile/lib/services/android_auto_navigation_projection.dart",
        [
            "'schemaVersion': 2",
            "'navigationLifecycle'",
            "'shouldOwnNavigation'",
            "'navigationSessionId'",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/AndroidAutoNavigationProjection.kt",
        [
            "AndroidAutoNavigationProjectionV2",
            "AndroidAutoNavigationProjectionStore",
            "candidate.sequence <= current.sequence",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/test/kotlin/me/osholt/ride_relay/AndroidAutoNavigationProjectionTest.kt",
        [
            "decodes the shared French V2 fixture",
            "store rejects replay out of order and stale source commands",
            "does not revive guidance from a rejected command",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/test/kotlin/me/osholt/ride_relay/AndroidAutoCompanionTest.kt",
        ["CarPlay V2 block cannot change the legacy Android projection"],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/AndroidAutoNavigationCoordinator.kt",
        [
            "setNavigationManagerCallback(",
            "navigationManager.navigationStarted()",
            "navigationManager.updateTrip(",
            "navigationManager.navigationEnded()",
            "NotificationCompat.CATEGORY_NAVIGATION",
            "CarAppExtender.Builder()",
            "hostRejectedSessionId",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/test/kotlin/me/osholt/ride_relay/AndroidAutoNavigationCoordinatorTest.kt",
        [
            "starts once updates every accepted trip and ends once",
            "host preemption stops once and blocks stale ownership replay",
            "route replacement and close balance host ownership",
            "trip contains current following and destination metadata",
            "active turn notification is ongoing navigation and extended for the car",
        ],
    )
    require_text(
        failures,
        "apps/mobile/lib/features/ride/active_ride_shell.dart",
        [
            "onAndroidAutoNavigationHostEvent: _handleAndroidAutoNavigationHostEvent",
            "AndroidAutoNavigationHostEventType.stopped",
            "await _cancelNavigationFromCarPlay()",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/AndroidManifest.xml",
        [
            "androidx.car.app.action.NAVIGATE",
            'android:scheme="geo"',
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/TailEndCharlieCarAppService.kt",
        [
            "AndroidAutoNavigationIntent.parse(intent)",
            "override fun onNewIntent(intent: Intent)",
            "onAutoDriveEnabled = { coordinator?.hostEnabledAutoDrive() }",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/AndroidAutoNavigationIntent.kt",
        [
            "CAR_ACTION_NAVIGATE",
            'scheme != "geo" && scheme != "geo.offline"',
            '"add_a_stop" -> Operation.ADD_STOP',
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/AndroidAutoTestDrive.kt",
        [
            "AndroidAutoDeterministicTestDrive",
            "SIMULATED_SPEED_METERS_PER_SECOND",
            "It never invents GPS samples",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/test/kotlin/me/osholt/ride_relay/AndroidAutoNavigationIntentTest.kt",
        [
            "parses Assistant query with two wheeler mode",
            "parses coordinates directions add stop and offline variants",
            "rejects non navigation malformed and unsupported requests",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/AndroidAutoManeuverFactory.kt",
        [
            "Maneuver.TYPE_UNKNOWN",
            "Maneuver.TYPE_U_TURN_LEFT",
            "Maneuver.TYPE_FORK_LEFT",
            "Maneuver.TYPE_MERGE_SIDE_UNSPECIFIED",
            "Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CW",
            "setRoundaboutExitNumber(value.exitNumber)",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/test/kotlin/me/osholt/ride_relay/AndroidAutoManeuverFactoryTest.kt",
        [
            "ParameterizedRobolectricTestRunner",
            "maps the shared manoeuvre to the Android host type",
            "roundabouts follow traffic side and retain exit number",
            "step cue road and icon come from one typed manoeuvre",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/AndroidAutoNavigationScreen.kt",
        [
            "override fun onVisibleAreaChanged(visibleArea: Rect)",
            "override fun onStableAreaChanged(stableArea: Rect)",
            "visibleArea = visibleArea",
            "stableArea = stableArea",
        ],
    )
    renderer = read(
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/ProjectedMapRenderer.kt"
    )
    if "drawText(" in renderer:
        failures.append("Android Auto navigation surface still draws non-map text")
    require_text(
        failures,
        "apps/mobile/android/app/src/test/kotlin/me/osholt/ride_relay/ProjectedMapRendererTest.kt",
        [
            "nothing to draw remains a map-only surface",
            "route pixels remain inside obstructed stable area",
            "800 to 480, 1280 to 720, 1920 to 720",
            "car host selects day and night independently of phone theme",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/TailEndCharlieCarAppService.kt",
        [
            "override fun onCarConfigurationChanged(newConfiguration: Configuration)",
            "navigationScreen?.applyHostDarkMode(carContext.isDarkMode)",
        ],
    )
    require_text(
        failures,
        "apps/mobile/android/app/src/main/kotlin/me/osholt/ride_relay/ProjectedMapRenderer.kt",
        [
            "hostDarkMode: Boolean",
            "ProjectedMapPalette.forHost(hostDarkMode)",
        ],
    )


def write_summary(
    carplay: tuple[int, int], android: tuple[int, int], strict: bool, failures: list[str]
) -> None:
    mode = "strict release gate" if strict else "incremental tester gate"
    lines = [
        "## Projected navigation compliance",
        "",
        f"- Mode: {mode}",
        f"- CarPlay required checks documented PASS: {carplay[0]}/{carplay[1]}",
        f"- Android Auto baseline criteria documented PASS: {android[0]}/{android[1]}",
        f"- Machine-checkable structural/traceability failures: {len(failures)}",
    ]
    if not strict:
        lines.extend(
            [
                "- Known ticketed gaps are allowed for closed-testing builds.",
                "- Production readiness must run this checker with `--strict`.",
            ]
        )
    if failures:
        lines.extend(["", "### Failures", *[f"- {failure}" for failure in failures]])
    summary = "\n".join(lines) + "\n"
    print(summary)
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a", encoding="utf-8") as output:
            output.write(summary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail until every required documented criterion is PASS",
    )
    args = parser.parse_args()

    failures: list[str] = []
    structural_checks(failures)
    carplay = carplay_checklist(failures, args.strict)
    android = android_checklist(failures, args.strict)
    write_summary(carplay, android, args.strict, failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
