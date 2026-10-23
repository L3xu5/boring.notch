#!/usr/bin/env python3
"""Link the actual artwork service/Core content reducer with real AppKit fixture images."""

from pathlib import Path
from media_test_support import core_arguments
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    fixture = "import BoringCore\n" + (ROOT / "Tests/MusicMetadataRegressionTests.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="boring-notch-metadata-tests-") as directory:
        directory = Path(directory)
        swift = directory / "MusicMetadataRegressionTests.swift"
        domain_arguments = core_arguments(directory)
        executable = directory / "metadata-tests"
        swift.write_text("import BoringCore\n" + fixture)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            *domain_arguments,
            str(swift), str(ROOT / "boringNotch/MediaControllers/ArtworkPresentationService.swift"),
            str(ROOT / "boringNotch/extensions/NSImage+Extensions.swift"), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
