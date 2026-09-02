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
        ],
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
        "apps/mobile/android/app/src/test/kotlin/me/osholt/ride_relay/AndroidAutoCompanionTest.kt",
        ["CarPlay V2 block cannot change the legacy Android projection"],
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
