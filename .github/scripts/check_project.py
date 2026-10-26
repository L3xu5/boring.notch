#!/usr/bin/env python3
"""Canonical project validation: Linux-compatible release tests and macOS native suites.

Usage: check_project.py [--python-only | --native-only]
The default runs both groups. Native checks build/test the real Swift 6 package once, then
link every platform fixture to the same fingerprint-verified SwiftPM static archive.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from media_test_support import (
    ARTIFACTS_ENV, CoreArtifactsError, compiler_identity, core_inputs,
    validate_artifacts, write_artifact_manifest,
)

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github/scripts"
NATIVE_SUITES = (
    "run_yandex_auth_tests.py",
    "test_lyrics.py",
    "test_music_metadata.py",
    "test_yandex_metadata.py",
    "test_yandex_favorite_ax.py",
    "test_media_stream.py",
    "test_media_keys.py",
    "test_media_key_recovery.py",
    "test_artwork_transport.py",
    "test_media_checker.py",
    "test_native_utilities.py",
    "test_camera_presentation.py",
    "test_slider_input.py",
    "test_spotify_lifecycle.py",
    "test_shelf_preview.py",
)


def run(arguments: list[str], *, environment: dict[str, str] | None = None,
        timeout: int = 600) -> None:
    subprocess.run(arguments, cwd=ROOT, env=environment, check=True, timeout=timeout)


def python_checks() -> None:
    print("Checking release/tooling Python tests", flush=True)
    run([sys.executable, "-m", "unittest", "discover", "-s", str(SCRIPTS / "tests"), "-v"])


def native_checks() -> None:
    if sys.platform != "darwin":
        raise RuntimeError("Native checks require macOS and Xcode; use --python-only on Linux")
    with tempfile.TemporaryDirectory(prefix="boring-notch-checks-") as path:
        temporary = Path(path)
        environment = os.environ.copy()
        environment.pop(ARTIFACTS_ENV, None)
        environment["CLANG_MODULE_CACHE_PATH"] = str(temporary / "ModuleCache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(temporary / "ModuleCache")
        compiler = compiler_identity()
        # SwiftPM and fixture xcrun calls use the same selected compiler, even if a shell has
        # a custom SWIFT_EXEC setting. No HOME replacement or user cache writes are needed.
        environment["SWIFT_EXEC"] = compiler["executable"]
        environment["SDKROOT"] = compiler["sdk"]
        inputs = core_inputs(compiler=compiler)
        common = [
            "--package-path", str(ROOT / "Packages/BoringCore"),
            "--scratch-path", str(temporary / "Build"),
            "--cache-path", str(temporary / "PackageCache"),
            "--config-path", str(temporary / "PackageConfig"),
            "--security-path", str(temporary / "PackageSecurity"),
            "--disable-sandbox", "--configuration", "debug",
            "-Xswiftc", "-swift-version", "-Xswiftc", "6",
        ]
        print("Checking the actual Swift 6 BoringCore package", flush=True)
        run(["xcrun", "swift", "test", *common], environment=environment)
        run(["xcrun", "swift", "build", *common, "--product", "BoringCore"], environment=environment)
        output = subprocess.check_output(
            ["xcrun", "swift", "build", *common, "--show-bin-path"],
            cwd=ROOT, env=environment, text=True, stderr=subprocess.PIPE,
        ).strip()
        artifacts = Path(output).resolve()
        if not artifacts.is_relative_to(temporary.resolve()):
            raise CoreArtifactsError("SwiftPM returned artifacts outside the private check directory")
        if inputs != core_inputs(compiler=compiler):
            raise CoreArtifactsError("BoringCore sources changed while checks were building; run checks again after the edits finish")
        write_artifact_manifest(artifacts, inputs)
        validate_artifacts(artifacts, compiler=compiler)
        environment[ARTIFACTS_ENV] = str(artifacts)
        for filename in NATIVE_SUITES:
            print(f"Checking {filename} (verified shared Core build)", flush=True)
            run([sys.executable, str(SCRIPTS / filename)], environment=environment, timeout=180)
        # Cover fixtures that do not use Core too: an edit during the final platform suite must
        # not leave a successful result associated with a different package snapshot.
        if inputs != core_inputs(compiler=compiler):
            raise CoreArtifactsError("BoringCore changed during native checks; rerun the check command")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--python-only", action="store_true", help="Run release/tooling unittest checks; no Swift/Xcode required")
    modes.add_argument("--native-only", action="store_true", help="Run Core SwiftPM and every macOS platform suite")
    arguments = parser.parse_args()
    started = time.monotonic()
    try:
        if not arguments.native_only:
            python_checks()
        if not arguments.python_only:
            native_checks()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, CoreArtifactsError, RuntimeError) as error:
        print(f"Project checks failed: {error}", file=sys.stderr)
        return 1
    print(f"Project checks passed in {time.monotonic() - started:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
