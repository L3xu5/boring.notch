#!/usr/bin/env python3
"""Compile the production media-key handler and exercise only in-memory events."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-notch-media-key-tests-") as directory:
        directory = Path(directory)
        executable = directory / "media-key-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            str(ROOT / "boringNotch/observers/MediaTransportKeyMonitor.swift"),
            str(ROOT / "Tests/MediaTransportKeyTests.swift"),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
