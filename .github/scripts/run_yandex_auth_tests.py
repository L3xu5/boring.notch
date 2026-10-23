#!/usr/bin/env python3
"""Compile the production OAuth/token store with fake-storage regression tests on macOS."""

from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="boring-notch-auth-tests-") as directory:
        temporary = Path(directory)
        executable = temporary / "auth-tests"
        subprocess.run(
            [
                "swiftc", "-swift-version", "5", "-parse-as-library",
                "-module-cache-path", str(temporary / "ModuleCache"),
                str(root / "boringNotch/helpers/YandexMusicTokenStore.swift"),
                str(root / "Tests/YandexMusicAuthTests.swift"),
                "-o", str(executable),
            ],
            check=True,
            cwd=root,
        )
        subprocess.run([str(executable)], check=True, cwd=root)


if __name__ == "__main__":
    main()
