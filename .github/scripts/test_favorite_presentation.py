#!/usr/bin/env python3
"""Compile whole favorite controls with interface fakes; no windows, media commands or app data."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-notch-favorite-presentation-") as path:
        directory = Path(path)
        defaults_object = directory / "Defaults.o"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            "-module-name", "Defaults", "-emit-module", "-emit-object",
            "-emit-module-path", str(directory / "Defaults.swiftmodule"),
            str(ROOT / "Tests/Fixtures/CameraDefaults.swift"), "-o", str(defaults_object),
        ], check=True, timeout=120)
        executable = directory / "favorite-presentation-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"), "-I", str(directory),
            str(ROOT / "boringNotch/components/Music/MusicTrackActions.swift"),
            str(ROOT / "boringNotch/components/HoverButton.swift"),
            str(ROOT / "Tests/FavoritePresentationTests.swift"), str(defaults_object),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
