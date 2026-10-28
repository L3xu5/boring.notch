#!/usr/bin/env python3
"""Link the actual snapshot reader to owned Perl/pipe fixtures; no real adapter or client."""

from pathlib import Path
import subprocess
import tempfile

from media_test_support import core_arguments

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-media-snapshot-tests-") as path:
        directory = Path(path)
        executable = directory / "snapshot-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"), *core_arguments(directory),
            str(ROOT / "boringNotch/MediaControllers/MediaAdapterSnapshotReader.swift"),
            str(ROOT / "Tests/MediaAdapterSnapshotTests.swift"), "-o", str(executable),
        ], check=True, timeout=180)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
