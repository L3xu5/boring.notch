#!/usr/bin/env python3
"""Compile the production Objective-C association wrapper without launching the application."""
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="boring-notch-native-utilities-") as directory:
        directory = Path(directory)
        executable = directory / "native-utilities"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            str(root / "boringNotch/helpers/AssociatedObject.swift"),
            str(root / "Tests/NativeUtilitiesRegressionTests.swift"),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
