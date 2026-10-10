"""Guard the public beta listing text against claims the evidence does not support.

The words in `docs/open-beta-listing/` are what a stranger reads before they
install a safety-adjacent app. AGENTS.md forbids claiming Nearby, background,
battery, CarPlay, Android Auto or PiP support without physical evidence, and the
open-beta plan (G4) repeats it for UI copy. These tests make the listing keep to
that, and keep the support address, age and not-an-emergency-service statements
from being edited out.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

LISTING = Path(__file__).resolve().parents[2] / "docs" / "open-beta-listing"
SUPPORT_EMAIL = "testing@tailendcharlie.app"

# Apple and Google's limits for each field.
LIMITS = {
    "testflight-beta-description.txt": 4_000,
    "testflight-review-notes.txt": 4_000,
    "whats-to-test.txt": 4_000,
    "play-full-description.txt": 4_000,
    "play-short-description.txt": 80,
    "play-release-notes.txt": 500,
}

# A sentence that mentions one of these must also hedge. "Android Auto is not
# supported" and "CarPlay is experimental" pass; "works with CarPlay" does not.
CLAIM_TERMS = re.compile(
    r"android auto|carplay|bluetooth|nearby|background|offline|battery|picture-in-picture",
    re.IGNORECASE,
)
HEDGES = re.compile(
    r"\b(not|cannot|experimental|unverified|unproven|yet|never|optional|do not rely)\b",
    re.IGNORECASE,
)
# Promises nobody can keep, whatever the hedge.
FORBIDDEN = (
    r"\bguarantee",
    r"\bnever (?:lose|get lost)",
    r"\b(?:always|100%) (?:safe|reliable)",
    r"\bworks (?:offline|without (?:signal|coverage|reception))",
    r"\bcalls? (?:the )?(?:emergency services|999|112)",
    r"\bcrash detection\b",
    r"\bfully (?:tested|supported)\b",
)


def read(name: str) -> str:
    return (LISTING / name).read_text(encoding="utf-8")


def sentences(text: str) -> list[str]:
    return [part.strip() for part in re.split(r"(?<=[.!?])\s+|\n+", text) if part.strip()]


class ListingTests(unittest.TestCase):
    def test_every_field_fits_its_store_limit(self):
        for name, limit in LIMITS.items():
            with self.subTest(name=name):
                self.assertLessEqual(len(read(name).strip()), limit)

    def test_every_listed_file_exists_and_nothing_unlisted_ships(self):
        self.assertEqual({path.name for path in LISTING.glob("*.txt")}, set(LIMITS))

    def test_risky_features_are_only_ever_mentioned_with_a_hedge(self):
        for name in LIMITS:
            for sentence in sentences(read(name)):
                if CLAIM_TERMS.search(sentence):
                    with self.subTest(name=name, sentence=sentence):
                        self.assertRegex(sentence, HEDGES)

    def test_no_promise_the_app_cannot_keep(self):
        for name in LIMITS:
            text = read(name)
            for pattern in FORBIDDEN:
                with self.subTest(name=name, pattern=pattern):
                    self.assertIsNone(re.search(pattern, text, re.IGNORECASE))

    def test_the_support_address_is_where_a_tester_will_look(self):
        for name in (
            "testflight-beta-description.txt",
            "play-full-description.txt",
            "play-release-notes.txt",
            "whats-to-test.txt",
            "testflight-review-notes.txt",
        ):
            with self.subTest(name=name):
                self.assertIn(SUPPORT_EMAIL, read(name))

    def test_the_age_and_emergency_statements_cannot_be_edited_out(self):
        for name in ("testflight-beta-description.txt", "play-full-description.txt"):
            with self.subTest(name=name):
                text = read(name)
                self.assertIn("17 or over", text)
                self.assertIn("not an emergency service", text)
                self.assertIn("privacy.html", text)

    def test_android_auto_is_not_claimed_on_the_android_listing(self):
        text = read("play-full-description.txt")
        self.assertIn("Android Auto is not supported in this beta", text)

    def test_the_review_notes_tell_a_reviewer_how_to_use_it_alone(self):
        self.assertIn("Try a simulated ride", read("testflight-review-notes.txt"))


if __name__ == "__main__":
    unittest.main()
