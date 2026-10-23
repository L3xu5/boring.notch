#!/usr/bin/env python3
"""Link the production lyrics service/providers/Core with deterministic injected IO fixtures.

The native SwiftPM suite covers pure parsing/matching/cache algorithms. This platform suite
retains all 1355 request/cancellation regressions without extracting any methods from source.
"""

from pathlib import Path
from media_test_support import core_arguments
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    fixture = "import BoringCore\n" + (ROOT / "Tests/LyricsRegressionTests.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="boring-notch-lyrics-tests-") as directory:
        directory = Path(directory)
        swift = directory / "LyricsRegressionTests.swift"
        domain_arguments = core_arguments(directory)
        executable = directory / "lyrics-tests"
        swift.write_text("import BoringCore\n" + fixture)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            *domain_arguments,
            str(swift), str(ROOT / "boringNotch/MediaControllers/LyricsService.swift"),
            str(ROOT / "boringNotch/MediaControllers/MediaHTTPSession.swift"),
            str(ROOT / "boringNotch/MediaControllers/LRCLIBClient.swift"),
            str(ROOT / "boringNotch/MediaControllers/YandexLyricsProvider.swift"), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
