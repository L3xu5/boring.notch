#!/usr/bin/env python3
"""Test the production policy and actual coordinator with fake native/player state."""

from pathlib import Path
from media_test_support import core_arguments
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    fixture = (ROOT / "Tests/MediaKeyRecoveryCoordinatorTests.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="boring-notch-media-recovery-tests-") as directory:
        directory = Path(directory)
        domain_arguments = core_arguments(directory)
        executable = directory / "media-recovery-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            *domain_arguments,
            str(ROOT / "boringNotch/helpers/MediaKeyRecoveryPolicy.swift"),
            str(ROOT / "Tests/MediaKeyRecoveryTests.swift"),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)
        coordinator_source = directory / "MediaKeyRecoveryCoordinatorTests.swift"
        coordinator_source.write_text(fixture)
        coordinator_executable = directory / "media-recovery-coordinator-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            *domain_arguments,
            str(ROOT / "boringNotch/helpers/MediaKeyRecoveryPolicy.swift"),
            str(coordinator_source), str(ROOT / "boringNotch/MediaControllers/MediaKeyRecoveryCoordinator.swift"), "-o", str(coordinator_executable),
        ], check=True, timeout=120)
        subprocess.run([str(coordinator_executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
