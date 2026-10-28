#!/usr/bin/env python3
"""Test the whole read-only power provider and its pure classification/stability policy.

--native-self-test creates and releases one assertion owned by this test process only.
--sample-yandex reads the verified running Yandex main PID; no player/window/permission action.
"""

from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--native-self-test", action="store_true")
    mode.add_argument("--sample-yandex", action="store_true")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="boring-yandex-playback-power-") as path:
        directory = Path(path)
        executable = directory / "playback-power-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            str(ROOT / "boringNotch/MediaControllers/YandexPlaybackPowerState.swift"),
            str(ROOT / "Tests/YandexPlaybackPowerTests.swift"), "-o", str(executable),
        ], check=True, timeout=120)
        flags = ["--native-self-test"] if arguments.native_self_test else ["--sample-yandex"] if arguments.sample_yandex else []
        subprocess.run([str(executable), *flags], check=True, timeout=30)


if __name__ == "__main__":
    main()
