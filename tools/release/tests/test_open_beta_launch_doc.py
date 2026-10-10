"""Keep the launch-day runbook honest about the workflows it tells someone to run.

docs/open-beta-launch.md is followed under pressure, on launch day, by someone
typing `gh workflow run` commands that open a public beta. A renamed input or a
changed confirmation phrase would turn a step into a failed dispatch at the worst
moment. These tests read the workflows and the document and require them to
agree.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.release.play_release_gate import CONFIRMATION_PHRASE  # noqa: E402

DOC = (ROOT / "docs" / "open-beta-launch.md").read_text(encoding="utf-8")
WORKFLOWS = ROOT / ".github" / "workflows"

# Workflow file -> (its `name:`, the inputs the launch document tells you to pass).
EXPECTED = {
    "android-internal.yml": (
        "Android internal testing",
        ["build_number", "promote_to", "confirm_open_testing", "android_auto", "notification_mode"],
    ),
    "android-promote.yml": (
        "Promote Android testing release",
        ["version_code", "source_track", "target_track"],
    ),
    "android-play-status.yml": ("Play track status", []),
    "testflight.yml": ("TestFlight", ["build_number", "submit_external"]),
    "testflight-status.yml": ("TestFlight status", ["build_number"]),
    "testflight-public-link.yml": (
        "TestFlight public link",
        ["action", "apply", "link_limit", "confirm_public_link", "expect_link"],
    ),
}


def workflow_text(name: str) -> str:
    return (WORKFLOWS / name).read_text(encoding="utf-8")


class LaunchDocTests(unittest.TestCase):
    def test_every_workflow_named_in_the_doc_exists_under_that_name(self):
        for filename, (name, _) in EXPECTED.items():
            with self.subTest(workflow=name):
                self.assertRegex(workflow_text(filename), rf"(?m)^name: {re.escape(name)}$")
                self.assertIn(f'"{name}"', DOC) if name != "TestFlight" else self.assertIn(
                    "workflow run TestFlight", DOC
                )

    def test_every_input_the_doc_passes_exists_in_its_workflow(self):
        for filename, (name, inputs) in EXPECTED.items():
            for field in inputs:
                with self.subTest(workflow=name, input=field):
                    self.assertRegex(workflow_text(filename), rf"(?m)^      {field}:$")
                    self.assertIn(field, DOC)

    def test_the_confirmation_phrases_in_the_doc_are_the_ones_enforced(self):
        self.assertEqual(CONFIRMATION_PHRASE, "publish-open-testing")
        self.assertIn(f"confirm_open_testing={CONFIRMATION_PHRASE}", DOC)
        self.assertIn("enable-public-link", DOC)
        self.assertIn('test "$CONFIRM" = "enable-public-link"', workflow_text("testflight-public-link.yml"))

    def test_the_default_cap_in_the_doc_is_the_one_in_the_tool(self):
        from tools.testflight.beta_distribution import DEFAULT_LINK_LIMIT

        self.assertIn(f"link_limit={DEFAULT_LINK_LIMIT}", DOC)
        self.assertIn(f"default: '{DEFAULT_LINK_LIMIT}'", workflow_text("testflight-public-link.yml"))

    def test_the_invite_variable_the_doc_asks_for_is_the_one_the_build_reads(self):
        self.assertIn("RIDE_RELAY_TESTFLIGHT_INVITE_URL", DOC)
        self.assertIn("vars.RIDE_RELAY_TESTFLIGHT_INVITE_URL", workflow_text("testflight.yml"))

    def test_the_decisions_are_stated_where_the_operator_will_look(self):
        self.assertIn("testing@tailendcharlie.app", DOC)
        self.assertIn("**100**", DOC)
        self.assertIn("**17**", DOC)
        self.assertIn("without Android Auto", DOC)


if __name__ == "__main__":
    unittest.main()
