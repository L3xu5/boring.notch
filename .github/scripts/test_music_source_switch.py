#!/usr/bin/env python3
"""Compile the complete production MusicManager with in-memory source/probe boundaries."""

from pathlib import Path
import subprocess
import tempfile

from media_test_support import core_arguments

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-music-source-switch-") as path:
        directory = Path(path)
        defaults_object = directory / "Defaults.o"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            "-module-name", "Defaults", "-emit-module", "-emit-object",
            "-emit-module-path", str(directory / "Defaults.swiftmodule"),
            str(ROOT / "Tests/Fixtures/CameraDefaults.swift"), "-o", str(defaults_object),
        ], check=True, timeout=120)
        # Append fixture access in the same lexical file, preserving the entire production
        # class verbatim. No command, cancellation or source-routing methods are extracted.
        source = directory / "MusicSourceSwitchTests.swift"
        source.write_text((ROOT / "boringNotch/managers/MusicManager.swift").read_text()
                          + "\n" + (ROOT / "Tests/MusicSourceSwitchTests.swift").read_text())
        executable = directory / "music-source-switch-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"), "-I", str(directory),
            *core_arguments(directory), str(source),
            str(ROOT / "boringNotch/models/PlaybackState.swift"),
            str(ROOT / "boringNotch/MediaControllers/MediaControllerProtocol.swift"),
            str(defaults_object), "-o", str(executable),
        ], check=True, timeout=180)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
