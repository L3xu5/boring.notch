#!/usr/bin/env python3
"""Test the production policy and actual coordinator with fake native/player state."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    source = (ROOT / "boringNotch/managers/MusicManager.swift").read_text()
    property_start = source.index("    private var mediaKeyRecoveryTask:")
    properties = source[property_start:source.index("\n\n", property_start)]
    methods = source[
        source.index("    // MARK: - Native media-key recovery\n"):
        source.index("    // MARK: - Lyrics\n")
    ]
    fixture = (ROOT / "Tests/MediaKeyRecoveryCoordinatorTests.swift").read_text()
    fixture = fixture.replace("    // PRODUCTION_RECOVERY_PROPERTIES", properties)
    fixture = fixture.replace("    // PRODUCTION_RECOVERY_METHODS", methods)
    with tempfile.TemporaryDirectory(prefix="boring-notch-media-recovery-tests-") as directory:
        directory = Path(directory)
        executable = directory / "media-recovery-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
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
            str(ROOT / "boringNotch/helpers/MediaKeyRecoveryPolicy.swift"),
            str(coordinator_source), "-o", str(coordinator_executable),
        ], check=True, timeout=120)
        subprocess.run([str(coordinator_executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
