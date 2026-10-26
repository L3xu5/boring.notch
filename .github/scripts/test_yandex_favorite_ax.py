#!/usr/bin/env python3
"""Test the actual AX favorite parser using only immutable, in-memory player snapshots."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-yandex-favorite-ax-") as path:
        directory = Path(path)
        executable = directory / "favorite-ax-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            str(ROOT / "boringNotch/MediaControllers/YandexAccessibilityClient.swift"),
            str(ROOT / "Tests/YandexFavoriteAXTests.swift"), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
