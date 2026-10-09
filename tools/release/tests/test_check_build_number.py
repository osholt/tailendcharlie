from __future__ import annotations

import io
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.release.check_build_number import (  # noqa: E402
    MAX_BUILD_NUMBER,
    BuildNumberError,
    highest_play_version_code,
    highest_testflight_build,
    judge,
    main,
    parse_build_number,
    run_check,
)


class FakeRequest:
    def __init__(self, result, log=None, name=""):
        self.result = result
        self.log = log
        self.name = name

    def execute(self):
        if self.log is not None:
            self.log.append(self.name)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class FakeListing:
    def __init__(self, result, log):
        self.result = result
        self.log = log

    def list(self, **_kwargs):
        return FakeRequest(self.result, self.log, "list")


class FakePlay:
    """Shaped like the androidpublisher discovery client's `edits()` tree."""

    def __init__(self, *, tracks, bundles, delete_error=None):
        self.log = []
        self._tracks = tracks
        self._bundles = bundles
        self._delete_error = delete_error

    def edits(self):
        return self

    def insert(self, **_kwargs):
        return FakeRequest({"id": "edit-1"}, self.log, "insert")

    def delete(self, **_kwargs):
        return FakeRequest(self._delete_error or {}, self.log, "delete")

    def tracks(self):
        return FakeListing({"tracks": self._tracks}, self.log)

    def bundles(self):
        return FakeListing({"bundles": self._bundles}, self.log)


class FakeAppStoreClient:
    def __init__(self, apps, builds):
        self.apps = apps
        self.builds = builds
        self.requests = []

    def request(self, method, path, **kwargs):
        self.requests.append((method, path, kwargs))
        if path == "/apps":
            return {"data": self.apps}
        if path == "/builds":
            return {"data": self.builds}
        raise AssertionError(path)


def build(version):
    return {"attributes": {"version": version}}


class ParseBuildNumberTests(unittest.TestCase):
    def test_accepts_a_canonical_integer(self):
        self.assertEqual(parse_build_number("103"), 103)
        self.assertEqual(parse_build_number(" 103 "), 103)
        self.assertEqual(parse_build_number(str(MAX_BUILD_NUMBER)), MAX_BUILD_NUMBER)

    def test_rejects_what_cannot_be_a_build_number(self):
        for raw in (None, "", "  ", "0", "0103", "10.3", "103a", "-4", "1e3"):
            with self.subTest(raw=raw), self.assertRaises(BuildNumberError):
                parse_build_number(raw)

    def test_rejects_a_number_above_the_store_limit(self):
        with self.assertRaises(BuildNumberError):
            parse_build_number(str(MAX_BUILD_NUMBER + 1))

    def test_empty_message_names_the_input(self):
        with self.assertRaises(BuildNumberError) as caught:
            parse_build_number("")
        self.assertIn("build_number", str(caught.exception))


class JudgeTests(unittest.TestCase):
    def test_higher_than_the_store_is_accepted(self):
        self.assertTrue(judge(103, 102, store="Google Play").accepted)

    def test_first_ever_build_is_accepted(self):
        self.assertTrue(judge(1, None, store="Google Play").accepted)

    def test_a_reused_code_is_refused_with_the_number_to_use(self):
        verdict = judge(65, 67, store="Google Play")
        self.assertFalse(verdict.accepted)
        self.assertIn("build_number=68", verdict.message)
        self.assertIn("67", verdict.message)

    def test_equal_is_refused_unless_a_rerun_is_allowed(self):
        self.assertFalse(judge(102, 102, store="Google Play").accepted)
        rerun = judge(102, 102, store="App Store Connect", allow_equal=True)
        self.assertTrue(rerun.accepted)
        self.assertIn("re-run", rerun.message)

    def test_lower_is_refused_even_when_a_rerun_is_allowed(self):
        verdict = judge(101, 102, store="App Store Connect", allow_equal=True)
        self.assertFalse(verdict.accepted)


class PlayLookupTests(unittest.TestCase):
    def test_reads_codes_from_tracks_and_unreleased_bundles(self):
        service = FakePlay(
            tracks=[
                {"track": "internal", "releases": [{"versionCodes": ["102"]}]},
                {"track": "alpha", "releases": [{"versionCodes": ["99", "100"]}]},
                {"track": "beta", "releases": []},
            ],
            bundles=[{"versionCode": 98}, {"versionCode": 104}, {"sha1": "x"}],
        )
        self.assertEqual(highest_play_version_code(service, "app.example"), 104)

    def test_no_codes_means_no_highest(self):
        service = FakePlay(tracks=[{"track": "internal"}], bundles=[])
        self.assertIsNone(highest_play_version_code(service, "app.example"))

    def test_the_throwaway_edit_is_always_deleted_and_never_committed(self):
        service = FakePlay(tracks=[], bundles=[])
        highest_play_version_code(service, "app.example")
        self.assertEqual(service.log[0], "insert")
        self.assertEqual(service.log[-1], "delete")
        self.assertNotIn("commit", service.log)

    def test_a_failing_delete_does_not_lose_the_answer(self):
        service = FakePlay(
            tracks=[{"track": "alpha", "releases": [{"versionCodes": ["7"]}]}],
            bundles=[],
            delete_error=RuntimeError("edit already expired"),
        )
        self.assertEqual(highest_play_version_code(service, "app.example"), 7)


class TestFlightLookupTests(unittest.TestCase):
    def test_takes_the_highest_numeric_build(self):
        client = FakeAppStoreClient(
            apps=[{"id": "app-1"}],
            builds=[build("101"), build("102"), build("99"), build("1.2.3")],
        )
        self.assertEqual(highest_testflight_build(client, "app.example"), 102)
        method, path, kwargs = client.requests[-1]
        self.assertEqual((method, path), ("GET", "/builds"))
        self.assertEqual(kwargs["query"]["filter[app]"], "app-1")

    def test_an_app_with_no_builds_has_no_highest(self):
        client = FakeAppStoreClient(apps=[{"id": "app-1"}], builds=[])
        self.assertIsNone(highest_testflight_build(client, "app.example"))


class RunCheckTests(unittest.TestCase):
    def check(self, raw, highest, **kwargs):
        out = io.StringIO()
        status = run_check(
            raw,
            store="Google Play",
            lookup=highest if callable(highest) else (lambda: highest),
            out=out,
            **kwargs,
        )
        return status, out.getvalue()

    def test_a_fresh_number_passes(self):
        status, output = self.check("103", 102)
        self.assertEqual(status, 0)
        self.assertNotIn("::error", output)

    def test_the_630_collision_fails_before_any_build(self):
        status, output = self.check("65", 67)
        self.assertEqual(status, 1)
        self.assertIn("::error", output)
        self.assertIn("build_number=68", output)

    def test_a_missing_number_fails_even_with_no_lookup(self):
        out = io.StringIO()
        self.assertEqual(run_check("", store="Google Play", lookup=None, out=out), 1)
        self.assertIn("::error", out.getvalue())

    def test_without_credentials_only_the_format_is_checked(self):
        out = io.StringIO()
        status = run_check("103", store="Google Play", lookup=None, out=out)
        self.assertEqual(status, 0)
        self.assertIn("not compared with the store", out.getvalue())

    def test_a_lookup_failure_warns_and_does_not_block_the_release(self):
        def broken():
            raise OSError("network unreachable")

        status, output = self.check("103", broken)
        self.assertEqual(status, 0)
        self.assertIn("::warning::", output)
        self.assertIn("network unreachable", output)

    def test_a_lookup_failure_never_excuses_a_malformed_number(self):
        def broken():
            raise OSError("network unreachable")

        status, _ = self.check("0103", broken)
        self.assertEqual(status, 1)

    def test_an_equal_ios_number_is_a_rerun_not_an_error(self):
        status, output = self.check("102", 102, allow_equal=True)
        self.assertEqual(status, 0)
        self.assertIn("re-run", output)


class CommandLineTests(unittest.TestCase):
    def test_android_without_credentials_still_validates_the_format(self):
        self.assertEqual(main(["android", "--build-number", "103"]), 0)
        self.assertEqual(main(["android", "--build-number", ""]), 1)

    def test_ios_without_credentials_still_validates_the_format(self):
        self.assertEqual(main(["ios", "--build-number", "103"]), 0)
        self.assertEqual(main(["ios", "--build-number", "x"]), 1)

    def test_android_refuses_a_code_the_store_holds_including_the_highest(self):
        for number, expected in (("102", 1), ("101", 1), ("103", 0)):
            with self.subTest(number=number):
                with mock.patch(
                    "tools.release.check_build_number._android_lookup",
                    return_value=lambda: 102,
                ):
                    self.assertEqual(main(["android", "--build-number", number]), expected)

    def test_ios_rerun_of_the_highest_build_passes_but_older_is_refused(self):
        for number, expected in (("102", 0), ("101", 1), ("103", 0)):
            with self.subTest(number=number):
                with mock.patch(
                    "tools.release.check_build_number._ios_lookup",
                    return_value=lambda: 102,
                ):
                    self.assertEqual(main(["ios", "--build-number", number]), expected)


STORE_WORKFLOWS = ("android-internal.yml", "testflight.yml")


class StoreWorkflowTests(unittest.TestCase):
    """The workflows must keep the guard that this tool provides (#630)."""

    def workflow(self, name: str) -> str:
        return (ROOT / ".github" / "workflows" / name).read_text()

    def test_no_store_workflow_falls_back_to_the_run_number(self):
        for name in STORE_WORKFLOWS:
            with self.subTest(workflow=name):
                self.assertNotIn("run_number", self.workflow(name))

    def test_build_number_is_a_required_input(self):
        for name in STORE_WORKFLOWS:
            with self.subTest(workflow=name):
                match = re.search(
                    r"\n      build_number:\n((?:        .*\n)+)", self.workflow(name)
                )
                self.assertIsNotNone(match, "build_number input not found")
                self.assertIn("required: true", match.group(1))

    def test_the_check_runs_before_any_build_work(self):
        for name in STORE_WORKFLOWS:
            with self.subTest(workflow=name):
                text = self.workflow(name)
                check = text.index("tools.release.check_build_number")
                self.assertLess(check, text.index("flutter pub get"))
                self.assertLess(check, text.index("Resolve build identity"))


if __name__ == "__main__":
    unittest.main()
