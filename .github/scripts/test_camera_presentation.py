#!/usr/bin/env python3
"""Compile the whole production VM with interface-only fakes: no logic extraction."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-notch-camera-ui-tests-") as directory:
        directory = Path(directory)
        defaults_object = directory / "Defaults.o"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            "-module-name", "Defaults", "-emit-module", "-emit-object",
            "-emit-module-path", str(directory / "Defaults.swiftmodule"),
            str(ROOT / "Tests/Fixtures/CameraDefaults.swift"), "-o", str(defaults_object),
        ], check=True, timeout=120)
        executable = directory / "camera-presentation-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"), "-I", str(directory),
            str(ROOT / "boringNotch/models/BoringViewModel.swift"),
            str(ROOT / "Tests/CameraPresentationTests.swift"), str(defaults_object),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
