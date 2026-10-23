#!/usr/bin/env python3
"""Execute the real fork publication step against a stateful GitHub CLI fake."""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / "workflows/build-latest.yml"
SOURCE_SHA = "a" * 40
SHORT_VERSION = "2.7.3-yandex.1353"
VERSION_TAG = f"v{SHORT_VERSION}"
ARCHIVE = f"boringNotch-{SOURCE_SHA}-123-1.zip"

MOCK_GH = r'''
import json
import os
from pathlib import Path
import sys

state_file = Path(os.environ["MOCK_GH_STATE"])
state = json.loads(state_file.read_text())
args = sys.argv[1:]
state["calls"].append(args)
state_file.write_text(json.dumps(state))

def option(name):
    return args[args.index(name) + 1]

def fail(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)

if args[0] == "api":
    method = option("--method") if "--method" in args else "GET"
    endpoint = args[3] if "--method" in args else args[1]
    tail = endpoint.removeprefix("repos/L3xu5/boring.notch/")
    if method == "GET":
        if tail == "git/ref/heads/main":
            print(state["head"])
        elif tail.startswith("git/ref/tags/"):
            tag = tail.removeprefix("git/ref/tags/")
            if state.get("fail") == "tag_lookup" and tag != "latest":
                fail("gh: service unavailable (HTTP 503)")
            if tag not in state["tags"]:
                fail("gh: Not Found (HTTP 404)")
            print(state["tags"][tag])
        elif tail.startswith("commits/"):
            tag = tail.removeprefix("commits/")
            print(state.get("tag_commits", {}).get(tag, state["tags"][tag]))
        else:
            fail("Unexpected GET: " + endpoint)
    elif method == "PATCH":
        tag = tail.removeprefix("git/refs/tags/")
        if tag not in state["tags"]:
            fail("gh: Reference does not exist (HTTP 422)")
        state["tags"][tag] = os.environ["GITHUB_SHA"]
    elif method == "POST" and tail == "git/refs":
        fields = [args[i + 1] for i, item in enumerate(args) if item == "-f"]
        tag = next(value.removeprefix("ref=refs/tags/") for value in fields if value.startswith("ref="))
        if tag in state["tags"]:
            fail("gh: Reference already exists (HTTP 422)")
        state["tags"][tag] = os.environ["GITHUB_SHA"]
    else:
        fail("Unexpected API operation: " + repr(args))
elif args[0] == "release":
    action, tag = args[1:3]
    release = state["releases"].get(tag)
    if action == "view":
        if state.get("fail") == "release_lookup" and tag != "latest":
            fail("gh: service unavailable (HTTP 503)")
        if release is None:
            fail("release not found")
        if "--json" in args:
            print("true" if release["draft"] else "false")
    elif action == "create":
        if release is not None:
            fail("Release already exists")
        state["releases"][tag] = {
            "draft": "--draft" in args,
            "title": option("--title"),
            "notes": Path(option("--notes-file")).read_text(),
            "target": option("--target"),
            "latest": False,
            "assets": {},
        }
    elif action == "upload":
        if release is None:
            fail("Release does not exist")
        for asset in args[3:]:
            if asset.startswith("--"):
                continue
            if state.get("fail") == f"upload:{tag}:{asset}":
                fail("Upload failed", 8)
            if asset in release["assets"] and "--clobber" not in args:
                fail("Asset already exists")
            release["assets"][asset] = Path(asset).read_text()
    elif action == "edit":
        if state.get("fail") == f"edit:{tag}":
            fail("Edit failed", 8)
        if release is None:
            fail("Release does not exist")
        for flag, key in [("--title", "title"), ("--target", "target")]:
            if flag in args:
                release[key] = option(flag)
        if "--notes-file" in args:
            release["notes"] = Path(option("--notes-file")).read_text()
        if "--latest=false" in args:
            release["latest"] = False
        if "--latest" in args:
            for other in state["releases"].values():
                other["latest"] = False
            release["latest"] = True
        if "--draft=false" in args:
            release["draft"] = False
            state["tags"].setdefault(tag, release["target"])
    else:
        fail("Unexpected release operation: " + repr(args))
else:
    fail("Unexpected gh command: " + repr(args))
state_file.write_text(json.dumps(state))
'''


def publication_script() -> str:
    workflow = WORKFLOW.read_text()
    marker = "      - name: Publish rolling and versioned releases\n"
    section = workflow.split(marker, 1)[1]
    block = section.split("        run: |\n", 1)[1]
    lines = []
    for line in block.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:] if line else "")
    return "\n".join(lines) + "\n"


class ForkPublishTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        bin_directory = self.root / "bin"
        bin_directory.mkdir()
        cli = bin_directory / "gh"
        cli.write_text(f"#!{sys.executable}\n" + textwrap.dedent(MOCK_GH))
        cli.chmod(0o755)
        self.state_file = self.root / "github.json"
        self.state = {
            "head": SOURCE_SHA,
            "tags": {"latest": "b" * 40},
            "releases": {"latest": self.release()},
            "calls": [],
        }
        self.environment = {
            **os.environ,
            "PATH": str(bin_directory) + os.pathsep + os.environ["PATH"],
            "MOCK_GH_STATE": str(self.state_file),
            "GITHUB_REPOSITORY": "L3xu5/boring.notch",
            "GITHUB_SHA": SOURCE_SHA,
            "RUNNER_TEMP": str(self.root),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "ARCHIVE": ARCHIVE,
            "SHORT": SHORT_VERSION,
            "BUILD": "1353",
        }
        for name, contents in [(ARCHIVE, "immutable archive"), ("boringNotch.zip", "current application"), ("appcast.xml", "signed feed")]:
            (self.root / name).write_text(contents)

    @staticmethod
    def release(*, draft: bool = False) -> dict:
        return {
            "draft": draft,
            "title": "Original title",
            "notes": "Maintainer's original notes",
            "target": SOURCE_SHA,
            "latest": not draft,
            "assets": {"boringNotch.zip": "original archive", "appcast.xml": "original feed"},
        }

    def execute(self) -> tuple[subprocess.CompletedProcess[str], dict]:
        self.state_file.write_text(json.dumps(self.state))
        result = subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", publication_script()],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
        )
        return result, json.loads(self.state_file.read_text())

    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_creates_a_visible_version_and_preserves_rolling_compatibility(self) -> None:
        result, state = self.execute()
        self.assert_success(result)
        rolling, version = state["releases"]["latest"], state["releases"][VERSION_TAG]
        self.assertEqual(rolling["title"], f"Rolling build {SHORT_VERSION}")
        self.assertFalse(rolling["latest"])
        self.assertEqual(rolling["assets"][ARCHIVE], "immutable archive")
        self.assertEqual(version["title"], f"Boring Notch — Yandex Music {SHORT_VERSION}")
        self.assertFalse(version["draft"])
        self.assertTrue(version["latest"])
        self.assertEqual(version["assets"], {"boringNotch.zip": "current application", "appcast.xml": "signed feed"})
        self.assertEqual(state["tags"]["latest"], SOURCE_SHA)
        self.assertEqual(state["tags"][VERSION_TAG], SOURCE_SHA)
        calls = state["calls"]
        uploads = [call for call in calls if call[:3] == ["release", "upload", "latest"]]
        self.assertEqual([call[3] for call in uploads], [ARCHIVE, "boringNotch.zip", "appcast.xml"])
        self.assertNotIn("--clobber", uploads[0])
        self.assertEqual(calls[-1][:3], ["release", "edit", VERSION_TAG])
        self.assertIn("--draft=false", calls[-1])

    def test_first_release_can_create_both_missing_tags(self) -> None:
        self.state["tags"] = {}
        self.state["releases"] = {}
        result, state = self.execute()
        self.assert_success(result)
        self.assertEqual(state["tags"], {"latest": SOURCE_SHA, VERSION_TAG: SOURCE_SHA})
        self.assertFalse(state["releases"]["latest"]["draft"])
        self.assertTrue(state["releases"][VERSION_TAG]["latest"])

    def test_resumes_a_draft_and_replaces_its_unpublished_assets(self) -> None:
        self.state["releases"][VERSION_TAG] = self.release(draft=True)
        result, state = self.execute()
        self.assert_success(result)
        version = state["releases"][VERSION_TAG]
        self.assertFalse(version["draft"])
        self.assertTrue(version["latest"])
        self.assertEqual(version["assets"]["boringNotch.zip"], "current application")
        self.assertFalse(any(call[:3] == ["release", "create", VERSION_TAG] for call in state["calls"]))

    def test_published_version_assets_notes_and_title_survive_a_rerun(self) -> None:
        original = self.release()
        self.state["releases"][VERSION_TAG] = copy.deepcopy(original)
        self.state["tags"][VERSION_TAG] = SOURCE_SHA
        result, state = self.execute()
        self.assert_success(result)
        self.assertEqual(state["releases"][VERSION_TAG], original)
        self.assertFalse(any(call[:2] in [["release", "upload"], ["release", "edit"], ["release", "create"]] and call[2] == VERSION_TAG for call in state["calls"]))

    def test_stale_main_skips_every_mutation(self) -> None:
        self.state["head"] = "c" * 40
        original = copy.deepcopy(self.state)
        result, state = self.execute()
        self.assert_success(result)
        self.assertEqual(state["tags"], original["tags"])
        self.assertEqual(state["releases"], original["releases"])
        self.assertEqual(len(state["calls"]), 1)

    def test_conflicting_version_tag_stops_before_any_mutation(self) -> None:
        self.state["tags"][VERSION_TAG] = "c" * 40
        original = copy.deepcopy(self.state)
        result, state = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace", result.stdout)
        self.assertEqual(state["tags"], original["tags"])
        self.assertEqual(state["releases"], original["releases"])

    def test_annotated_version_tag_resolves_to_the_source_commit(self) -> None:
        self.state["tags"][VERSION_TAG] = "c" * 40
        self.state["tag_commits"] = {VERSION_TAG: SOURCE_SHA}
        result, state = self.execute()
        self.assert_success(result)
        self.assertFalse(state["releases"][VERSION_TAG]["draft"])

    def test_lookup_errors_are_not_treated_as_missing_releases_or_tags(self) -> None:
        for failure in ["tag_lookup", "release_lookup"]:
            with self.subTest(failure=failure):
                self.state["fail"] = failure
                result, state = self.execute()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["releases"], self.state["releases"])
                self.assertEqual(state["tags"], self.state["tags"])

    def test_upload_errors_stop_before_later_publication(self) -> None:
        for failure in [
            f"upload:latest:{ARCHIVE}",
            "upload:latest:boringNotch.zip",
            "upload:latest:appcast.xml",
            f"upload:{VERSION_TAG}:boringNotch.zip",
            f"edit:{VERSION_TAG}",
        ]:
            with self.subTest(failure=failure):
                self.state["fail"] = failure
                result, state = self.execute()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["calls"][-1][:2], ["release", failure.split(":")[0]])
                version = state["releases"].get(VERSION_TAG)
                if version is not None:
                    self.assertTrue(version["draft"])
                    self.assertFalse(version["latest"])


if __name__ == "__main__":
    unittest.main()
