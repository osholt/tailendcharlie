from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "assert_android_auto", ROOT / "tools" / "assert-android-auto-disabled.py"
)
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)

CAR_MANIFEST = ROOT / "apps/mobile/android/app/src/androidAuto/AndroidManifest.xml"
MAIN_MANIFEST = ROOT / "apps/mobile/android/app/src/main/AndroidManifest.xml"


class AssertAndroidAutoTests(unittest.TestCase):
    def write(self, text: str) -> Path:
        handle = tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False)
        self.addCleanup(Path(handle.name).unlink)
        handle.write(text)
        handle.close()
        return Path(handle.name)

    def test_the_shipped_main_manifest_declares_no_android_auto(self):
        self.assertEqual(TOOL.check([MAIN_MANIFEST], "disabled"), [])

    def test_the_preserved_car_manifest_is_exactly_what_enabled_requires(self):
        # The source set the -PandroidAuto switch merges must satisfy the
        # enabled check, or the switch would build a bundle the check refuses.
        self.assertEqual(TOOL.check([CAR_MANIFEST], "enabled"), [])
        self.assertNotEqual(TOOL.check([CAR_MANIFEST], "disabled"), [])

    def test_every_forbidden_declaration_is_caught_on_its_own(self):
        for value in TOOL.FORBIDDEN:
            with self.subTest(value=value):
                path = self.write(f'<manifest><x android:name="{value}"/></manifest>')
                failures = TOOL.check([path], "disabled")
                self.assertEqual(len(failures), 1)
                self.assertIn(value, failures[0])

    def test_enabled_names_what_is_missing(self):
        path = self.write("<manifest/>")
        failures = TOOL.check([path], "enabled")
        self.assertEqual(len(failures), 1)
        self.assertIn("TailEndCharlieCarAppService", failures[0])

    def test_a_phone_manifest_is_not_a_car_manifest(self):
        self.assertNotEqual(TOOL.check([MAIN_MANIFEST], "enabled"), [])


if __name__ == "__main__":
    unittest.main()
