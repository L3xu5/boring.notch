"""A preview command must not execute a Release app where privacy gates are compiled out."""
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import preview_ui


class PreviewSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Fixture.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/Fixture").write_bytes(b"fixture executable; never run")

    def write_info(self, configuration=None, executable="Fixture"):
        info = {"CFBundleExecutable": executable}
        if configuration is not None:
            info["BNBuildConfiguration"] = configuration
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)

    def test_debug_bundle_is_accepted(self):
        self.write_info("Debug")
        self.assertEqual(preview_ui.validate_debug_bundle(self.app)["BNBuildConfiguration"], "Debug")

    def test_release_and_missing_capability_are_rejected(self):
        for configuration in (None, "Release", "Custom"):
            self.write_info(configuration)
            with self.assertRaises(ValueError):
                preview_ui.validate_debug_bundle(self.app)

    def test_release_command_never_signs_or_launches_the_app(self):
        self.write_info("Release")
        output = Path(self.temporary.name) / "output"
        with mock.patch.object(sys, "argv", ["preview_ui.py", "--app", str(self.app), "--output", str(output)]), \
             mock.patch.object(preview_ui.subprocess, "run") as execute, \
             mock.patch.object(preview_ui.shutil, "copytree") as copy:
            with self.assertRaises(SystemExit) as result:
                preview_ui.main()
        self.assertEqual(result.exception.code, 2)
        execute.assert_not_called()
        copy.assert_not_called()
        self.assertFalse(output.exists())
