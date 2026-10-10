#!/usr/bin/env python3
"""Open the external TestFlight group to the public, and check that it is open.

`submit_external.py` puts a build in front of an external group. This is the
other half of an open beta: the group's *public link*, the cap on how many
testers may join through it, and the beta test information Apple shows them and
reviews. Everything goes through the App Store Connect API with the review
(App Manager) key already used for `submit_external.py`:

* `verify` is read-only. It reports the link, its cap, how many testers are in
  the group, whether a build testers can install is assigned, and whether the
  test information and review contact are filled in. It exits non-zero when
  something launch needs is missing or the link is not in the state
  `--expect-link` names, so it doubles as the rollback check.
* `test-info` sets the beta description, feedback email and privacy-policy URL
  (App Store Connect: TestFlight > Test Information) for one locale.
* `public-link enable|disable` turns the link on with a cap, or off.

Every write is a dry run unless `--apply` is given: the planned change is
printed and nothing is sent. A write is read back afterwards and the command
fails if the group does not say what was asked for.

What this cannot do: Apple's beta *review* is separate (`submit_external.py`),
and nothing here changes a build's availability. Disabling the link stops new
people joining. It does not remove testers who already have a build; that is
done by expiring the build in App Store Connect.

Usage, from the repository root (needs PyJWT[crypto]):

  python -m tools.testflight.beta_distribution verify \\
      --bundle-id app.tailendcharlie --group "External Testers" \\
      --issuer-id ... --key-id ... --private-key AuthKey_XXXX.p8
  python -m tools.testflight.beta_distribution public-link enable --limit 100 \\
      ... --apply
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from tools.testflight.submit_external import (
    AppStoreConnectClient,
    AppStoreConnectError,
    find_app,
    find_external_group,
)

DEFAULT_LINK_LIMIT = 100
MIN_LINK_LIMIT = 1
# TestFlight's own ceiling for external testers.
MAX_LINK_LIMIT = 10_000
DEFAULT_FEEDBACK_EMAIL = "testing@tailendcharlie.app"
DEFAULT_PRIVACY_URL = "https://tailendcharlie.app/privacy.html"
DEFAULT_MARKETING_URL = "https://tailendcharlie.app"
DEFAULT_LOCALE = "en-GB"
# Apple's limit on the beta app description.
MAX_DESCRIPTION_LENGTH = 4_000
# States in which an external tester can actually install a build.
INSTALLABLE_BUILD_STATES = frozenset({"IN_BETA_TESTING", "READY_FOR_BETA_TESTING"})
CHECK_NAMES = ("link", "builds", "test-info", "review-contact")


class ConfigurationError(ValueError):
    """A request was refused before any call was made."""


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    detail: str


@dataclass
class Report:
    checks: list[Check] = field(default_factory=list)
    facts: list[tuple[str, str]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return all(check.ok for check in self.checks)


# ---------------------------------------------------------------------------
# Request construction. Pure functions: these are what the unit tests pin.
# ---------------------------------------------------------------------------


def validate_link_limit(limit: int) -> int:
    if not MIN_LINK_LIMIT <= limit <= MAX_LINK_LIMIT:
        raise ConfigurationError(
            f"The public-link limit must be between {MIN_LINK_LIMIT} and "
            f"{MAX_LINK_LIMIT}, not {limit}."
        )
    return limit


def desired_link_attributes(*, enabled: bool, limit: int | None) -> dict[str, Any]:
    """The `betaGroups` attributes that express "link on, capped" or "link off".

    Turning the link off leaves the cap alone: it is the setting the group will
    come back to if the link is re-enabled.
    """
    if not enabled:
        return {"publicLinkEnabled": False}
    if limit is None:
        raise ConfigurationError("Enabling the public link needs a limit.")
    return {
        "publicLinkEnabled": True,
        "publicLinkLimitEnabled": True,
        "publicLinkLimit": validate_link_limit(limit),
    }


def changed_attributes(current: dict[str, Any], desired: dict[str, Any]) -> dict[str, Any]:
    """Only the attributes whose value differs, so a repeat run sends nothing."""
    return {key: value for key, value in desired.items() if current.get(key) != value}


def group_update_body(group_id: str, attributes: dict[str, Any]) -> dict[str, Any]:
    return {"data": {"type": "betaGroups", "id": group_id, "attributes": attributes}}


def validate_test_info(
    *, description: str, feedback_email: str, privacy_url: str, marketing_url: str
) -> dict[str, str]:
    description = description.strip()
    if not description:
        raise ConfigurationError("The beta description is empty.")
    if len(description) > MAX_DESCRIPTION_LENGTH:
        raise ConfigurationError(
            f"The beta description is {len(description)} characters; Apple allows "
            f"{MAX_DESCRIPTION_LENGTH}."
        )
    if "@" not in feedback_email or " " in feedback_email.strip():
        raise ConfigurationError(f"{feedback_email!r} is not an email address.")
    for label, url in (("privacy-policy", privacy_url), ("marketing", marketing_url)):
        if not url.startswith("https://"):
            raise ConfigurationError(f"The {label} URL must be https, not {url!r}.")
    return {
        "description": description,
        "feedbackEmail": feedback_email.strip(),
        "privacyPolicyUrl": privacy_url,
        "marketingUrl": marketing_url,
    }


def localization_create_body(
    app_id: str, locale: str, attributes: dict[str, str]
) -> dict[str, Any]:
    return {
        "data": {
            "type": "betaAppLocalizations",
            "attributes": {**attributes, "locale": locale},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    }


def localization_update_body(localization_id: str, attributes: dict[str, str]) -> dict[str, Any]:
    return {
        "data": {
            "type": "betaAppLocalizations",
            "id": localization_id,
            "attributes": attributes,
        }
    }


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------


def _attributes(resource: dict[str, Any] | None) -> dict[str, Any]:
    return (resource or {}).get("attributes", {}) or {}


def read_group(client: Any, group_id: str) -> dict[str, Any]:
    return client.request("GET", f"/betaGroups/{group_id}")["data"]


def count_testers(client: Any, group_id: str) -> int | None:
    """Testers in the group, or None when Apple does not say."""
    try:
        payload = client.request("GET", f"/betaGroups/{group_id}/betaTesters", query={"limit": "1"})
    except AppStoreConnectError:
        return None
    total = ((payload.get("meta") or {}).get("paging") or {}).get("total")
    return total if isinstance(total, int) else None


def installable_builds(client: Any, *, app_id: str, group_id: str) -> list[tuple[str, str]]:
    """Newest builds assigned to the group, as (build number, external state)."""
    payload = client.request(
        "GET",
        "/builds",
        query={
            "filter[app]": app_id,
            "filter[betaGroups]": group_id,
            "filter[expired]": "false",
            "sort": "-uploadedDate",
            "limit": "5",
        },
    )
    found: list[tuple[str, str]] = []
    for build in payload.get("data", []):
        detail = client.request("GET", f"/builds/{build['id']}/buildBetaDetail")
        state = _attributes(detail.get("data")).get("externalBuildState", "UNKNOWN")
        found.append((_attributes(build).get("version", "?"), state))
    return found


def find_localization(client: Any, *, app_id: str, locale: str) -> dict[str, Any] | None:
    payload = client.request("GET", f"/apps/{app_id}/betaAppLocalizations", query={"limit": "200"})
    for item in payload.get("data", []):
        if _attributes(item).get("locale") == locale:
            return item
    return None


def read_review_detail(client: Any, app_id: str) -> dict[str, Any]:
    return _attributes(client.request("GET", f"/apps/{app_id}/betaAppReviewDetail").get("data"))


# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------


def verify(
    client: Any,
    *,
    bundle_id: str,
    group_name: str,
    checks: tuple[str, ...] = CHECK_NAMES,
    expect_link: str = "any",
    expected_limit: int | None = DEFAULT_LINK_LIMIT,
    feedback_email: str = DEFAULT_FEEDBACK_EMAIL,
    privacy_url: str = DEFAULT_PRIVACY_URL,
    locale: str = DEFAULT_LOCALE,
) -> Report:
    """Read everything launch depends on and return it as pass/fail checks."""
    report = Report()
    app = find_app(client, bundle_id)
    group = find_external_group(client, app_id=app["id"], group_name=group_name)
    group = read_group(client, group["id"])
    attrs = _attributes(group)
    link_on = bool(attrs.get("publicLinkEnabled"))
    limit_on = bool(attrs.get("publicLinkLimitEnabled"))
    limit = attrs.get("publicLinkLimit")
    testers = count_testers(client, group["id"])

    report.facts += [
        ("Group", f"{attrs.get('name')} (external)"),
        ("Public link", "enabled" if link_on else "disabled"),
        ("Link address", str(attrs.get("publicLink") or "none")),
        ("Link limit", f"{limit} (enforced)" if limit_on else f"{limit} (not enforced)"),
        ("Testers in the group", "unknown" if testers is None else str(testers)),
    ]

    if "link" in checks:
        if expect_link == "enabled":
            report.checks.append(
                Check(
                    "link",
                    link_on,
                    "public link is enabled" if link_on else "public link is DISABLED",
                )
            )
        elif expect_link == "disabled":
            report.checks.append(
                Check(
                    "link",
                    not link_on,
                    "public link is disabled" if not link_on else "public link is STILL ENABLED",
                )
            )
        if link_on and expected_limit is not None and expect_link != "disabled":
            capped = limit_on and limit == expected_limit
            report.checks.append(
                Check(
                    "link-limit",
                    capped,
                    f"cap is {limit} and enforced"
                    if capped
                    else f"cap is {limit} (enforced: {limit_on}), "
                    f"expected {expected_limit} enforced",
                )
            )

    if "builds" in checks:
        builds = installable_builds(client, app_id=app["id"], group_id=group["id"])
        ready = [number for number, state in builds if state in INSTALLABLE_BUILD_STATES]
        report.facts.append(
            ("Builds in the group", ", ".join(f"{n} ({s})" for n, s in builds) or "none")
        )
        report.checks.append(
            Check(
                "builds",
                bool(ready),
                f"build {ready[0]} can be installed by external testers"
                if ready
                else "no build assigned to the group is installable by external testers",
            )
        )

    if "test-info" in checks:
        localization = find_localization(client, app_id=app["id"], locale=locale)
        info = _attributes(localization)
        problems = []
        if localization is None:
            problems.append(f"no {locale} test information")
        else:
            if not (info.get("description") or "").strip():
                problems.append("description empty")
            if info.get("feedbackEmail") != feedback_email:
                problems.append(f"feedback email is not {feedback_email}")
            if info.get("privacyPolicyUrl") != privacy_url:
                problems.append(f"privacy URL is not {privacy_url}")
        report.checks.append(
            Check(
                "test-info",
                not problems,
                f"{locale} description, feedback email and privacy URL are set"
                if not problems
                else "; ".join(problems),
            )
        )

    if "review-contact" in checks:
        detail = read_review_detail(client, app["id"])
        missing = [
            label
            for key, label in (
                ("contactEmail", "contact email"),
                ("contactPhone", "contact phone"),
                ("notes", "reviewer notes"),
            )
            if not str(detail.get(key) or "").strip()
        ]
        report.checks.append(
            Check(
                "review-contact",
                not missing,
                "reviewer contact and notes are present"
                if not missing
                else "missing: " + ", ".join(missing),
            )
        )
    return report


# ---------------------------------------------------------------------------
# writes
# ---------------------------------------------------------------------------


def set_public_link(
    client: Any,
    *,
    bundle_id: str,
    group_name: str,
    enable: bool,
    limit: int | None,
    apply: bool,
) -> tuple[dict[str, Any], bool]:
    """Plan, and with `apply` make, a public-link change.

    Returns (attributes that changed, whether a request was sent). Enabling is
    refused while no build in the group can be installed: Apple would publish a
    link that leads to nothing.
    """
    desired = desired_link_attributes(enabled=enable, limit=limit)
    app = find_app(client, bundle_id)
    group = read_group(
        client, find_external_group(client, app_id=app["id"], group_name=group_name)["id"]
    )
    changes = changed_attributes(_attributes(group), desired)
    if not changes:
        return {}, False
    if enable:
        ready = [
            number
            for number, state in installable_builds(client, app_id=app["id"], group_id=group["id"])
            if state in INSTALLABLE_BUILD_STATES
        ]
        if not ready:
            raise ConfigurationError(
                "No build assigned to the group is installable by external "
                "testers yet (Beta App Review not approved, or no build "
                "assigned). Enable the link once one is."
            )
    if not apply:
        return changes, False
    client.request(
        "PATCH",
        f"/betaGroups/{group['id']}",
        body=group_update_body(group["id"], changes),
    )
    after = _attributes(read_group(client, group["id"]))
    wrong = {key: after.get(key) for key, value in changes.items() if after.get(key) != value}
    if wrong:
        raise AppStoreConnectError(
            f"App Store Connect accepted the change but reports {wrong} on read-back."
        )
    return changes, True


def set_test_info(
    client: Any,
    *,
    bundle_id: str,
    locale: str,
    attributes: dict[str, str],
    apply: bool,
) -> tuple[str, dict[str, str], bool]:
    """Create or update one locale's beta test information.

    Returns (what happens: create|update|none, the attributes involved, whether
    a request was sent).
    """
    app = find_app(client, bundle_id)
    existing = find_localization(client, app_id=app["id"], locale=locale)
    if existing is None:
        action, payload = "create", attributes
    else:
        payload = changed_attributes(_attributes(existing), attributes)
        action = "update" if payload else "none"
    if action == "none" or not apply:
        return action, payload, False
    if existing is None:
        client.request(
            "POST",
            "/betaAppLocalizations",
            body=localization_create_body(app["id"], locale, payload),
            expected=(201,),
        )
    else:
        client.request(
            "PATCH",
            f"/betaAppLocalizations/{existing['id']}",
            body=localization_update_body(existing["id"], payload),
        )
    after = _attributes(find_localization(client, app_id=app["id"], locale=locale))
    wrong = [key for key, value in payload.items() if after.get(key) != value]
    if wrong:
        raise AppStoreConnectError(
            f"App Store Connect accepted the test information but {', '.join(wrong)} "
            "did not read back as written."
        )
    return action, payload, True


# ---------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------


def write_summary(title: str, lines: list[str]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as summary:
        summary.write(f"### {title}\n\n")
        summary.write("\n".join(lines) + "\n\n")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--bundle-id", required=True)
    common.add_argument("--group", required=True, help="Exact external group name")
    common.add_argument("--issuer-id", required=True)
    common.add_argument("--key-id", required=True)
    common.add_argument("--private-key", required=True, type=Path)
    common.add_argument("--locale", default=DEFAULT_LOCALE)
    common.add_argument("--feedback-email", default=DEFAULT_FEEDBACK_EMAIL)
    common.add_argument("--privacy-url", default=DEFAULT_PRIVACY_URL)

    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("verify", parents=[common], help="Read-only report")
    check.add_argument("--expect-link", choices=("enabled", "disabled", "any"), default="any")
    check.add_argument("--expected-limit", type=int, default=DEFAULT_LINK_LIMIT)
    check.add_argument(
        "--check",
        action="append",
        choices=CHECK_NAMES,
        help="Limit the report to these checks (repeatable); default all",
    )

    info = commands.add_parser("test-info", parents=[common], help="Set the beta test information")
    info.add_argument("--description-file", required=True, type=Path)
    info.add_argument("--marketing-url", default=DEFAULT_MARKETING_URL)
    info.add_argument("--apply", action="store_true", help="Send the change; default is a dry run")

    link = commands.add_parser(
        "public-link", parents=[common], help="Turn the public link on or off"
    )
    link.add_argument("state", choices=("enable", "disable"))
    link.add_argument("--limit", type=int, default=DEFAULT_LINK_LIMIT)
    link.add_argument("--apply", action="store_true", help="Send the change; default is a dry run")
    return parser.parse_args(argv)


def _run_verify(client: Any, args: argparse.Namespace) -> int:
    report = verify(
        client,
        bundle_id=args.bundle_id,
        group_name=args.group,
        checks=tuple(args.check) if args.check else CHECK_NAMES,
        expect_link=args.expect_link,
        expected_limit=args.expected_limit,
        feedback_email=args.feedback_email,
        privacy_url=args.privacy_url,
        locale=args.locale,
    )
    lines = [f"- {name}: {value}" for name, value in report.facts]
    lines += [f"- [{'ok' if c.ok else 'FAIL'}] {c.name}: {c.detail}" for c in report.checks]
    print("\n".join(lines))
    write_summary("TestFlight public beta: verification", lines)
    return 0 if report.ok else 1


def _run_test_info(client: Any, args: argparse.Namespace) -> int:
    attributes = validate_test_info(
        description=args.description_file.read_text(encoding="utf-8"),
        feedback_email=args.feedback_email,
        privacy_url=args.privacy_url,
        marketing_url=args.marketing_url,
    )
    action, payload, sent = set_test_info(
        client,
        bundle_id=args.bundle_id,
        locale=args.locale,
        attributes=attributes,
        apply=args.apply,
    )
    keys = ", ".join(sorted(payload)) or "nothing"
    if action == "none":
        line = f"Beta test information for {args.locale} already matches; nothing to change."
    elif sent:
        line = (
            f"{action.capitalize()}d {args.locale} beta test information ({keys}) and read it back."
        )
    else:
        line = (
            f"Dry run: would {action} {args.locale} beta test information "
            f"({keys}). Re-run with --apply."
        )
    print(line)
    write_summary("TestFlight beta test information", [line])
    return 0


def _run_public_link(client: Any, args: argparse.Namespace) -> int:
    enable = args.state == "enable"
    changes, sent = set_public_link(
        client,
        bundle_id=args.bundle_id,
        group_name=args.group,
        enable=enable,
        limit=args.limit if enable else None,
        apply=args.apply,
    )
    if not changes:
        state = "enabled with that limit" if enable else "disabled"
        line = f"Public link is already {state}; nothing to change."
    elif sent:
        line = f"Public link {args.state}d for {args.group} ({changes}) and read back."
    else:
        line = f"Dry run: would set {changes} on {args.group}. Re-run with --apply."
    print(line)
    write_summary("TestFlight public link", [line])
    return 0


def main(argv: list[str] | None = None, client: Any | None = None) -> int:
    args = parse_args(argv)
    try:
        client = client or AppStoreConnectClient(
            issuer_id=args.issuer_id, key_id=args.key_id, private_key_path=args.private_key
        )
        if args.command == "verify":
            return _run_verify(client, args)
        if args.command == "test-info":
            return _run_test_info(client, args)
        return _run_public_link(client, args)
    except (AppStoreConnectError, ConfigurationError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
