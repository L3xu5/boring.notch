#!/usr/bin/env python3

from __future__ import annotations

import base64
from contextlib import redirect_stderr, redirect_stdout
from email.utils import parsedate_to_datetime
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from create_fork_appcast import ED_SIGNATURE, SPARKLE_NS, create_appcast, main  # noqa: E402


class CreateForkAppcastTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Boring Notch.app"
        (self.app / "Contents").mkdir(parents=True)
        self.metadata = {
            "CFBundleVersion": "1351",
            "CFBundleShortVersionString": "2.8-yandex.1351",
            "LSMinimumSystemVersion": "14.5",
        }
        self.write_metadata()
        self.archive = self.root / "boringNotch-commit.zip"
        self.archive.write_bytes(b"packaged application")
        self.signature = base64.b64encode(bytes(range(64))).decode("ascii")
        self.signature_output = (
            f'sparkle:edSignature="{self.signature}" length="{self.archive.stat().st_size}"'
        )
        self.url = "https://github.com/example/fork/releases/download/latest/commit.zip"

    def write_metadata(self) -> None:
        with (self.app / "Contents" / "Info.plist").open("wb") as plist_file:
            plistlib.dump(self.metadata, plist_file)

    def create(self, **overrides: str) -> ET.ElementTree:
        return create_appcast(
            self.app,
            self.archive,
            overrides.get("url", self.url),
            overrides.get("signature", self.signature_output),
        )

    def test_uses_built_bundle_metadata_and_real_archive_size(self) -> None:
        tree = self.create()
        item = tree.getroot().find("channel/item")
        self.assertIsNotNone(item)
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}version"), "1351")
        self.assertEqual(
            item.findtext(f"{{{SPARKLE_NS}}}shortVersionString"), "2.8-yandex.1351"
        )
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion"), "14.5")
        self.assertEqual(parsedate_to_datetime(item.findtext("pubDate")).utcoffset().total_seconds(), 0)
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get(ED_SIGNATURE), self.signature)
        self.assertEqual(enclosure.get("url"), self.url)
        self.assertEqual(int(enclosure.get("length")), self.archive.stat().st_size)

    def test_xml_escapes_metadata_and_download_url(self) -> None:
        self.metadata["CFBundleShortVersionString"] = "2.8-yandex.<preview>&test"
        self.write_metadata()
        url = f"{self.url}?download=1&source=appcast"
        xml = ET.tostring(self.create(url=url).getroot(), encoding="unicode")
        self.assertIn("&lt;preview&gt;&amp;test", xml)
        self.assertIn("&amp;source=appcast", xml)
        reparsed = ET.fromstring(xml)
        self.assertEqual(
            reparsed.findtext(f"channel/item/{{{SPARKLE_NS}}}shortVersionString"),
            self.metadata["CFBundleShortVersionString"],
        )
        self.assertEqual(reparsed.find("channel/item/enclosure").get("url"), url)

    def test_rejects_non_positive_or_non_integer_bundle_version(self) -> None:
        for version in ("0", "-1", "1.5", "build 2", "", None, True):
            with self.subTest(version=version):
                self.metadata["CFBundleVersion"] = version
                if version is None:
                    del self.metadata["CFBundleVersion"]
                self.write_metadata()
                with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
                    self.create()

    def test_rejects_empty_short_version_or_minimum_system(self) -> None:
        for key in ("CFBundleShortVersionString", "LSMinimumSystemVersion"):
            original = self.metadata[key]
            for value in ("", "   "):
                with self.subTest(key=key, value=value):
                    self.metadata[key] = value
                    self.write_metadata()
                    with self.assertRaisesRegex(ValueError, key):
                        self.create()
            self.metadata[key] = original

    def test_rejects_signature_length_mismatch(self) -> None:
        with self.assertRaisesRegex(ValueError, "length does not match"):
            self.create(signature=f'sparkle:edSignature="{self.signature}" length="1"')

    def test_rejects_invalid_signature_output_and_wrong_ed25519_size(self) -> None:
        size = self.archive.stat().st_size
        invalid_outputs = (
            "not a signature",
            f'length="{size}"',
            f'sparkle:edSignature="%%%" length="{size}"',
            f'sparkle:edSignature="YWJj" length="{size}"',
            f'sparkle:edSignature="{self.signature}" length="{size}" extra="1"',
        )
        for output in invalid_outputs:
            with self.subTest(output=output):
                with self.assertRaises(ValueError):
                    self.create(signature=output)

    def test_rejects_empty_archive_and_non_https_url(self) -> None:
        for url in ("http://example.com/app.zip", "/app.zip", "https:///app.zip", "https://example.com/a b"):
            with self.subTest(url=url):
                with self.assertRaisesRegex(ValueError, "HTTPS"):
                    self.create(url=url)
        self.archive.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "must not be empty"):
            self.create()

    def test_cli_writes_valid_feed_and_preserves_output_on_invalid_input(self) -> None:
        output = self.root / "appcast.xml"
        arguments = [
            "--app", str(self.app),
            "--archive", str(self.archive),
            "--download-url", self.url,
            "--signature", self.signature_output,
            "--output", str(output),
        ]
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(arguments), 0)
        previous = output.read_bytes()
        ET.fromstring(previous)
        self.archive.write_bytes(b"different size")
        with redirect_stderr(io.StringIO()):
            self.assertEqual(main(arguments), 1)
        self.assertEqual(output.read_bytes(), previous)
        output.unlink()
        with redirect_stderr(io.StringIO()):
            self.assertEqual(main(arguments), 1)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
