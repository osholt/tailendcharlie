from __future__ import annotations

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.testflight import beta_distribution as bd  # noqa: E402
from tools.testflight.submit_external import AppStoreConnectError  # noqa: E402

APP_ID = "app-1"
GROUP_ID = "group-1"
BUNDLE = "app.tailendcharlie"
GROUP = "External Testers"

DESCRIPTION = "Tail End Charlie keeps a group ride together."


def group_attributes(**overrides):
    attributes = {
        "name": GROUP,
        "isInternalGroup": False,
        "publicLinkEnabled": False,
        "publicLinkLimitEnabled": False,
        "publicLinkLimit": 10_000,
        "publicLink": None,
    }
    attributes.update(overrides)
    return attributes


class FakeAppStoreConnect:
    """Answers by method and path, and records every request.

    PATCH to the group is applied to the stored attributes, so a read-back sees
    what was written, unless `ignore_patch` models Apple accepting a change and
    reporting something else.
    """

    def __init__(
        self,
        *,
        group=None,
        builds=(("102", "IN_BETA_TESTING"),),
        localizations=(),
        review_detail=None,
        testers=7,
        ignore_patch=False,
    ):
        self.group = group if group is not None else group_attributes()
        self.builds = list(builds)
        self.localizations = [dict(item) for item in localizations]
        self.review_detail = (
            review_detail
            if review_detail is not None
            else {"contactEmail": "a@b.c", "contactPhone": "+44", "notes": "Use Ride Lab"}
        )
        self.testers = testers
        self.ignore_patch = ignore_patch
        self.requests = []

    def writes(self):
        return [r for r in self.requests if r[0] in ("POST", "PATCH")]

    def request(self, method, path, *, query=None, body=None, expected=(200,)):
        self.requests.append((method, path, body, expected))
        if (method, path) == ("GET", "/apps"):
            return {"data": [{"id": APP_ID}]}
        if (method, path) == ("GET", "/betaGroups"):
            return {"data": [{"id": GROUP_ID, "attributes": self.group}]}
        if (method, path) == ("GET", f"/betaGroups/{GROUP_ID}"):
            return {"data": {"id": GROUP_ID, "attributes": self.group}}
        if (method, path) == ("PATCH", f"/betaGroups/{GROUP_ID}"):
            if not self.ignore_patch:
                self.group = {**self.group, **body["data"]["attributes"]}
            return {"data": {"id": GROUP_ID, "attributes": self.group}}
        if path == f"/betaGroups/{GROUP_ID}/betaTesters":
            if self.testers is None:
                raise AppStoreConnectError("forbidden")
            return {"data": [], "meta": {"paging": {"total": self.testers}}}
        if (method, path) == ("GET", "/builds"):
            return {
                "data": [
                    {"id": f"build-{number}", "attributes": {"version": number}}
                    for number, _ in self.builds
                ]
            }
        if path.endswith("/buildBetaDetail"):
            number = path.split("build-")[1].split("/")[0]
            state = dict(self.builds)[number]
            return {"data": {"attributes": {"externalBuildState": state}}}
        if (method, path) == ("GET", f"/apps/{APP_ID}/betaAppLocalizations"):
            return {"data": self.localizations}
        if (method, path) == ("POST", "/betaAppLocalizations"):
            created = {
                "id": "loc-new",
                "attributes": dict(body["data"]["attributes"]),
            }
            self.localizations.append(created)
            return {"data": created}
        if method == "PATCH" and path.startswith("/betaAppLocalizations/"):
            for item in self.localizations:
                if item["id"] == path.rsplit("/", 1)[1]:
                    item["attributes"].update(body["data"]["attributes"])
            return {"data": {}}
        if (method, path) == ("GET", f"/apps/{APP_ID}/betaAppReviewDetail"):
            return {"data": {"attributes": self.review_detail}}
        raise AssertionError(f"unexpected request {method} {path}")


TEST_INFO = {
    "description": DESCRIPTION,
    "feedbackEmail": bd.DEFAULT_FEEDBACK_EMAIL,
    "privacyPolicyUrl": bd.DEFAULT_PRIVACY_URL,
    "marketingUrl": bd.DEFAULT_MARKETING_URL,
}


def info_attributes(**overrides):
    attributes = {
        "description": DESCRIPTION,
        "feedbackEmail": bd.DEFAULT_FEEDBACK_EMAIL,
        "privacyPolicyUrl": bd.DEFAULT_PRIVACY_URL,
        "marketingUrl": bd.DEFAULT_MARKETING_URL,
        "locale": bd.DEFAULT_LOCALE,
    }
    attributes.update(overrides)
    return attributes


def localization(**overrides):
    return {"id": "loc-1", "attributes": info_attributes(**overrides)}


class RequestConstructionTests(unittest.TestCase):
    def test_enabling_sets_the_link_the_cap_and_enforces_it(self):
        self.assertEqual(
            bd.desired_link_attributes(enabled=True, limit=100),
            {
                "publicLinkEnabled": True,
                "publicLinkLimitEnabled": True,
                "publicLinkLimit": 100,
            },
        )

    def test_disabling_touches_only_the_switch(self):
        self.assertEqual(
            bd.desired_link_attributes(enabled=False, limit=None),
            {"publicLinkEnabled": False},
        )
        self.assertEqual(
            bd.desired_link_attributes(enabled=False, limit=5),
            {"publicLinkEnabled": False},
        )

    def test_the_cap_is_bounded_by_what_testflight_allows(self):
        for limit in (0, -1, 10_001):
            with self.subTest(limit=limit), self.assertRaises(bd.ConfigurationError):
                bd.desired_link_attributes(enabled=True, limit=limit)
        self.assertEqual(bd.validate_link_limit(1), 1)
        self.assertEqual(bd.validate_link_limit(10_000), 10_000)

    def test_enabling_without_a_cap_is_refused(self):
        with self.assertRaises(bd.ConfigurationError):
            bd.desired_link_attributes(enabled=True, limit=None)

    def test_the_default_cap_is_one_hundred(self):
        self.assertEqual(bd.DEFAULT_LINK_LIMIT, 100)

    def test_the_group_update_body_is_a_jsonapi_patch(self):
        self.assertEqual(
            bd.group_update_body("g", {"publicLinkEnabled": True}),
            {
                "data": {
                    "type": "betaGroups",
                    "id": "g",
                    "attributes": {"publicLinkEnabled": True},
                }
            },
        )

    def test_only_differing_attributes_are_sent(self):
        current = {"publicLinkEnabled": True, "publicLinkLimit": 100}
        self.assertEqual(
            bd.changed_attributes(current, {"publicLinkEnabled": True, "publicLinkLimit": 250}),
            {"publicLinkLimit": 250},
        )
        self.assertEqual(bd.changed_attributes(current, dict(current)), {})

    def test_localization_bodies(self):
        attributes = {"feedbackEmail": "testing@tailendcharlie.app"}
        self.assertEqual(
            bd.localization_create_body("app-1", "en-GB", attributes),
            {
                "data": {
                    "type": "betaAppLocalizations",
                    "attributes": {
                        "feedbackEmail": "testing@tailendcharlie.app",
                        "locale": "en-GB",
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": "app-1"}}},
                }
            },
        )
        self.assertEqual(
            bd.localization_update_body("loc-1", attributes),
            {
                "data": {
                    "type": "betaAppLocalizations",
                    "id": "loc-1",
                    "attributes": attributes,
                }
            },
        )

    def test_test_information_is_validated_before_any_call(self):
        good = {
            "description": DESCRIPTION,
            "feedback_email": "testing@tailendcharlie.app",
            "privacy_url": "https://tailendcharlie.app/privacy.html",
            "marketing_url": "https://tailendcharlie.app",
        }
        self.assertEqual(
            bd.validate_test_info(**good)["feedbackEmail"], "testing@tailendcharlie.app"
        )
        for override in (
            {"description": "  "},
            {"description": "x" * (bd.MAX_DESCRIPTION_LENGTH + 1)},
            {"feedback_email": "not an email"},
            {"feedback_email": "no-at-sign"},
            {"privacy_url": "http://tailendcharlie.app/privacy.html"},
            {"marketing_url": "ftp://example.com"},
        ):
            with self.subTest(override=override), self.assertRaises(bd.ConfigurationError):
                bd.validate_test_info(**{**good, **override})


class PublicLinkTests(unittest.TestCase):
    def enable(self, client, *, apply, limit=100):
        return bd.set_public_link(
            client, bundle_id=BUNDLE, group_name=GROUP, enable=True, limit=limit, apply=apply
        )

    def test_a_dry_run_plans_the_change_and_sends_nothing(self):
        client = FakeAppStoreConnect()
        changes, sent = self.enable(client, apply=False)
        self.assertEqual(changes["publicLinkLimit"], 100)
        self.assertFalse(sent)
        self.assertEqual(client.writes(), [])

    def test_apply_patches_once_and_reads_back(self):
        client = FakeAppStoreConnect()
        changes, sent = self.enable(client, apply=True)
        self.assertTrue(sent)
        patches = [r for r in client.writes() if r[0] == "PATCH"]
        self.assertEqual(len(patches), 1)
        self.assertEqual(patches[0][1], f"/betaGroups/{GROUP_ID}")
        self.assertEqual(patches[0][2]["data"]["attributes"], changes)
        self.assertEqual(client.requests[-1][:2], ("GET", f"/betaGroups/{GROUP_ID}"))
        self.assertTrue(client.group["publicLinkEnabled"])
        self.assertEqual(client.group["publicLinkLimit"], 100)

    def test_a_repeat_run_sends_nothing(self):
        client = FakeAppStoreConnect(
            group=group_attributes(
                publicLinkEnabled=True, publicLinkLimitEnabled=True, publicLinkLimit=100
            )
        )
        changes, sent = self.enable(client, apply=True)
        self.assertEqual((changes, sent), ({}, False))
        self.assertEqual(client.writes(), [])

    def test_only_the_cap_is_sent_when_the_link_is_already_on(self):
        client = FakeAppStoreConnect(
            group=group_attributes(
                publicLinkEnabled=True, publicLinkLimitEnabled=False, publicLinkLimit=10_000
            )
        )
        changes, _ = self.enable(client, apply=True)
        self.assertEqual(changes, {"publicLinkLimitEnabled": True, "publicLinkLimit": 100})

    def test_enabling_is_refused_while_no_build_can_be_installed(self):
        for builds in ((), (("102", "WAITING_FOR_BETA_REVIEW"),), (("102", "BETA_REJECTED"),)):
            with self.subTest(builds=builds):
                client = FakeAppStoreConnect(builds=builds)
                with self.assertRaises(bd.ConfigurationError):
                    self.enable(client, apply=True)
                self.assertEqual(client.writes(), [])

    def test_disabling_needs_no_build_and_leaves_the_cap(self):
        client = FakeAppStoreConnect(
            group=group_attributes(
                publicLinkEnabled=True, publicLinkLimitEnabled=True, publicLinkLimit=100
            ),
            builds=(),
        )
        changes, sent = bd.set_public_link(
            client, bundle_id=BUNDLE, group_name=GROUP, enable=False, limit=None, apply=True
        )
        self.assertEqual(changes, {"publicLinkEnabled": False})
        self.assertTrue(sent)
        self.assertEqual(client.group["publicLinkLimit"], 100)

    def test_a_change_apple_does_not_keep_fails_the_read_back(self):
        client = FakeAppStoreConnect(ignore_patch=True)
        with self.assertRaises(AppStoreConnectError):
            self.enable(client, apply=True)

    def test_an_invalid_cap_is_refused_before_any_request(self):
        client = FakeAppStoreConnect()
        with self.assertRaises(bd.ConfigurationError):
            self.enable(client, apply=True, limit=10_001)
        self.assertEqual(client.requests, [])


class TestInformationTests(unittest.TestCase):
    def run_set(self, client, *, apply):
        return bd.set_test_info(
            client, bundle_id=BUNDLE, locale="en-GB", attributes=dict(TEST_INFO), apply=apply
        )

    def test_a_missing_locale_is_created_with_the_app_relationship(self):
        client = FakeAppStoreConnect()
        action, _, sent = self.run_set(client, apply=True)
        self.assertEqual((action, sent), ("create", True))
        method, path, body, expected = client.writes()[0]
        self.assertEqual((method, path, expected), ("POST", "/betaAppLocalizations", (201,)))
        self.assertEqual(body["data"]["attributes"]["locale"], "en-GB")
        self.assertEqual(
            body["data"]["relationships"]["app"]["data"], {"type": "apps", "id": APP_ID}
        )
        self.assertEqual(body["data"]["attributes"]["feedbackEmail"], "testing@tailendcharlie.app")

    def test_a_stale_locale_is_updated_with_only_what_differs(self):
        client = FakeAppStoreConnect(localizations=[localization(feedbackEmail="old@example.com")])
        action, payload, sent = self.run_set(client, apply=True)
        self.assertEqual((action, sent), ("update", True))
        self.assertEqual(payload, {"feedbackEmail": "testing@tailendcharlie.app"})
        self.assertEqual(client.writes()[0][:2], ("PATCH", "/betaAppLocalizations/loc-1"))

    def test_matching_information_is_left_alone(self):
        client = FakeAppStoreConnect(localizations=[localization()])
        self.assertEqual(self.run_set(client, apply=True), ("none", {}, False))
        self.assertEqual(client.writes(), [])

    def test_a_dry_run_sends_nothing(self):
        client = FakeAppStoreConnect()
        action, _, sent = self.run_set(client, apply=False)
        self.assertEqual((action, sent), ("create", False))
        self.assertEqual(client.writes(), [])

    def test_another_locale_is_not_mistaken_for_this_one(self):
        other = localization(locale="en-US")
        client = FakeAppStoreConnect(localizations=[other])
        action, _, _ = self.run_set(client, apply=False)
        self.assertEqual(action, "create")


class VerifyTests(unittest.TestCase):
    def verify(self, client, **kwargs):
        return bd.verify(client, bundle_id=BUNDLE, group_name=GROUP, **kwargs)

    def ready_client(self, **group):
        return FakeAppStoreConnect(
            group=group_attributes(
                publicLinkEnabled=True,
                publicLinkLimitEnabled=True,
                publicLinkLimit=100,
                publicLink="https://testflight.apple.com/join/abc",
                **group,
            ),
            localizations=[localization()],
        )

    def by_name(self, report):
        return {check.name: check for check in report.checks}

    def test_a_launched_group_passes_every_check_and_writes_nothing(self):
        client = self.ready_client()
        report = self.verify(client, expect_link="enabled")
        self.assertTrue(report.ok, [c for c in report.checks if not c.ok])
        self.assertEqual(client.writes(), [])
        self.assertIn(("Testers in the group", "7"), report.facts)

    def test_a_disabled_link_fails_when_enabled_is_expected(self):
        client = FakeAppStoreConnect(localizations=[localization()])
        checks = self.by_name(self.verify(client, expect_link="enabled"))
        self.assertFalse(checks["link"].ok)

    def test_an_enabled_link_fails_the_rollback_check(self):
        report = self.verify(self.ready_client(), expect_link="disabled", checks=("link",))
        self.assertFalse(report.ok)
        self.assertIn("STILL ENABLED", report.checks[0].detail)

    def test_a_disabled_link_passes_the_rollback_check_without_other_sections(self):
        client = FakeAppStoreConnect(localizations=[], builds=())
        report = self.verify(client, expect_link="disabled", checks=("link",))
        self.assertTrue(report.ok)
        # The rollback check must not need a build, test information or contact.
        self.assertFalse([r for r in client.requests if "betaAppLocalizations" in r[1]])

    def test_an_uncapped_link_fails(self):
        client = self.ready_client()
        client.group["publicLinkLimitEnabled"] = False
        checks = self.by_name(self.verify(client, expect_link="enabled"))
        self.assertFalse(checks["link-limit"].ok)

    def test_a_cap_other_than_the_expected_one_fails(self):
        client = self.ready_client()
        client.group["publicLinkLimit"] = 1000
        checks = self.by_name(self.verify(client, expect_link="enabled"))
        self.assertFalse(checks["link-limit"].ok)
        self.assertIn("expected 100", checks["link-limit"].detail)

    def test_no_installable_build_fails(self):
        client = self.ready_client()
        client.builds = [("102", "IN_BETA_REVIEW")]
        self.assertFalse(self.by_name(self.verify(client))["builds"].ok)

    def test_missing_or_wrong_test_information_fails_and_says_why(self):
        for localizations, expected in (
            ([], "no en-GB"),
            ([localization(description="")], "description empty"),
            ([localization(feedbackEmail="x@y.z")], "feedback email"),
            ([localization(privacyPolicyUrl="https://example.com")], "privacy URL"),
        ):
            with self.subTest(expected=expected):
                client = self.ready_client()
                client.localizations = localizations
                check = self.by_name(self.verify(client))["test-info"]
                self.assertFalse(check.ok)
                self.assertIn(expected, check.detail)

    def test_review_contact_gaps_are_named_without_printing_the_values(self):
        client = self.ready_client()
        client.review_detail = {
            "contactEmail": "secret@example.com",
            "contactPhone": "",
            "notes": "",
        }
        check = self.by_name(self.verify(client))["review-contact"]
        self.assertFalse(check.ok)
        self.assertIn("contact phone", check.detail)
        self.assertIn("reviewer notes", check.detail)
        self.assertNotIn("secret@example.com", check.detail)

    def test_an_unreadable_tester_count_is_reported_not_fatal(self):
        client = self.ready_client()
        client.testers = None
        report = self.verify(client)
        self.assertIn(("Testers in the group", "unknown"), report.facts)

    def test_the_internal_group_is_never_chosen(self):
        client = self.ready_client()
        client.group["isInternalGroup"] = True
        with self.assertRaises(AppStoreConnectError):
            self.verify(client)


COMMON_ARGS = [
    "--bundle-id", BUNDLE, "--group", GROUP,
    "--issuer-id", "issuer", "--key-id", "key", "--private-key", "unused.p8",
]  # fmt: skip


class CommandLineTests(unittest.TestCase):
    def run_main(self, argv, client):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = bd.main(argv, client=client)
        return code, out.getvalue(), err.getvalue()

    def test_public_link_defaults_to_a_dry_run(self):
        client = FakeAppStoreConnect()
        code, out, _ = self.run_main(["public-link", "enable", *COMMON_ARGS], client)
        self.assertEqual(code, 0)
        self.assertIn("Dry run", out)
        self.assertEqual(client.writes(), [])

    def test_public_link_apply_uses_the_default_cap_of_one_hundred(self):
        client = FakeAppStoreConnect()
        code, out, _ = self.run_main(["public-link", "enable", "--apply", *COMMON_ARGS], client)
        self.assertEqual(code, 0)
        self.assertEqual(client.group["publicLinkLimit"], 100)
        self.assertIn("read back", out)

    def test_a_refusal_is_a_failing_exit_with_a_message(self):
        client = FakeAppStoreConnect(builds=())
        code, _, err = self.run_main(["public-link", "enable", "--apply", *COMMON_ARGS], client)
        self.assertEqual(code, 1)
        self.assertIn("installable", err)

    def test_test_info_reads_the_description_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write(DESCRIPTION)
        self.addCleanup(Path(handle.name).unlink)
        client = FakeAppStoreConnect()
        code, out, _ = self.run_main(
            ["test-info", "--description-file", handle.name, "--apply", *COMMON_ARGS], client
        )
        self.assertEqual(code, 0, out)
        self.assertEqual(client.localizations[0]["attributes"]["description"], DESCRIPTION)

    def test_verify_exit_status_follows_the_checks(self):
        client = FakeAppStoreConnect(localizations=[localization()])
        code, out, _ = self.run_main(["verify", "--expect-link", "enabled", *COMMON_ARGS], client)
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] link", out)
        code, _, _ = self.run_main(
            ["verify", "--expect-link", "disabled", "--check", "link", *COMMON_ARGS], client
        )
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
