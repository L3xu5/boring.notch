#!/usr/bin/env python3
"""Exercise whole SwiftUI slider sources with events sent only to an owned offscreen panel."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-notch-slider-input-") as path:
        directory = Path(path)
        defaults_object = directory / "Defaults.o"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            "-module-name", "Defaults", "-emit-module", "-emit-object",
            "-emit-module-path", str(directory / "Defaults.swiftmodule"),
            str(ROOT / "Tests/Fixtures/CameraDefaults.swift"), "-o", str(defaults_object),
        ], check=True, timeout=120)
        executable = directory / "slider-input-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"), "-I", str(directory),
            str(ROOT / "boringNotch/components/Music/PlayerProgressControl.swift"),
            str(ROOT / "boringNotch/extensions/PanGesture.swift"),
            str(ROOT / "boringNotch/App/NotchHostingView.swift"),
            str(ROOT / "Tests/SliderInputTests.swift"), str(defaults_object),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
