from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.release.play_release_gate import (  # noqa: E402
    CONFIRMATION_PHRASE,
    check_open_testing_gate,
    find_release,
    main,
    parse_flag,
    verify_track,
)


class FakeRequest:
    def __init__(self, result, log, name):
        self.result, self.log, self.name = result, log, name

    def execute(self):
        self.log.append(self.name)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class FakeTracks:
    def __init__(self, tracks, log):
        self._tracks, self.log = tracks, log

    def list(self, **_kwargs):
        return FakeRequest({"tracks": self._tracks}, self.log, "list")


class FakePlay:
    def __init__(self, tracks, delete_error=None):
        self.log = []
        self._tracks = tracks
        self._delete_error = delete_error

    def edits(self):
        return self

    def insert(self, **_kwargs):
        return FakeRequest({"id": "edit-1"}, self.log, "insert")

    def delete(self, **_kwargs):
        return FakeRequest(self._delete_error or {}, self.log, "delete")

    def tracks(self):
        return FakeTracks(self._tracks, self.log)


def release(codes, status="completed"):
    return {"versionCodes": [str(code) for code in codes], "status": status}


class GateTests(unittest.TestCase):
    def test_beta_needs_the_exact_confirmation_phrase(self):
        for confirm in ("", "yes", "publish", CONFIRMATION_PHRASE.upper(), "beta"):
            with self.subTest(confirm=confirm):
                allowed, message = check_open_testing_gate(
                    promote_to="beta", confirm=confirm, android_auto=False
                )
                self.assertFalse(allowed)
                self.assertIn(CONFIRMATION_PHRASE, message)

    def test_beta_with_the_phrase_is_allowed(self):
        allowed, _ = check_open_testing_gate(
            promote_to="beta", confirm=CONFIRMATION_PHRASE, android_auto=False
        )
        self.assertTrue(allowed)

    def test_beta_never_carries_android_auto_even_when_confirmed(self):
        allowed, message = check_open_testing_gate(
            promote_to="beta", confirm=CONFIRMATION_PHRASE, android_auto=True
        )
        self.assertFalse(allowed)
        self.assertIn("Android Auto", message)

    def test_closed_tracks_need_no_confirmation_and_may_carry_android_auto(self):
        for track in ("alpha", "none", "internal"):
            with self.subTest(track=track):
                for android_auto in (False, True):
                    allowed, _ = check_open_testing_gate(
                        promote_to=track, confirm="", android_auto=android_auto
                    )
                    self.assertTrue(allowed)

    def test_a_confirmation_on_a_closed_track_is_ignored(self):
        allowed, message = check_open_testing_gate(
            promote_to="alpha", confirm=CONFIRMATION_PHRASE, android_auto=False
        )
        self.assertTrue(allowed)
        self.assertIn("not the public", message)

    def test_flags_parse_the_workflow_spelling(self):
        self.assertTrue(parse_flag("true"))
        self.assertTrue(parse_flag("True"))
        self.assertFalse(parse_flag("false"))
        self.assertFalse(parse_flag(""))
        self.assertFalse(parse_flag(None))
        with self.assertRaises(ValueError):
            parse_flag("maybe")

    def test_main_exit_codes(self):
        out = io.StringIO()
        self.assertEqual(
            main(["gate", "--promote-to", "beta", "--android-auto", "false"], out=out), 1
        )
        self.assertIn("::error", out.getvalue())
        out = io.StringIO()
        self.assertEqual(
            main(
                [
                    "gate",
                    "--promote-to",
                    "beta",
                    "--confirm",
                    CONFIRMATION_PHRASE,
                    "--android-auto",
                    "false",
                ],
                out=out,
            ),
            0,
        )
        out = io.StringIO()
        self.assertEqual(
            main(["gate", "--promote-to", "alpha", "--android-auto", "nonsense"], out=out), 1
        )


class VerifyTrackTests(unittest.TestCase):
    def test_a_completed_release_holding_the_code_passes(self):
        service = FakePlay([{"track": "beta", "releases": [release([103])]}])
        ok, message = verify_track(
            service, package="app.tailendcharlie", track="beta", version_code=103
        )
        self.assertTrue(ok, message)
        self.assertEqual(service.log, ["insert", "list", "delete"])

    def test_the_wrong_track_does_not_count(self):
        service = FakePlay([{"track": "alpha", "releases": [release([103])]}])
        ok, message = verify_track(
            service, package="app.tailendcharlie", track="beta", version_code=103
        )
        self.assertFalse(ok)
        self.assertIn("does not hold", message)

    def test_a_draft_beside_a_live_release_does_not_count(self):
        # A committed `status: draft` write reports success and serves nobody.
        service = FakePlay([{"track": "beta", "releases": [release([7]), release([103], "draft")]}])
        ok, message = verify_track(
            service, package="app.tailendcharlie", track="beta", version_code=103
        )
        self.assertFalse(ok)
        self.assertIn("'draft'", message)

    def test_the_edit_is_deleted_even_when_listing_fails(self):
        service = FakePlay([])
        service.tracks = lambda: type(
            "Boom",
            (),
            {"list": lambda _self, **_k: FakeRequest(RuntimeError("down"), service.log, "list")},
        )()
        with self.assertRaises(RuntimeError):
            verify_track(service, package="p", track="beta", version_code=1)
        self.assertEqual(service.log[-1], "delete")

    def test_a_failed_edit_delete_is_not_fatal(self):
        service = FakePlay(
            [{"track": "beta", "releases": [release([103])]}],
            delete_error=RuntimeError("expired"),
        )
        ok, _ = verify_track(service, package="p", track="beta", version_code=103)
        self.assertTrue(ok)

    def test_find_release_matches_integer_or_string_codes(self):
        tracks = [{"track": "beta", "releases": [{"versionCodes": [103], "status": "completed"}]}]
        self.assertIsNotNone(find_release(tracks, "beta", 103))
        self.assertIsNone(find_release(tracks, "beta", 104))


if __name__ == "__main__":
    unittest.main()
